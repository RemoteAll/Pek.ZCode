//! zcodegen：`Model.xml` → Zig 实体（正向）；`--reverse` 则从数据库反查生成 `Model.xml`。
//!
//! 用法：
//! ```powershell
//! zig build codegen -- --model Entity\Model.xml --out src\entities
//! zig build codegen -- --model Model.xml --out src\entities --table JiLiYu
//! zig build codegen -- --model Model.xml --out src\entities --dry-run
//! zig build codegen -- --reverse "Data Source=..\Data\DG.db;Provider=SQLite" --out Entity\Model.xml
//! zig build codegen -- --reverse "Provider=MySQL;Server=127.0.0.1;Port=3307;Database=zcode_test;UserID=root" --out Entity\Model.xml
//! ```

const std = @import("std");
const zcode = @import("zcode");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var model_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var table: ?[]const u8 = null;
    var reverse_conn: ?[]const u8 = null;
    var dry_run = false;
    var verify = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= argv.len) return usage();
            model_path = argv[i];
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= argv.len) return usage();
            out_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--table")) {
            i += 1;
            if (i >= argv.len) return usage();
            table = argv[i];
        } else if (std.mem.eql(u8, a, "--reverse")) {
            i += 1;
            if (i >= argv.len) return usage();
            reverse_conn = argv[i];
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage();
            return;
        } else {
            std.debug.print("未知参数：{s}\n", .{a});
            return usage();
        }
    }

    // 反向工程：连库 → 生成 Model.xml（--out 这里是**文件路径**而不是目录）
    // 反查不需要现有模型，用一个空模型建 Dal 即可（Dal 只在 sync/table 时用到表定义）
    if (reverse_conn) |conn| {
        const od = out_dir orelse return usage();
        const empty_model =
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><EntityModel xmlns=\"https://newlifex.com/Model202509.xsd\"><Tables></Tables></EntityModel>";
        var dal = try zcode.Dal.initWithModel(gpa, conn, try zcode.EntityModel.parse(gpa, empty_model));
        defer dal.deinit();
        var s = try dal.openSession();
        defer s.deinit();

        const xml = try zcode.reverse.modelXmlAlloc(gpa, &s, .{ .conn_name = "" });
        defer gpa.free(xml);
        if (dry_run) {
            std.debug.print("{s}", .{xml});
        } else {
            try zcode.File.WriteAll(od, xml);
            std.debug.print("zcodegen --reverse：已生成 {s}（{d} 字节）\n", .{ od, xml.len });
        }
        return;
    }

    const mp = model_path orelse return usage();

    // 互读对账：解析 → 回写 → 再解析，比对表/列/索引/未识别属性
    if (verify) {
        try verifyModel(gpa, mp);
        return;
    }

    const od = out_dir orelse return usage();

    var m = try zcode.EntityModel.load(gpa, mp);
    defer m.deinit();

    const report = try zcode.codegen.generateAll(gpa, &m, .{
        .out_dir = od,
        .table = table,
        .dry_run = dry_run,
    });
    std.debug.print("zcodegen：生成 {d} 个实体 / {d} 个文件 → {s}{s}\n", .{
        report.tables,
        report.files,
        od,
        if (dry_run) "（dry-run，未落盘）" else "",
    });
}

fn usage() error{MissingArgument} {
    printUsage();
    return error.MissingArgument;
}

/// Model.xml 互读对账（与 C# / Rust 的模型文件完全共用）。
///
/// 检查四件事：① 能解析；② 计数一致（表/列/索引/未识别属性）；③ 回写后再解析得到相同计数；
/// ④ 未识别属性一个部不丢。
fn verifyModel(gpa: std.mem.Allocator, path: []const u8) !void {
    var m1 = try zcode.EntityModel.load(gpa, path);
    defer m1.deinit();

    var cols: usize = 0;
    var idxs: usize = 0;
    var extra: usize = 0;
    for (m1.tables) |*t| {
        cols += t.columns.len;
        idxs += t.indexes.len;
        extra += t.extra.len;
        for (t.columns) |c| extra += c.extra.len;
    }

    const xml = try m1.toXmlAlloc(gpa);
    defer gpa.free(xml);

    var m2 = try zcode.EntityModel.parse(gpa, xml);
    defer m2.deinit();

    var cols2: usize = 0;
    var idxs2: usize = 0;
    var extra2: usize = 0;
    for (m2.tables) |*t| {
        cols2 += t.columns.len;
        idxs2 += t.indexes.len;
        extra2 += t.extra.len;
        for (t.columns) |c| extra2 += c.extra.len;
    }

    const ok = m1.tables.len == m2.tables.len and cols == cols2 and
        idxs == idxs2 and extra == extra2;

    // 未识别属性按名字聚合（这些是「原样保留」的，打出来便于判断是否有语义属性漏解析）
    var names: std.StringHashMapUnmanaged(usize) = .empty;
    defer names.deinit(gpa);
    for (m1.tables) |*t| {
        for (t.extra) |kv| {
            const e = try names.getOrPut(gpa, kv.key);
            if (!e.found_existing) e.value_ptr.* = 0;
            e.value_ptr.* += 1;
        }
        for (t.columns) |c| {
            for (c.extra) |kv| {
                const e = try names.getOrPut(gpa, kv.key);
                if (!e.found_existing) e.value_ptr.* = 0;
                e.value_ptr.* += 1;
            }
        }
    }
    if (names.count() > 0) {
        var it = names.iterator();
        while (it.next()) |kv| {
            std.debug.print("  未识别属性 {s} × {d}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
        }
    }

    std.debug.print(
        "verify {s}\n  表 {d}（回写 {d}）  列 {d}（{d}）  索引 {d}（{d}）  未知属性 {d}（{d}）  回写 {d} 字节 → {s}\n",
        .{ path, m1.tables.len, m2.tables.len, cols, cols2, idxs, idxs2, extra, extra2, xml.len, if (ok) "一致" else "不一致" },
    );
    if (!ok) return error.ModelMismatch;
}

fn printUsage() void {
    std.debug.print(
        \\zcodegen —— Model.xml → Zig 实体
        \\
        \\  --model <path>   必填，Model.xml 路径
        \\  --verify        只做互读对账（解析 → 回写 → 再解析），不生成
        \\  --out <dir>      必填，输出目录
        \\  --table <name>   只生成指定表（实体名或物理表名）
        \\  --dry-run        只打印到标准错误，不写文件
        \\
    , .{});
}
