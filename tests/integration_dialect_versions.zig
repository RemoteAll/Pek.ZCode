//! 真库用例：**服务端版本探测 + 方言能力开关**（`dialect.ServerVersion` / `dialect.Features`）。
//!
//! 为什么单独一个文件：这两项能力都**依赖真实服务端版本**，只在 SQLite 上验证等于没验证：
//!
//! - MySQL 8.0.19+ 的**行别名** upsert（`... VALUES (...) AS zcode_new ON DUPLICATE KEY UPDATE`）
//!   与 5.7 / MariaDB 的 `VALUES(col)` 是两套语法，任一份写错都是**语法错**（不是性能差异）；
//! - PostgreSQL 的 `INSERT ... RETURNING` 是本库**唯一**能在一次往返里拿回自增 ID 的路径
//!   （PG 驱动的 `lastInsertId` 恒 0）。
//!
//! SQLite 总是跑；MySQL / PostgreSQL 只在给了 `-Dmysql-conn` / `-Dpg-conn` 时跑
//! （未给时**显式 SKIP**，不是静默跳过）。

const std = @import("std");
const zcode = @import("zcode");
const build_options = @import("build_options");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="VerItem" TableName="zcode_ver_item">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Code" DataType="String" Length="50" />
    \\      <Column Name="Qty" DataType="Int32" />
    \\    </Columns>
    \\    <Indexes>
    \\      <Index Columns="Code" Unique="True" />
    \\    </Indexes>
    \\  </Table>
    \\</Tables></EntityModel>
;

fn openDal(a: std.mem.Allocator, conn: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    return zcode.Dal.initWithModel(a, conn, m);
}

fn field(name: []const u8, value: zcode.Value) zcode.sqlbuild.Field {
    return .{ .name = name, .value = value };
}

/// 一行 upsert 数据（只写业务列：主键列不在插入列里，冲突目标因此落到 `Code` 唯一索引）。
fn upsertRow(code: []const u8, qty: i32) [2]zcode.sqlbuild.Field {
    return .{ field("Code", .{ .text = code }), field("Qty", .{ .int = qty }) };
}

/// 全表读回首行的 `Id` 与 `Qty`（列下标 0 / 2）。
///
/// **不要硬编码自增值**：upsert 在 SQLite（rowid 先分配后回滚）与 MySQL（AUTO_INCREMENT 被消耗）
/// 上都会让下一次插入的 id 跳号，写死 `Id=1` 的断言会假失败。
///
/// 行集指向会话内存，**读完立刻拷出来**再 `resetResults`（否则下一次查询会把它覆盖掉）。
fn scan(s: *zcode.Session, table: anytype, gpa: std.mem.Allocator) !struct { rows: usize, id: i64, qty: i64 } {
    // **不要用 `s.resultAllocator()`**：`resetResults()` 会整块重置那个 arena，
    // 而 `q.deinit()` 在 `defer` 里晚于它执行 → `write after free`（实测 crash）。
    var q = zcode.Query.init(gpa);
    defer q.deinit();
    // 按主键升序，“首行”才稳定（否则 SQL 不保证行序，断言会随实现飘）
    try q.order_by.append(q.a, .{ .column = "Id" });
    const rows = try table.queryRows(s, &q);
    const n = rows.len;
    const id: i64 = if (n == 0) 0 else (rows[0].values[0].asI64() orelse 0);
    const qty: i64 = if (n == 0) 0 else (rows[0].values[2].asI64() orelse 0);
    s.resetResults();
    return .{ .rows = n, .id = id, .qty = qty };
}

