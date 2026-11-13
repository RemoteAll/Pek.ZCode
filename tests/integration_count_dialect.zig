//! 真库用例：行数判定的三种方言 + 整表缓存的装载上限。
//!
//! 为什么单独一个文件：`countUpTo` / `countApprox` 都是**方言相关 SQL**
//! （`LIMIT ?` 子查询 / `TOP(n)` / `ROWNUM`、`information_schema` / `pg_class` / `sqlite_stat1`），
//! 只在 SQLite 上验证过等于没验证。SQLite 总是跑；MySQL / PostgreSQL 只在给了
//! `-Dmysql-conn` / `-Dpg-conn` 时跑（未给时显式 SKIP，不是静默跳过）。

const std = @import("std");
const zcode = @import("zcode");
const build_options = @import("build_options");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="Probe" TableName="zcode_probe" MaxCacheCount="3">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

const Probe = struct {
    dirty: zcode.entity.DirtyBits = 0,
    Id: i32 = 0,
    Name: []const u8 = "",

    pub const meta = zcode.entity.EntityMeta{
        .name = "Probe",
        .table_name = "zcode_probe",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "Name", .data_type = .string },
        },
    };

    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = self.Id },
            1 => .{ .text = self.Name },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => self.Id = v.asI32() orelse 0,
            1 => self.Name = if (v == .text) v.text else "",
            else => {},
        }
    }
};

fn openDal(a: std.mem.Allocator, conn: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    return zcode.Dal.initWithModel(a, conn, m);
}

/// 三种方言共用的一套断言。
///
/// `expect_approx`：该方言是否必须能读到统计估算（MySQL 的 `information_schema.TABLE_ROWS`
/// 总是有值；SQLite 要跑过 `ANALYZE`、PG 要 autoanalyze，所以不强求）。
fn exercise(dal: *zcode.Dal, s: *zcode.Session, expect_approx: bool) !void {
    // 干净起点（表可能残留上次的数据）
    const table = try dal.table("Probe");
    _ = try table.delete(s, null);

    for (0..5) |i| {
        const name = try std.fmt.allocPrint(s.resultAllocator(), "n{d}", .{i});
        _ = try table.insert(s, &.{.{ .name = "Name", .value = .{ .text = name } }});
    }

    // countUpTo：恒定成本，min(行数, limit)
    try std.testing.expectEqual(@as(i64, 3), try dal.countUpTo(s, "Probe", 3));
    try std.testing.expectEqual(@as(i64, 5), try dal.countUpTo(s, "Probe", 100));
    try std.testing.expectEqual(@as(i64, 0), try dal.countUpTo(s, "Probe", 0));

    // 精确计数
    try std.testing.expectEqual(@as(i64, 5), try dal.countRows(s, "Probe"));

    // countTotal：小表（floor 很大）走精确
    const old = zcode.setting.snapshot();
    defer zcode.setting.restore(old);
    zcode.setting.current().full_count_floor = 1000;
    try std.testing.expectEqual(@as(i64, 5), try dal.countTotal(s, "Probe"));

    // countTotal：表比 floor 大 → 先试统计；统计拿不到就退回精确，两个分支结果都必须对
    zcode.setting.current().full_count_floor = 1;
    try std.testing.expectEqual(@as(i64, 5), try dal.countTotal(s, "Probe"));

    // countApprox 允许返回 null（没跑过 ANALYZE/统计未收集），但给了值就必须合理
    const est = try dal.countApprox(s, "zcode_probe");
    if (est) |v| {
        try std.testing.expect(v >= 0);
        std.debug.print("[countApprox] {s} 统计估算 = {d}\n", .{ "zcode_probe", v });
    } else {
        std.debug.print("[countApprox] {s} 无统计信息（按 null 处理）\n", .{"zcode_probe"});
        try std.testing.expect(!expect_approx);
    }

    // 整表缓存：MaxCacheCount=3 < 5 行 → 一行不留（内存上限与表大小无关）
    var c = zcode.cache.Cache(Probe).init(dal, 600);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 5), (try c.all(s)).len);
    try std.testing.expect(!c.usingCache());
    try std.testing.expectEqual(@as(usize, 0), c.cachedRows());
    try std.testing.expectEqual(@as(usize, 1), c.stats().over_limit);

    // 删到 3 行 → 静默期过后可正常缓存（这里直接把静默期清零，等价于「60 秒后」）
    _ = try table.delete(s, null);
    for (0..3) |i| {
        const name = try std.fmt.allocPrint(s.resultAllocator(), "m{d}", .{i});
        _ = try table.insert(s, &.{.{ .name = "Name", .value = .{ .text = name } }});
    }
    c.over_limit_until = 0;
    try std.testing.expectEqual(@as(usize, 3), (try c.all(s)).len);
    try std.testing.expect(c.usingCache());
    try std.testing.expectEqual(@as(usize, 3), c.cachedRows());
}

test "SQLite：countUpTo / countApprox / countTotal / 缓存装载上限" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "count_dialect", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{path});
    defer a.free(conn);
    var dal = try openDal(a, conn);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);
    try exercise(&dal, &s, false);
}

test "MySQL：countUpTo / countApprox / countTotal / 缓存装载上限（需 -Dmysql-conn）" {
    if (build_options.mysql_conn.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-conn，跳过 MySQL 行数判定用例\n", .{});
        return;
    }
    const a = std.testing.allocator;
    var dal = try openDal(a, build_options.mysql_conn);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);
    try exercise(&dal, &s, true);
}

test "PostgreSQL：countUpTo / countApprox / countTotal / 缓存装载上限（需 -Dpg-conn）" {
    if (build_options.pg_conn.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dpg-conn，跳过 PostgreSQL 行数判定用例\n", .{});
        return;
    }
    const a = std.testing.allocator;
    var dal = try openDal(a, build_options.pg_conn);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    // PostgreSQL 的表名小写、库共享：先删表保证结构干净
    _ = s.execute("DROP TABLE IF EXISTS zcode_probe", &[_]zcode.Value{}) catch 0;
    _ = try dal.syncSchema(&s);
    try exercise(&dal, &s, false);
}
