const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzig_dep = b.dependency("zzig", .{ .target = target, .optimize = optimize });
    const zzig_mod = zzig_dep.module("zzig");

    // 对外发布的模块
    const zcode = b.addModule("zcode", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcode.addImport("zzig", zzig_mod);

    // 单元测试（src 内联 test）
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_mod.addImport("zzig", zzig_mod);

    const unit_tests = b.addTest(.{
        .name = "zcode-unit",
        .root_module = unit_mod,
    });
    const run_unit = b.addRunArtifact(unit_tests);

    // 集成测试（真实 SQLite：动态加载 sqlite3.dll / winsqlite3.dll）
    const itest_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    itest_mod.addImport("zcode", zcode);

    const itests = b.addTest(.{
        .name = "zcode-integration",
        .root_module = itest_mod,
    });
    const run_itests = b.addRunArtifact(itests);

    const test_step = b.step("test", "运行单元测试 + 集成测试");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_itests.step);

    const unit_step = b.step("unit", "仅运行单元测试");
    unit_step.dependOn(&run_unit.step);

    const integration_step = b.step("integration", "仅运行集成测试（真实 SQLite）");
    integration_step.dependOn(&run_itests.step);

    // zcodegen：Model.xml → Zig 实体
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/zcodegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_mod.addImport("zcode", zcode);
    const gen_exe = b.addExecutable(.{ .name = "zcodegen", .root_module = gen_mod });
    b.installArtifact(gen_exe);

    const gen_run = b.addRunArtifact(gen_exe);
    // 0.17 已移除 `b.args`，改用 build option：
    //   zig build codegen -Dmodel=Entity\Model.xml -Dout=src\entities
    if (b.option([]const u8, "model", "Model.xml 路径")) |v| {
        gen_run.addArg("--model");
        gen_run.addArg(v);
    }
    if (b.option([]const u8, "out", "实体输出目录")) |v| {
        gen_run.addArg("--out");
        gen_run.addArg(v);
    }
    if (b.option([]const u8, "table", "只生成指定表")) |v| {
        gen_run.addArg("--table");
        gen_run.addArg(v);
    }
    if (b.option(bool, "dry-run", "只打印不落盘") orelse false) {
        gen_run.addArg("--dry-run");
    }
    const gen_step = b.step("codegen", "从 Model.xml 生成实体：zig build codegen -Dmodel=<xml> -Dout=<dir>");
    gen_step.dependOn(&gen_run.step);

    // 绿色版（便携 exe）：不安装、不配置，直接跑通建表与增删改查
    const green_mod = b.createModule(.{
        .root_source_file = b.path("examples/green.zig"),
        .target = target,
        .optimize = optimize,
    });
    green_mod.addImport("zcode", zcode);
    const green_exe = b.addExecutable(.{ .name = "zcode-green", .root_module = green_mod });
    b.installArtifact(green_exe);

    const green_step = b.step("green", "构建绿色版 exe（zig-out/bin/zcode-green.exe）");
    green_step.dependOn(b.getInstallStep());

    const green_run = b.addRunArtifact(green_exe);
    green_run.addArgs(&.{ "--db", "zcode-green-selfcheck.db", "--reset" });
    const green_test_step = b.step("green-test", "运行绿色版自检（临时库，失败则退出码非 0）");
    green_test_step.dependOn(&green_run.step);
}
