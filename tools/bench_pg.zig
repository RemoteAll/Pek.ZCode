//! PostgreSQL 预处理语句复用基准（同进程 A/B）。
//!
//! 用法：
//! ```powershell
//! powershell -File tools/pg-local.ps1 -Action start
//! zig build bench-pg -Dpg-conn="Provider=PostgreSQL;Server=127.0.0.1;Port=5433;Database=postgres;UserID=postgres;Password="
//! ```
//!
//! 口径（与 `bench_mysql.zig` 一致，避免自欺）：
//! - **同一进程、同一连接、同一批数据**顺序跑两遍，先关缓存再开缓存 —— 跨轮次绝对值不可相减；
//! - 查询各自热身 1 次，把首次 `Parse` 排除在计时外；
//! - 插入放在同一事务里，避免把每次提交的 fsync 算进协议对比；
//! - 只测驱动协议层（`Bind + Execute + Sync` vs `Parse + Describe + Bind + Execute + Sync`），
//!   不含 ORM 的 SQL 组装。

const std = @import("std");
const zcode = @import("zcode");
const zzig = @import("zzig");
const build_options = @import("build_options");

var io_global: std.Io = undefined;

fn nowNs() i128 {
    return std.Io.Clock.Timestamp.now(io_global, .awake).raw.nanoseconds;
}

const iterations: usize = 3000;
const seed_rows: i64 = 100;

fn benchSelect(
    conn: *zzig.postgres.Conn,
    arena: *std.heap.ArenaAllocator,
    sql: []const u8,
) !u64 {
    const t0 = nowNs();
    for (0..iterations) |i| {
        _ = arena.reset(.retain_capacity);
        const key: i64 = @intCast(i % @as(usize, @intCast(seed_rows)) + 1);
        switch (try conn.queryAlloc(arena.allocator(), sql, &.{.{ .int = key }})) {
            .rows => |rs| if (rs.rows.len != 1) return error.UnexpectedRowCount,
            .ok => return error.UnexpectedOk,
        }
    }
    return @intCast(nowNs() - t0);
}

fn benchInsert(conn: *zzig.postgres.Conn, sql: []const u8) !u64 {
    _ = try conn.exec("BEGIN", &.{});
    defer _ = conn.exec("ROLLBACK", &.{}) catch {};

    var buf: [32]u8 = undefined;
    const t0 = nowNs();
    for (0..iterations) |i| {
        const code = std.fmt.bufPrint(&buf, "b-{d}", .{i}) catch "b";
        _ = try conn.exec(sql, &.{ .{ .text = code }, .{ .int = @intCast(i) } });
    }
    return @intCast(nowNs() - t0);
}

fn report(label: []const u8, no_cache_ns: u64, cache_ns: u64) void {
    const n: f64 = @floatFromInt(iterations);
    const a_us: f64 = @as(f64, @floatFromInt(no_cache_ns)) / 1000.0;
    const b_us: f64 = @as(f64, @floatFromInt(cache_ns)) / 1000.0;
    const ratio = if (cache_ns == 0) 0.0 else @as(f64, @floatFromInt(no_cache_ns)) / @as(f64, @floatFromInt(cache_ns));
    std.debug.print(
        "[bench-pg] {s} {d} 次：不复用 {d:.2} ms（{d:.2} µs/次） → 复用 {d:.2} ms（{d:.2} µs/次） = **{d:.2}×**\n",
        .{ label, iterations, a_us / 1000.0, a_us / n, b_us / 1000.0, b_us / n, ratio },
    );
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    io_global = std.Io.Threaded.global_single_threaded.io();

    const conn_str = build_options.pg_conn;
    if (conn_str.len == 0) {
        std.debug.print(
            "[SKIP] 未提供 -Dpg-conn；示例：\n  zig build bench-pg -Dpg-conn=\"Provider=PostgreSQL;Server=127.0.0.1;Port=5433;Database=postgres;UserID=postgres;Password=\"\n",
            .{},
        );
        return;
    }

    var opts = try zcode.parseConnectionString(gpa, conn_str);
    defer opts.deinit(gpa);

    var conn = try zzig.postgres.Conn.open(gpa, .{
        .host = opts.server,
        .port = opts.port,
        .user = opts.user,
        .password = opts.password,
        .database = opts.database,
    });
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    _ = try conn.exec("DROP TABLE IF EXISTS zcode_bench_pg", &.{});
    _ = try conn.exec(
        "CREATE TABLE zcode_bench_pg (\"Id\" serial PRIMARY KEY, \"Code\" text NOT NULL, \"Qty\" int NOT NULL)",
        &.{},
    );
    defer _ = conn.exec("DROP TABLE IF EXISTS zcode_bench_pg", &.{}) catch {};

    const select_sql = "SELECT \"Code\" FROM zcode_bench_pg WHERE \"Id\" = $1";
    const insert_sql = "INSERT INTO zcode_bench_pg (\"Code\", \"Qty\") VALUES ($1, $2)";

    // 播种（不复用，属于准备阶段）
    conn.setStmtCacheLimit(0);
    _ = try conn.exec("BEGIN", &.{});
    var seed_buf: [32]u8 = undefined;
    for (0..@as(usize, @intCast(seed_rows))) |i| {
        const code = std.fmt.bufPrint(&seed_buf, "seed-{d}", .{i}) catch "seed";
        _ = try conn.exec(insert_sql, &.{ .{ .text = code }, .{ .int = @intCast(i) } });
    }
    _ = try conn.exec("COMMIT", &.{});

    // ── A：不复用（每次 Parse + Describe + Bind + Execute + Sync）──
    conn.setStmtCacheLimit(0);
    _ = try benchSelect(&conn, &arena_state, select_sql); // 热身
    const a_select = try benchSelect(&conn, &arena_state, select_sql);
    const a_insert = try benchInsert(&conn, insert_sql);
    const stats_a = conn.stmtCacheStats(); // A 阶段全是不复用，只看差值才有意义

    // ── B：复用（首条 Parse，其后只 Bind + Execute + Sync）──
    conn.setStmtCacheLimit(32);
    _ = try benchSelect(&conn, &arena_state, select_sql); // 热身（触发首次 Parse）
    const b_select = try benchSelect(&conn, &arena_state, select_sql);
    const b_insert = try benchInsert(&conn, insert_sql);

    report("点查", a_select, b_select);
    report("单行插入", a_insert, b_insert);

    const st = conn.stmtCacheStats();
    const b_hits = st.hits - stats_a.hits;
    const b_misses = st.misses - stats_a.misses;
    const b_total = b_hits + b_misses;
    const hit_rate = if (b_total == 0) 0.0 else @as(f64, @floatFromInt(b_hits)) / @as(f64, @floatFromInt(b_total));
    std.debug.print(
        "[bench-pg] 复用阶段命中率：{d:.1}%（hits={d} misses={d}，缓存条目 {d}）—— 只计 B 阶段\n",
        .{ hit_rate * 100.0, b_hits, b_misses, st.size },
    );
}
