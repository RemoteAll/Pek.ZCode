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
    // 集成用例要能直接用底层库（如 http_server / compat / File）
    itest_mod.addImport("zzig", zzig_mod);

    // MySQL 真库集成用例：只有传了 `-Dmysql-conn="Server=...;Database=...;Uid=...;Pwd=..."`
    // 才会真正连库；未传时用例显式打印 SKIP 原因（不静默通过）。
    const mysql_conn = b.option([]const u8, "mysql-conn", "MySQL 连接串（提供时跑真库集成测试）") orelse "";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "mysql_conn", mysql_conn);
    // MySQL 自签 CA（PEM）：给了才跑 SslMode=VerifyCA/VerifyFull 的正向用例
    const mysql_ca = b.option([]const u8, "mysql-ca", "MySQL 根证书路径（PEM，跑自签 CA 的证书校验用例）") orelse "";
    build_options.addOption([]const u8, "mysql_ca", mysql_ca);
    // PostgreSQL 真库集成用例：`-Dpg-conn="Provider=PostgreSQL;Server=...;Port=5432;Database=...;UserID=...;Password=..."`
    const pg_conn = b.option([]const u8, "pg-conn", "PostgreSQL 连接串（提供时跑真库集成测试）") orelse "";
    build_options.addOption([]const u8, "pg_conn", pg_conn);
    // 可选：SCRAM 鉴权专用连接（指向一个非 postgres 库，pg_hba 在那里要求 scram-sha-256）
    const pg_conn_scram = b.option([]const u8, "pg-conn-scram", "PostgreSQL SCRAM 连接串（可选，验证密码鉴权）") orelse "";
    build_options.addOption([]const u8, "pg_conn_scram", pg_conn_scram);
    itest_mod.addOptions("build_options", build_options);

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

    // 方言覆盖审计：把所有方言 × 各生成函数跑一遍，列缺口（不连库）
    const audit_mod = b.createModule(.{
        .root_source_file = b.path("tools/audit_dialects.zig"),
        .target = target,
        .optimize = optimize,
    });
    audit_mod.addImport("zcode", zcode);
    audit_mod.addImport("zzig", zzig_mod);
    const audit_exe = b.addExecutable(.{
        .name = "audit-dialects",
        .root_module = audit_mod,
    });
    const run_audit = b.addRunArtifact(audit_exe);
    const audit_step = b.step("audit-dialects", "方言覆盖审计（列出入 SQL 生成缺口）");
    audit_step.dependOn(&run_audit.step);

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
    const model_arg = b.option([]const u8, "model", "Model.xml 路径");
    if (model_arg) |v| {
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
    if (b.option([]const u8, "import", "生成代码里的 zcode 导入路径（库内自用传 ../../root.zig）")) |v| {
        gen_run.addArg("--import");
        gen_run.addArg(v);
    }
    if (b.option(bool, "no-biz", "不生成业务扩展文件（默认生成一次且不覆盖）") orelse false) {
        gen_run.addArg("--no-biz");
    }
    if (b.option(bool, "force-biz", "强制重写业务扩展文件（会丢掉手写内容）") orelse false) {
        gen_run.addArg("--force-biz");
    }
    if (b.option(bool, "dry-run", "只打印不落盘") orelse false) {
        gen_run.addArg("--dry-run");
    }
    const gen_step = b.step("codegen", "从 Model.xml 生成实体：zig build codegen -Dmodel=<xml> -Dout=<dir>");
    gen_step.dependOn(&gen_run.step);

    // 生成器自检：把已生成的实体编译出来，在临时 SQLite 上真建表 + 增删改查
    //   zig build codegen -Dmodel=<Model.xml> -Dout=zig-out\gen-csharp
    //   zig build gen-check -Dgen-check=zig-out\gen-csharp -Dmodel=<Model.xml>
    if (b.option([]const u8, "gen-check", "已生成实体的目录（需含 mod.zig），编译并跑一遍增删改查")) |dir| {
        const entities_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}/mod.zig", .{dir})),
            .target = target,
            .optimize = optimize,
        });
        entities_mod.addImport("zcode", zcode);

        const check_mod = b.createModule(.{
            .root_source_file = b.path("tools/gencheck.zig"),
            .target = target,
            .optimize = optimize,
        });
        check_mod.addImport("zcode", zcode);
        check_mod.addImport("entities", entities_mod);

        const check_exe = b.addExecutable(.{ .name = "gencheck", .root_module = check_mod });
        const check_run = b.addRunArtifact(check_exe);
        // 复用上面已经声明过的 `model` 选项值（同一 build 里不能重复 declare）
        if (model_arg) |v| {
            check_run.addArg("--model");
            check_run.addArg(v);
        }
        check_run.addArg("--db");
        check_run.addArg(b.fmt("{s}/gencheck.db", .{dir}));

        const check_step = b.step("gen-check", "生成器自检：编译生成实体并真库增删改查（需 -Dgen-check=<dir>）");
        check_step.dependOn(&check_run.step);
    }

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

    // 性能基准：`zig build bench`（SQLite 内存库），输出各关键路径的耗时表
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = b.option(std.builtin.OptimizeMode, "bench-optimize", "基准优化档位（默认 ReleaseFast）") orelse .ReleaseFast,
    });
    bench_mod.addImport("zcode", zcode);
    const bench_exe = b.addExecutable(.{ .name = "zcode-bench", .root_module = bench_mod });
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "性能基准：zig build bench（默认 ReleaseFast）");
    bench_step.dependOn(&bench_run.step);

    // MySQL 批量写基准：`zig build bench-mysql -Dmysql-conn="..."`（需要本机有 MySQL 实例）
    const bench_mysql_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_mysql.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mysql_mod.addImport("zcode", zcode);
    bench_mysql_mod.addOptions("build_options", build_options);
    const bench_mysql_exe = b.addExecutable(.{ .name = "zcode-bench-mysql", .root_module = bench_mysql_mod });
    const bench_mysql_run = b.addRunArtifact(bench_mysql_exe);
    const bench_mysql_step = b.step("bench-mysql", "MySQL 批量写基准（insertBatch vs LOCAL INFILE）");
    bench_mysql_step.dependOn(&bench_mysql_run.step);
}
