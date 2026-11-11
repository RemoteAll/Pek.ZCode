//! MySQL 批量写基准：`insertBatch`（多行 INSERT）vs `loadDataBatch`（LOAD DATA LOCAL INFILE）。
//!
//! 用法：
//! ```powershell
//! powershell -File tools/mysql-local.ps1 -Action start
//! zig build bench-mysql -Dmysql-conn="Provider=MySQL;Server=127.0.0.1;Port=3307;Database=zcode_test;UserID=root;Password="
//! ```
//!
//! 口径：
//! - 每次先 `DELETE` 清表再计时（清表不计入耗时）；
//! - 同一进程内跑两种方式，**同机同轮对比**（跨轮次数字不能相减）；
//! - 打印「毫秒 / 每秒行数 / 每行微秒」。

const std = @import("std");
const zcode = @import("zcode");
const build_options = @import("build_options");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="BenchBulk" TableName="DH_BenchBulk">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Code" DataType="String" Length="50" />
    \\      <Column Name="Title" DataType="String" Length="200" />
    \\      <Column Name="Amount" DataType="Decimal" Precision="18" Scale="4" />
    \\      <Column Name="Ok" DataType="Boolean" />
    \\      <Column Name="CreateTime" DataType="DateTime" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

const cols = [_][]const u8{ "Code", "Title", "Amount", "Ok", "CreateTime" };

var io_global: std.Io = undefined;

