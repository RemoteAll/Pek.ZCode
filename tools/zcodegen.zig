//! zcodegen：`Model.xml` → Zig 实体。
//!
//! 用法：
//! ```powershell
//! zig build codegen -- --model Entity\Model.xml --out src\entities
//! zig build codegen -- --model Model.xml --out src\entities --table JiLiYu
//! zig build codegen -- --model Model.xml --out src\entities --dry-run
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
    var dry_run = false;

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
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage();
            return;
        } else {
            std.debug.print("未知参数：{s}\n", .{a});
            return usage();
        }
    }

    const mp = model_path orelse return usage();
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

fn printUsage() void {
    std.debug.print(
        \\zcodegen —— Model.xml → Zig 实体
        \\
        \\  --model <path>   必填，Model.xml 路径
        \\  --out <dir>      必填，输出目录
        \\  --table <name>   只生成指定表（实体名或物理表名）
        \\  --dry-run        只打印到标准错误，不写文件
        \\
    , .{});
}
