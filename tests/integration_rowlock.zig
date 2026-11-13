//! 真库用例：行锁 `FOR UPDATE SKIP LOCKED`（多实例并发消费同一张表）。
//!
//! 这是亿级设备场景的核心模式：指令队列 / 批量任务，多个 worker 同时抢任务，
//! 每人拿到**不同**的行、互不阻塞、不重复消费。
//!
//! - MySQL 8.0 / PostgreSQL 9.5+ / Oracle 11g+：`FOR UPDATE SKIP LOCKED`
//! - SQL Server：`WITH (UPDLOCK, READPAST)`（表提示）
//! - SQLite：**不支持**，显式 `error.Unsupported`（它只有库级写锁）

const std = @import("std");
const zcode = @import("zcode");
const build_options = @import("build_options");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="Task" TableName="zcode_task">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

fn openDal(a: std.mem.Allocator, conn: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    return zcode.Dal.initWithModel(a, conn, m);
}

fn seed(table: zcode.dbtable.TableRef, s: *zcode.Session) !void {
    _ = try table.delete(s, null);
    for (0..4) |i| {
        const name = try std.fmt.allocPrint(s.resultAllocator(), "t{d}", .{i});
        _ = try table.insert(s, &.{.{ .name = "Name", .value = .{ .text = name } }});
    }
}

/// 两个会话同时抢一批（各抢 2 行），断言拿到的 id **不相交**。
fn twoWorkersClaim(table: zcode.dbtable.TableRef, s1: *zcode.Session, s2: *zcode.Session) !void {
    _ = try s1.beginTransaction(.read_committed);
    errdefer _ = s1.rollback(true) catch {};
    _ = try s2.beginTransaction(.read_committed);
    errdefer _ = s2.rollback(true) catch {};

    var q1 = zcode.Query.init(std.testing.allocator);
    defer q1.deinit();
    q1.limit = 2;
    q1.lock = .skip_locked;

    var q2 = zcode.Query.init(std.testing.allocator);
    defer q2.deinit();
    q2.limit = 2;
    q2.lock = .skip_locked;

    const rows1 = try table.queryRows(s1, &q1);
    const rows2 = try table.queryRows(s2, &q2);

    try std.testing.expectEqual(@as(usize, 2), rows1.len);
    try std.testing.expectEqual(@as(usize, 2), rows2.len);

    // 关键断言：两个人拿到的是不同的行（SKIP LOCKED 生效）
    for (rows1) |a| {
        const id_a = a.get("Id").?.asI32() orelse -1;
        for (rows2) |b| {
            const id_b = b.get("Id").?.asI32() orelse -1;
            try std.testing.expect(id_a != id_b);
        }
    }

    _ = try s1.rollback(true);
    _ = try s2.rollback(true);
}

test "SQLite：行锁显式报 Unsupported（只有库级写锁）" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "rowlock", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{path});
    defer a.free(conn);
    var dal = try openDal(a, conn);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("Task");
    try seed(table, &s);

    var q = zcode.Query.init(a);
    defer q.deinit();
    q.limit = 2;
    q.lock = .skip_locked;
    try std.testing.expectError(error.Unsupported, table.queryRows(&s, &q));
}

test "MySQL：FOR UPDATE SKIP LOCKED 两个会话抢到不同的行（需 -Dmysql-conn）" {
    if (build_options.mysql_conn.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-conn，跳过 MySQL 行锁用例\n", .{});
        return;
    }
    const a = std.testing.allocator;
    var dal = try openDal(a, build_options.mysql_conn);
    defer dal.deinit();
    var s1 = try dal.openSession();
    defer s1.deinit();
    var s2 = try dal.openSession();
    defer s2.deinit();
    _ = try dal.syncSchema(&s1);

    const table = try dal.table("Task");
    try seed(table, &s1);
    try twoWorkersClaim(table, &s1, &s2);
}

test "PostgreSQL：FOR UPDATE SKIP LOCKED 两个会话抢到不同的行（需 -Dpg-conn）" {
    if (build_options.pg_conn.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dpg-conn，跳过 PostgreSQL 行锁用例\n", .{});
        return;
    }
    const a = std.testing.allocator;
    var dal = try openDal(a, build_options.pg_conn);
    defer dal.deinit();
    var s1 = try dal.openSession();
    defer s1.deinit();
    var s2 = try dal.openSession();
    defer s2.deinit();
    _ = s1.execute("DROP TABLE IF EXISTS zcode_task", &[_]zcode.Value{}) catch 0;
    _ = try dal.syncSchema(&s1);

    const table = try dal.table("Task");
    try seed(table, &s1);
    try twoWorkersClaim(table, &s1, &s2);
}
