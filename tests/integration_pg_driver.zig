//! PostgreSQL 驱动层真库用例（`-Dpg-conn` 守卫）。
//!
//! 这里只放**驱动行为**（协议状态机 / 预处理语句复用），不放 ORM 语义
//! —— ORM 语义在 `integration_pg_real.zig` / `integration_dialect_versions.zig`。

const std = @import("std");
const zcode = @import("zcode");
const zzig = @import("zzig");
const build_options = @import("build_options");

const conn_str = build_options.pg_conn;

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="PgDrv" TableName="zcode_pg_drv">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Code" DataType="String" Length="50" />
    \\      <Column Name="Qty" DataType="Int32" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

fn openDal(a: std.mem.Allocator, conn: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    return zcode.Dal.initWithModel(a, conn, m);
}

test "PostgreSQL 驱动：一次 SQL 错误后连接仍可继续使用（错误路径必须消费 ReadyForQuery）" {
    if (conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dpg-conn，跳过 PG 驱动错误路径用例\n", .{});
        return;
    }
    const a = std.testing.allocator;

    var dal = try openDal(a, conn_str);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    // 先制造一次服务端错误（表不存在）
    const bad = s.queryRows("SELECT * FROM zcode_no_such_table_xyz", &.{});
    try std.testing.expectError(error.Server, bad);
    try std.testing.expect(std.mem.indexOf(u8, s.lastError(), "zcode_no_such_table_xyz") != null);

    // 再正常查询：若错误路径没把 ReadyForQuery 读掉，这里会读到残留消息 → 协议错位
    const rows = try s.queryRows("SELECT 1", &.{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].values[0].asI64().?);
}

test "PostgreSQL 驱动：预处理语句复用（命中缓存 / DDL 后自动重建 / 可关闭）" {
    if (conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dpg-conn，跳过 PG 预处理语句复用用例\n", .{});
        return;
    }
    const a = std.testing.allocator;

    var opts = try zcode.parseConnectionString(a, conn_str);
    defer opts.deinit(a);

    var conn = try zzig.postgres.Conn.open(a, .{
        .host = opts.server,
        .port = opts.port,
        .user = opts.user,
        .password = opts.password,
        .database = opts.database,
    });
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    // 干净起点（DDL 走简单查询，不进缓存）
    _ = try conn.exec("DROP TABLE IF EXISTS zcode_pg_stmt", &.{});
    _ = try conn.exec("CREATE TABLE zcode_pg_stmt (\"Id\" serial PRIMARY KEY, \"Code\" text NOT NULL)", &.{});

    const ins = "INSERT INTO zcode_pg_stmt (\"Code\") VALUES ($1)";
    _ = try conn.exec(ins, &.{.{ .text = "a" }});
    var st = conn.stmtCacheStats();
    try std.testing.expectEqual(@as(usize, 1), st.misses); // 首次必须 Parse
    try std.testing.expectEqual(@as(usize, 0), st.hits);

    // 同一条 SQL 再跑两次 → 只发 Bind + Execute + Sync
    _ = try conn.exec(ins, &.{.{ .text = "b" }});
    _ = try conn.exec(ins, &.{.{ .text = "c" }});
    st = conn.stmtCacheStats();
    try std.testing.expectEqual(@as(usize, 1), st.misses);
    try std.testing.expectEqual(@as(usize, 2), st.hits);
    try std.testing.expectEqual(@as(usize, 1), st.size);

    // 复用后结果必须仍然正确（不是"省了往返但数据错"）
    const sel = "SELECT \"Code\" FROM zcode_pg_stmt WHERE \"Id\" = $1";
    for (1..4) |i| {
        const r = try conn.queryAlloc(al, sel, &.{.{ .int = @intCast(i) }});
        switch (r) {
            .rows => |rs| try std.testing.expectEqual(@as(usize, 1), rs.rows.len),
            .ok => return error.UnexpectedOk,
        }
    }

    // DDL 改结果集形状 → 旧的命名语句会失效（PG 报 0A000 cached plan must not change result type）
    const sel_all = "SELECT * FROM zcode_pg_stmt WHERE \"Id\" = $1";
    switch (try conn.queryAlloc(al, sel_all, &.{.{ .int = 1 }})) {
        .rows => |rs| try std.testing.expectEqual(@as(usize, 1), rs.rows.len),
        .ok => return error.UnexpectedOk,
    }
    _ = try conn.exec("ALTER TABLE zcode_pg_stmt ADD COLUMN \"Qty\" int", &.{});
    // 驱动应丢弃缓存并自动重试一次 —— 这里不能再抛错
    switch (try conn.queryAlloc(al, sel_all, &.{.{ .int = 1 }})) {
        .rows => |rs| try std.testing.expectEqual(@as(usize, 1), rs.rows.len),
        .ok => return error.UnexpectedOk,
    }

    // 关闭复用：缓存清空、行为不变
    conn.setStmtCacheLimit(0);
    try std.testing.expectEqual(@as(usize, 0), conn.stmtCacheStats().size);
    _ = try conn.exec(ins, &.{.{ .text = "d" }});
    try std.testing.expectEqual(@as(usize, 0), conn.stmtCacheStats().size);

    _ = try conn.exec("DROP TABLE IF EXISTS zcode_pg_stmt", &.{});
}

