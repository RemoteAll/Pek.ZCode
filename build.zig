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
}
