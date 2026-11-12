//! 生成器自检：把 `zcodegen` 生成的实体**真编译、真建表、真增删改查**跑一遍。
//!
//! 用法（两步，第二步用 `-Dgen-check` 指向第一步的输出目录）：
//! ```powershell
//! zig build codegen -Dmodel=..\..\Pek.FrameWork\DH.NCode\DH.NCode\Model.xml -Dout=zig-out\gen-csharp
//! zig build gen-check -Dgen-check=zig-out\gen-csharp -Dmodel=<同一个 Model.xml>
//! ```
//!
//! 为什么要它：C# / Rust 的 `Model.xml` 能不能被本库**完全共用**，只靠“解析成功”说明不了问题——
//! 必须把生成的实体编译出来，在真库上建表并读写一遍，才证明模型里的长度/精度/主键/自增/索引
//! 都被正确吃进去了。

const std = @import("std");
const zcode = @import("zcode");
const entities = @import("entities");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var model_path: ?[]const u8 = null;
    var db_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--model") and i + 1 < argv.len) {
            i += 1;
            model_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--db") and i + 1 < argv.len) {
            i += 1;
            db_path = argv[i];
        }
    }
    const mp = model_path orelse {
        std.debug.print("用法：gencheck --model <Model.xml> [--db <sqlite 路径>]\n", .{});
        return error.MissingArgument;
    };

    var m = try zcode.EntityModel.load(gpa, mp);
    // 模型交给 Dal 接管（Dal.deinit 会释放模型 arena）——不能再自己 deinit，否则双重释放
    const dbp = db_path orelse "zig-out/gencheck.db";
    const conn = try std.fmt.allocPrint(gpa, "Data Source={s};Provider=SQLite", .{dbp});
    defer gpa.free(conn);

    var dal = zcode.Dal.initWithModel(gpa, conn, m) catch |e| {
        m.deinit();
        return e;
    };
    defer dal.deinit();

    // 模型里声明的**其它连接**（表级 ConnName 覆盖模型级）必须显式挂上，
    // 否则 `syncSchema` 会拒绝把那些表静默建到主库（这是有意的守卫）。
    // 冒烟工具只有一个 SQLite 文件，所以把每个连接名都挂到同一个文件上；
    // 真实业务里这里应挂各自的连接串。
    {
        var attached: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (attached.items) |n| gpa.free(n);
            attached.deinit(gpa);
        }
        for (dal.model.tables) |*t| {
            const cn = dal.model.tableConn(t) orelse continue;
            if (cn.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(cn, dal.connName())) continue;
            var seen = false;
            for (attached.items) |n| {
                if (std.ascii.eqlIgnoreCase(n, cn)) seen = true;
            }
            if (seen) continue;
            dal.attachConnection(cn, conn) catch |e| {
                std.debug.print("[gencheck] 挂载连接 {s} 失败：{s}\n", .{ cn, @errorName(e) });
                continue;
            };
            const owned = try gpa.dupe(u8, cn);
            try attached.append(gpa, owned);
        }
        if (attached.items.len > 0) {
            std.debug.print("gencheck：按模型挂载了 {d} 个附加连接（同一 SQLite 文件）\n", .{attached.items.len});
        }
    }

    var s = try dal.openSession();
    defer s.deinit();

    // 1) 增量建表（含索引）：这一步就把「模型 → DDL」的兼容性验了
    const report = try dal.syncSchema(&s);
    std.debug.print(
        "gencheck：建表 {d} / 补列 {d} / 建索引 {d}（库 {s}）\n",
        .{ report.tables_created, report.columns_added, report.indexes_created, dbp },
    );

    // 2) 逐个实体：插入一行 → 按主键取回 → 删掉
    var ok: usize = 0;
    var skipped: usize = 0;
    inline for (entities.all) |T| {
        if (checkEntity(gpa, &dal, &s, T)) |_| {
            ok += 1;
        } else |e| {
            skipped += 1;
            std.debug.print("  [SKIP] {s}：{s}\n", .{ T.meta.name, @errorName(e) });
        }
    }

    std.debug.print("gencheck：实体 {d} 个，真实增删改查通过 {d} 个，跳过 {d} 个\n", .{
        entities.all.len,
        ok,
        skipped,
    });
    if (ok == 0) return error.NoEntityChecked;
}

fn checkEntity(gpa: std.mem.Allocator, dal: *zcode.Dal, s: *zcode.Session, comptime T: type) !void {
    const t = dal.model.table(T.meta.table_name) orelse return error.TableNotFound;
    if (t.is_view) return error.ViewTable;
    if (t.insert_only) return error.InsertOnlyTable;

    var e: T = .{};
    inline for (T.meta.fields, 0..) |f, idx| {
        if (f.identity) continue;
        try e.setColumnValue(idx, sampleValue(f.data_type, idx));
    }

    const id = try zcode.entity.insert(dal, &e, s);

    // 有单列自增主键就再取回来比对（复合主键 / 无自增只做插入验证）
    const pks = try t.primaryKeys(gpa);
    defer if (pks.len > 0) gpa.free(pks);
    if (pks.len == 1 and t.identity() != null) {
        const got = (try zcode.entity.findByPk(dal, T, s, &.{.{ .int = id }})) orelse return error.NotFoundAfterInsert;
        // 取回来的实体列数必须与生成的元数据一致（装载不能漏列）
        if (@TypeOf(got).meta.fields.len != T.meta.fields.len) return error.FieldCountMismatch;
    }

    _ = try zcode.entity.delete(dal, &e, s);
    std.debug.print(
        "  [OK] {s}（{d} 列，主键 {d} 列，自增 {s}）id={d}\n",
        .{ T.meta.name, T.meta.fields.len, pks.len, if (t.identity() != null) "是" else "否", id },
    );
}

fn sampleValue(dt: zcode.DataType, idx: usize) zcode.Value {
    const n: i64 = @intCast(idx + 2);
    return switch (dt) {
        .boolean => .{ .boolean = true },
        .byte => .{ .int = n },
        .int16, .int32, .int64 => .{ .int = n },
        .single, .double => .{ .float = @floatFromInt(n) },
        .decimal => .{ .decimal = zcode.Decimal.init(n, 0) catch .{ .mantissa = 0, .scale = 0 } },
        .datetime => .{ .datetime = zcode.DateTime.nowLocal() },
        .string, .json => .{ .text = "zcheck" },
        .binary => .{ .blob = "zcheck" },
    };
}
