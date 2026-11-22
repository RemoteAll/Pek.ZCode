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
    // 反向工程时 `Model.xml` 的落盘路径（默认 `{out}/Model.xml`）。
    var model_out: ?[]const u8 = null;
    // 反向工程：**只导出 `Model.xml`**，不生成实体（看/比结构时用）。
    var model_only = false;
    var table: ?[]const u8 = null;
    var reverse_conn: ?[]const u8 = null;
    var dry_run = false;
    var verify = false;
    var import_path: []const u8 = "zcode";
    var biz = true;
    var force_biz = false;

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
        } else if (std.mem.eql(u8, a, "--model-out")) {
            i += 1;
            if (i >= argv.len) return usage();
            model_out = argv[i];
        } else if (std.mem.eql(u8, a, "--model-only")) {
            model_only = true;
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
        } else if (std.mem.eql(u8, a, "--import")) {
            i += 1;
            if (i >= argv.len) return usage();
            import_path = argv[i];
        } else if (std.mem.eql(u8, a, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, a, "--no-biz")) {
            biz = false;
        } else if (std.mem.eql(u8, a, "--force-biz")) {
            force_biz = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage();
            return;
        } else {
            std.debug.print("未知参数：{s}\n", .{a});
            return usage();
        }
    }

    // 反向工程：连库 → `Model.xml` → **实体**（与 C#「GetTables + Builder」两步同口径，
    // Rust `Pek.RCode --reverse` 只做到 `Model.xml`，这里再往前一步把实体也生成出来）。
    // `--out` 是**实体目录**（与正向一致），`--model-out` 指定 `Model.xml` 路径，
    // 默认落在 `{out}/Model.xml`（留着随时能看/改结构）。
    if (reverse_conn) |conn| {
        // `--model-only`：只要 xml（结构导出），不需要实体目录
        const od = out_dir orelse if (model_only) "" else return usage();
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
            return;
        }

        const xml_path = model_out orelse if (od.len > 0)
            try std.fmt.allocPrint(gpa, "{s}/Model.xml", .{od})
        else
            return usage();
        defer if (model_out == null and od.len > 0) gpa.free(xml_path);
        try zcode.File.WriteAll(xml_path, xml);
        std.debug.print("zcodegen --reverse：已从库导出 {s}（{d} 字节）\n", .{ xml_path, xml.len });
        if (model_only) return;

        // 接着用刚导出的模型生成实体（同一套语义：列默认值按 C# XCode 补全）
        var m = zcode.EntityModel.parse(gpa, xml) catch |e| {
            std.debug.print("zcodegen --reverse：解析刚生成的 Model.xml 失败（{s}）\n", .{@errorName(e)});
            return;
        };
        m.applyCsharpColumnDefaults();
        const report = try zcode.codegen.generateAll(gpa, &m, .{
            .out_dir = od,
            .table = table,
            .dry_run = false,
            .import = import_path,
            .biz = biz,
            .force_biz = force_biz,
        });
        std.debug.print("zcodegen --reverse：已生成 {d} 个实体 / {d} 个文件 → {s}\n", .{ report.tables, report.files, od });
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

    // **按 C# XCode 的列语义补全**（C# 同源模型不写 `Nullable`/`DefaultValue`）：
    // 与 `syncSchema` 建表同一口径，否则生成的实体把可空列当空串/0。
    m.applyCsharpColumnDefaults();

    const report = try zcode.codegen.generateAll(gpa, &m, .{
        .out_dir = od,
        .table = table,
        .dry_run = dry_run,
        .import = import_path,
        .biz = biz,
        .force_biz = force_biz,
    });
    std.debug.print("zcodegen：生成 {d} 个实体 / {d} 个文件 → {s}{s}\n", .{
        report.tables,
        report.files,
        od,
        if (dry_run) "（dry-run，未落盘）" else "",
    });
    if (biz and !dry_run) {
        std.debug.print("zcodegen：业务扩展文件 新建 {d} / 保留 {d}（已有内容不会覆盖）\n", .{ report.biz_written, report.biz_kept });
        std.debug.print(
            "zcodegen：接入 build.zig ——\n" ++
                "    const entities = b.createModule(.{{ .root_source_file = b.path(\"{s}/mod.zig\") }});\n" ++
                "    entities.addImport(\"zcode\", zcode);\n",
            .{od},
        );
    }
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
        \\zcodegen —— Model.xml ⇄ Zig 实体（正向生成 / 反向工程）
        \\
        \\正向（模型 → 实体）：
        \\  --model <path>    必填，Model.xml 路径
        \\  --out <dir>       必填，实体输出目录（名字.zig + 名字.biz.zig + mod.zig）
        \\  --table <name>    只生成指定表（实体名或物理表名）
        \\  --import <path>   生成文件里的 zcode 导入路径（默认 zcode）
        \\  --no-biz          不生成业务扩展文件
        \\  --force-biz       覆盖已有业务扩展文件（默认保留）
        \\  --dry-run         只打印，不写文件
        \\  --verify          只做互读对账（解析 → 回写 → 再解析），不生成
        \\
        \\反向工程（库 → Model.xml → 实体，与 C#「GetTables + Builder」同口径）：
        \\  --reverse <conn>  连接串，如 "Data Source=Data/Admin.db;Provider=SQLite"
        \\  --out <dir>       必填，实体输出目录
        \\  --model-out <path> 导出的 Model.xml 路径（默认 out 目录下 Model.xml）
        \\
    , .{});
}