test "SQLite：探测到版本、能力保守、全列冲突退化为 DO NOTHING" {
    const a = std.testing.allocator;

    const db_path = try zcode.File.UniqueTempName(a, "verlite", ".db");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);

    var dal = openDal(a, conn) catch |e| {
        std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    // 探测发生在第一次开会话之后；SQLite 是本地库，一定能拿到版本
    const v = dal.serverVersion() orelse {
        std.debug.print("[FAIL] SQLite 版本探测没有结果\n", .{});
        return error.ProbeMissing;
    };
    try std.testing.expectEqual(zcode.dialect.ServerVersion.Flavor.sqlite, v.flavor);
    try std.testing.expect(v.major >= 3);

    // SQLite 不走这两个能力（行别名是 MySQL 的、RETURNING 它在任何在役版本上都不需要——
    // 本地 `last_insert_rowid()` 已经是零成本）
    const f = dal.features();
    try std.testing.expect(!f.mysql_row_alias);
    try std.testing.expect(!f.pg_returning);

    const desc = try dal.describeServerAlloc();
    defer a.free(desc);
    std.debug.print("[INFO] SQLite 服务端：{s}\n", .{desc});
    try std.testing.expect(std.mem.indexOf(u8, desc, "SQLite") != null);

    _ = try dal.syncSchema(&s);
    const table = try dal.table("VerItem");

    // 正常 upsert：先插后改
    const r1 = upsertRow("k1", 1);
    const inserted = try table.upsertBatch(&s, &[_][]const zcode.sqlbuild.Field{&r1}, .upsert);
    try std.testing.expectEqual(@as(usize, 1), inserted);

    const r2 = upsertRow("k1", 5);
    _ = try table.upsertBatch(&s, &[_][]const zcode.sqlbuild.Field{&r2}, .upsert);

    const first = try scan(&s, &table, a);
    try std.testing.expectEqual(@as(usize, 1), first.rows); // 冲突没插出第二行
    try std.testing.expectEqual(@as(i64, 5), first.qty);

    // **全列冲突**（只 upsert 主键，没有可更新列）：
    // 这里若生成 `ON CONFLICT (...) DO UPDATE SET` 后面空着就是语法错，必须退化为 `DO NOTHING`。
    // 主键用**显式值**构造：upsert 在 SQLite（rowid 先分配后回滚）/ MySQL（AUTO_INCREMENT 被消耗）
    // 上都会让自增号跳，写死或读回的 id 都不可靠。
    const seeded = [_]zcode.sqlbuild.Field{
        field("Id", .{ .int = 901 }),
        field("Code", .{ .text = "k9" }),
        field("Qty", .{ .int = 1 }),
    };
    _ = try table.insert(&s, &seeded);
    const id_only = [_]zcode.sqlbuild.Field{field("Id", .{ .int = 901 })};
    // **只写主键的 upsert 在 SQLite 上不可表达**（实测 3.49.1：`DO NOTHING` 不处理 rowid 冲突，
    // `DO UPDATE` 又没有列可写）→ 必须**明确报错**，而不是发一条注定失败的 SQL
    try std.testing.expectError(
        error.UpsertNeedsUpdatableColumn,
        table.upsertBatch(&s, &[_][]const zcode.sqlbuild.Field{&id_only}, .upsert),
    );

    // 表状态不能被这次失败的调用改动
    const after = try scan(&s, &table, a);
    try std.testing.expectEqual(@as(usize, 2), after.rows); // 原有 1 行 + 显式主键 1 行
    try std.testing.expectEqual(@as(i64, 5), after.qty); // 首行（Id 最小 = k1）的 Qty 不能被改掉
}

