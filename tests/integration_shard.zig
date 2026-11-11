//! 分表完整性用例：**跨库分片 + 分片表自动建表**。
//!
//! 场景：`ConnPolicy="{0}_{1:yyyy}"` 让不同年份的数据落到**不同数据库**（两个 SQLite 文件），
//! 对应 C# `TimeShardPolicy.ConnPolicy` 的分库语义。用两个真实库文件验证：
//! 写入确实进了对应文件、分片表按基础表结构自动建出来、没挂载的连接明确报错。

const std = @import("std");
const zcode = @import("zcode");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="Log" TableName="DH_Log">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Title" DataType="String" Length="50" />
    \\      <Column Name="CreateTime" DataType="DateTime" Nullable="True" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

fn tempDbPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    return zcode.File.UniqueTempName(a, tag, ".db");
}

test "跨库分片：按 ConnPolicy 写入不同库文件，分片表自动建表" {
    const a = std.testing.allocator;

    const main_path = try tempDbPath(a, "shardmain");
    defer a.free(main_path);
    defer zcode.File.DeleteQuiet(main_path);
    const y2023_path = try tempDbPath(a, "shard2023");
    defer a.free(y2023_path);
    defer zcode.File.DeleteQuiet(y2023_path);
    const y2024_path = try tempDbPath(a, "shard2024");
    defer a.free(y2024_path);
    defer zcode.File.DeleteQuiet(y2024_path);

    const main_conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{main_path});
    defer a.free(main_conn);
    const y2023_conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{y2023_path});
    defer a.free(y2023_conn);
    const y2024_conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{y2024_path});
    defer a.free(y2024_conn);

    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = try zcode.Dal.initWithModel(a, main_conn, m);
    defer dal.deinit();

    // 主库建基础表
    {
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    // 挂两个「年度库」（连接名与 ConnPolicy 渲染结果一致：DH_2023 / DH_2024）
    try dal.attachConnection("DH_2023", y2023_conn);
    try dal.attachConnection("DH_2024", y2024_conn);
    try std.testing.expectEqual(@as(usize, 2), dal.connectionCount());

    try dal.addShardPolicy("Log", .{
        .gpa = a,
        .field = "CreateTime",
        .base_conn = "DH",
        .base_table = "DH_Log",
        .conn_policy = "{0}_{1:yyyy}",
        .table_policy = "{0}_{1:yyyy}",
        .step_ms = 365 * zcode.shards.day_ms,
        .level = .year,
    });

    // 2024：路由到 DH_2024 库的 DH_Log_2024 表
    const m2024 = try dal.shardOfTable("Log", .{ .datetime = .{ .year = 2024, .month = 5, .day = 6 } });
    defer m2024.deinit(a);
    try std.testing.expectEqualStrings("DH_2024", m2024.conn_name);
    try std.testing.expectEqualStrings("DH_Log_2024", m2024.table_name);

    // 自动建表（第一次 1 = 新建，第二次 0 = 已存在）
    try std.testing.expectEqual(@as(usize, 1), try dal.ensureShardTable("Log", m2024));
    try std.testing.expectEqual(@as(usize, 0), try dal.ensureShardTable("Log", m2024));

    // 写入 2024 分片（会话必须来自分片所属连接）
    {
        var s = try dal.sessionForConn(m2024.conn_name);
        defer s.deinit();
        const t = try dal.tableShardOn("Log", m2024);
        _ = try t.insert(&s, &.{.{ .name = "Title", .value = .{ .text = "y2024" } }});
    }

    // 2023 分片同样写一条
    const m2023 = try dal.shardOfTable("Log", .{ .datetime = .{ .year = 2023, .month = 1, .day = 2 } });
    defer m2023.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), try dal.ensureShardTable("Log", m2023));
    {
        var s = try dal.sessionForConn(m2023.conn_name);
        defer s.deinit();
        const t = try dal.tableShardOn("Log", m2023);
        _ = try t.insert(&s, &.{.{ .name = "Title", .value = .{ .text = "y2023" } }});
    }

    // 断言：数据各自落在对应文件里（主库的 DH_Log 一条都没有）
    {
        var s = try dal.openSession();
        defer s.deinit();
        const base = try dal.table("Log");
        try std.testing.expectEqual(@as(i64, 0), try base.count(&s, null));
    }
    {
        var s = try dal.sessionForConn("DH_2024");
        defer s.deinit();
        const rows = try s.queryRows("SELECT Title FROM DH_Log_2024", &.{});
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqualStrings("y2024", rows[0].values[0].asText().?);
    }
    {
        var s = try dal.sessionForConn("DH_2023");
        defer s.deinit();
        const rows = try s.queryRows("SELECT Title FROM DH_Log_2023", &.{});
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqualStrings("y2023", rows[0].values[0].asText().?);
    }
}

test "跨库分片：未挂载的连接明确报错（不静默写主库）" {
    const a = std.testing.allocator;
    const main_path = try tempDbPath(a, "shardu");
    defer a.free(main_path);
    defer zcode.File.DeleteQuiet(main_path);
    const main_conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{main_path});
    defer a.free(main_conn);

    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = try zcode.Dal.initWithModel(a, main_conn, m);
    defer dal.deinit();

    try dal.addShardPolicy("Log", .{
        .gpa = a,
        .field = "CreateTime",
        .base_conn = "DH",
        .base_table = "DH_Log",
        .conn_policy = "{0}_{1:yyyy}",
        .table_policy = "{0}_{1:yyyy}",
        .step_ms = 365 * zcode.shards.day_ms,
        .level = .year,
    });

    const sm = try dal.shardOfTable("Log", .{ .datetime = .{ .year = 2024, .month = 1, .day = 1 } });
    var owned = sm;
    defer owned.deinit(a);
    try std.testing.expectEqualStrings("DH_2024", owned.conn_name);

    // 没 attachConnection("DH_2024") → 取表句柄直接报错
    try std.testing.expectError(error.UnknownConnection, dal.tableShardOn("Log", owned));
    // 取会话同样报错
    try std.testing.expectError(error.UnknownConnection, dal.sessionForConn("DH_2024"));
}