fn nowNs() i128 {
    return std.Io.Clock.Timestamp.now(io_global, .awake).raw.nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    io_global = std.Io.Threaded.global_single_threaded.io();

    const conn_str = build_options.mysql_conn;
    if (conn_str.len == 0) {
        std.debug.print(
            "[SKIP] 未提供 -Dmysql-conn；示例：\n  zig build bench-mysql -Dmysql-conn=\"Provider=MySQL;Server=127.0.0.1;Port=3307;Database=zcode_test;UserID=root;Password=\"\n",
            .{},
        );
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    const m = try zcode.EntityModel.parse(gpa, model_xml);
    var dal = try zcode.Dal.initWithModel(gpa, conn_str, m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    _ = s.execute("DROP TABLE IF EXISTS `DH_BenchBulk`", &.{}) catch {};
    _ = try dal.syncSchema(&s);

    // local_infile 是 MySQL 8 默认关闭的；打不开就只跑 insertBatch 并说明原因
    var local_infile_ok = true;
    _ = s.execute("SET GLOBAL local_infile = 1", &.{}) catch {
        local_infile_ok = false;
        std.debug.print("[WARN] 无法开启 local_infile（{s}），跳过 LOAD DATA 对比\n", .{s.lastError()});
    };

    const table = try dal.table("BenchBulk");
    const total: usize = 20000;
    const now = zcode.DateTime.nowLocal();
    // 两套视图共享同一批字符串：Value 行给 LOAD DATA，Field 行给多行 INSERT
    const value_rows = try aa.alloc([]const zcode.Value, total);
    const field_rows = try aa.alloc([]const zcode.sqlbuild.Field, total);
    for (value_rows, 0..) |*row, i| {
        const code = try std.fmt.allocPrint(aa, "bulk-{d}", .{i});
        const title = try std.fmt.allocPrint(aa, "标题-{d}", .{i});
        const vals = try aa.alloc(zcode.Value, 5);
        vals[0] = .{ .text = code };
        vals[1] = .{ .text = title };
        vals[2] = .{ .decimal = try zcode.Decimal.parse("1234.5678") };
        vals[3] = .{ .boolean = (i % 2 == 0) };
        vals[4] = .{ .datetime = now };
        row.* = vals;

        const fields = try aa.alloc(zcode.sqlbuild.Field, 5);
        for (fields, 0..) |*f, j| f.* = .{ .name = cols[j], .value = vals[j] };
        field_rows[i] = fields;
    }

    std.debug.print("\n=== Pek.ZCode MySQL 批量写基准（{d} 行 × {d} 列）===\n", .{ total, cols.len });

    // 1) 多行 INSERT 分批
    {
        _ = try s.execute("DELETE FROM `DH_BenchBulk`", &.{});
        const start = nowNs();
        const inserted = try table.insertBatch(&s, field_rows);
        const elapsed = nowNs() - start;
        const count = try table.count(&s, null);
        try std.testing.expectEqual(@as(i64, @intCast(inserted)), count);
        printLine("insertBatch（多行 INSERT）", elapsed, inserted);
    }

    // 2) LOAD DATA LOCAL INFILE
    if (local_infile_ok) {
        _ = try s.execute("DELETE FROM `DH_BenchBulk`", &.{});
        const start = nowNs();
        const loaded = try table.loadDataBatch(&s, &cols, value_rows);
        const elapsed = nowNs() - start;
        const count = try table.count(&s, null);
        try std.testing.expectEqual(@as(i64, @intCast(loaded)), count);
        printLine("loadDataBatch（LOCAL INFILE）", elapsed, loaded);
    }

    // 3) 预处理语句复用 A/B：同一进程内先关缓存测一遍，再开缓存测一遍
    {
        const rounds: usize = 3000;
        _ = try s.execute("DELETE FROM `DH_BenchBulk`", &.{});
        _ = try s.execute("INSERT INTO `DH_BenchBulk` (`Id`, `Code`, `Title`, `Amount`, `Ok`, `CreateTime`) VALUES (1, 'hit-1', 'x', 1.0, 1, '2026-11-11 00:00:00')", &.{});

        const sel_sql = "SELECT `Id`, `Code`, `Title` FROM `DH_BenchBulk` WHERE `Id` = ?";
        const ins_sql = "INSERT INTO `DH_BenchBulk` (`Code`, `Title`, `Amount`, `Ok`, `CreateTime`) VALUES (?, 'y', 2.0, 0, '2026-11-11 00:00:00')";

        // 关缓存
        s.driver.mysql.setStmtCacheLimit(0);
        const off_sel = try timePointSelect(&s, sel_sql, rounds);
        const off_ins = try timeSingleInsert(&s, ins_sql, rounds);
        printLine("点查（预处理**未**复用）", off_sel, rounds);
        printLine("单行插入（预处理**未**复用）", off_ins, rounds);

        // 开缓存（32 条够用）
        s.driver.mysql.setStmtCacheLimit(32);
        const on_sel = try timePointSelect(&s, sel_sql, rounds);
        const on_ins = try timeSingleInsert(&s, ins_sql, rounds);
        printLine("点查（预处理复用）", on_sel, rounds);
        printLine("单行插入（预处理复用）", on_ins, rounds);

        const stats = s.driver.mysql.stmtCacheStats();
        std.debug.print("语句缓存：命中 {d} / 未命中 {d} / 当前 {d} 条\n", .{ stats.hits, stats.misses, stats.size });
        const speedup_sel = @as(f64, @floatFromInt(off_sel)) / @as(f64, @floatFromInt(on_sel));
        const speedup_ins = @as(f64, @floatFromInt(off_ins)) / @as(f64, @floatFromInt(on_ins));
        std.debug.print("提速：点查 {d:.2}× / 单行插入 {d:.2}×\n", .{ speedup_sel, speedup_ins });
    }

    _ = s.execute("DROP TABLE IF EXISTS `DH_BenchBulk`", &.{}) catch {};
}

/// 单个参数化点查循环（不计数、只测协议往返），返回总纳秒。
fn timePointSelect(s: *zcode.Session, sql: []const u8, rounds: usize) !i128 {
    // 热身 1 次：把首次 prepare/缓存写入排除在计时之外
    const warm = try s.queryRows(sql, &.{.{ .int = 1 }});
    try std.testing.expect(warm.len == 1);
    s.resetResults();

    const start = nowNs();
    for (0..rounds) |_| {
        const rows = try s.queryRows(sql, &.{.{ .int = 1 }});
        if (rows.len != 1) return error.Unexpected;
        s.resetResults();
    }
    return nowNs() - start;
}

/// 单个参数化插入循环（包在一个事务里，避免把「每次提交」的磁盘开销算进来）。
fn timeSingleInsert(s: *zcode.Session, sql: []const u8, rounds: usize) !i128 {
    _ = try s.beginTransaction(.default);
    const start = nowNs();
    for (0..rounds) |i| {
        const code = try std.fmt.allocPrint(s.resultAllocator(), "s-{d}", .{i});
        _ = try s.execute(sql, &.{.{ .text = code }});
        s.resetResults();
    }
    const elapsed = nowNs() - start;
    _ = try s.rollback(false);
    return elapsed;
}

fn printLine(name: []const u8, elapsed_ns: i128, n: usize) void {
    const ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const per_row_us = if (n == 0) 0.0 else @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(n)) / 1000.0;
    const per_sec = if (elapsed_ns <= 0) 0.0 else @as(f64, @floatFromInt(n)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));
    std.debug.print("{s: <34} {d: >8} 行  {d: >9.2} ms  {d: >9.2} µs/行  {d: >11.0} 行/秒\n", .{
        name, n, ms, per_row_us, per_sec,
    });
}