test "MySQL：探测版本 + 行别名 upsert（真库）+ 保守档对照（需 -Dmysql-conn）" {
    if (build_options.mysql_conn.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-conn，跳过 MySQL 版本/行别名用例\n", .{});
        return;
    }
    const a = std.testing.allocator;

    var dal = try openDal(a, build_options.mysql_conn);
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    const v = dal.serverVersion() orelse {
        std.debug.print("[FAIL] MySQL 版本探测没有结果\n", .{});
        return error.ProbeMissing;
    };
    const desc = try dal.describeServerAlloc();
    defer a.free(desc);
    std.debug.print("[INFO] MySQL 服务端：{s}\n", .{desc});

    // 能力判定必须与服务端版本一致（MariaDB 即便 10.x 也必须关掉行别名）
    const f = dal.features();
    const expect_alias = v.flavor != .mariadb and v.atLeast(.{ 8, 0, 19 });
    try std.testing.expectEqual(expect_alias, f.mysql_row_alias);

    _ = try dal.syncSchema(&s);
    const table = try dal.table("VerItem");
    _ = try table.delete(&s, null);

    // 1) 走**探测结果**（生产路径）：8.0.19+ 会生成行别名 SQL
    const r1 = upsertRow("m1", 1);
    try std.testing.expectEqual(@as(usize, 1), try table.upsertBatch(&s, &[_][]const zcode.sqlbuild.Field{&r1}, .upsert));
    const r2 = upsertRow("m1", 7);
    _ = try table.upsertBatch(&s, &[_][]const zcode.sqlbuild.Field{&r2}, .upsert);

    const first = try scan(&s, &table, a);
    try std.testing.expectEqual(@as(usize, 1), first.rows);
    try std.testing.expectEqual(@as(i64, 7), first.qty);

    // 2) 强制**保守档**（等价于 MariaDB / 5.7 路径）：`col = VALUES(col)` 也必须能跑通
    var legacy = try dal.table("VerItem");
    legacy.features = zcode.dialect.Features.conservative;
    const r3 = upsertRow("m1", 9);
    _ = try legacy.upsertBatch(&s, &[_][]const zcode.sqlbuild.Field{&r3}, .upsert);

    const second = try scan(&s, &table, a);
    try std.testing.expectEqual(@as(usize, 1), second.rows);
    try std.testing.expectEqual(@as(i64, 9), second.qty);

    // 3) 只写主键的 upsert：MySQL 严格模式下必失败（实测 ERROR 1364），必须**明确报错**
    const seeded = [_]zcode.sqlbuild.Field{
        field("Id", .{ .int = 902 }),
        field("Code", .{ .text = "m9" }),
        field("Qty", .{ .int = 1 }),
    };
    _ = try table.insert(&s, &seeded);
    const id_only = [_]zcode.sqlbuild.Field{field("Id", .{ .int = 902 })};
    try std.testing.expectError(
        error.UpsertNeedsUpdatableColumn,
        table.upsertBatch(&s, &[_][]const zcode.sqlbuild.Field{&id_only}, .upsert),
    );
}

test "PostgreSQL：探测版本 + INSERT ... RETURNING 回写自增 ID（需 -Dpg-conn）" {
    if (build_options.pg_conn.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dpg-conn，跳过 PostgreSQL RETURNING 用例\n", .{});
        return;
    }
    const a = std.testing.allocator;

    var dal = try openDal(a, build_options.pg_conn);
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    const v = dal.serverVersion() orelse {
        std.debug.print("[FAIL] PostgreSQL 版本探测没有结果\n", .{});
        return error.ProbeMissing;
    };
    const desc = try dal.describeServerAlloc();
    defer a.free(desc);
    std.debug.print("[INFO] PostgreSQL 服务端：{s}\n", .{desc});

    // `SHOW server_version` 返回 `16.2 (Debian ...)`：串里没有产品名，flavor 由连接串声明的
    // provider 补齐（否则 `describeServerAlloc` 会给出「不知道是什么库」的误导信息）
    try std.testing.expectEqual(zcode.dialect.ServerVersion.Flavor.postgresql, v.flavor);
    try std.testing.expect(v.atLeast(.{ 8, 2, 0 }));
    try std.testing.expect(dal.features().pg_returning);

    _ = try dal.syncSchema(&s);
    const table = try dal.table("VerItem");
    _ = try table.delete(&s, null);

    const r1 = upsertRow("p1", 3);
    // **关键断言**：PG 驱动没有 lastInsertId，能拿到 >0 的 ID 只可能来自 `RETURNING`
    const id = try table.insert(&s, &r1);
    try std.testing.expect(id > 0);

    const back = try table.findByPk(&s, &.{.{ .int = id }});
    const row = back orelse {
        std.debug.print("[FAIL] RETURNING 返回的 id={d} 查不到对应行\n", .{id});
        s.resetResults();
        return error.RowMissing;
    };
    const qty = row.values[2].asI64().?;
    s.resetResults();
    try std.testing.expectEqual(@as(i64, 3), qty);
}
