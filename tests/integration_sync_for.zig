//! `syncSchemaFor` / `syncSchemaForAny`：按连接过滤建表（对齐 Rust `Pek.RCode::sync_schema_for`）。
//!
//! 模型里两张表：
//! - `SyncFor_Main`：**无表级 `ConnName`** → 归属模型级连接 `Main`；
//! - `SyncFor_Second`：表级 `ConnName="Second"` → 覆盖到附加连接。
//!
//! 断言过滤语义、跨库落点、幂等性。每个测试用**独立的临时目录**，
//! 不依赖共享的临时文件名（并行跑测试时不会互踩库文件）。

const std = @import("std");
const zcode = @import("zcode");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd" Version="1.0">
    \\  <Option><ConnName>Main</ConnName><Output>Entity</Output><Namespace>SyncFor.Entity</Namespace></Option>
    \\  <Tables>
    \\    <Table Name="MainRow" TableName="SyncFor_Main" Description="归属模型级连接">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Name" DataType="String" Length="64" Nullable="True" />
    \\      </Columns>
    \\    </Table>
    \\    <Table Name="SecondRow" TableName="SyncFor_Second" ConnName="Second" Description="表级连接覆盖">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Val" DataType="String" Length="64" Nullable="True" />
    \\      </Columns>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

/// 唯一临时库文件名（纳秒时间戳 + 进程内原子计数器，调用方负责释放并删除）。
fn tempDbPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    return zcode.File.UniqueTempName(a, tag, ".db");
}

fn connStr(a: std.mem.Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
}

/// 该会话所在库里是否存在指定表（字面量 SQL：表名全部来自本文件常量）。
fn tableExists(s: *zcode.Session, name: []const u8) !bool {
    const sql = try std.fmt.allocPrint(std.testing.allocator, "SELECT name FROM sqlite_master WHERE type='table' AND name='{s}'", .{name});
    defer std.testing.allocator.free(sql);
    const rows = try s.queryRows(sql, &.{});
    return rows.len == 1;
}

test "syncSchemaFor：只建归属指定连接的表（表级 ConnName 命中 / 模型级开关）" {
    const a = std.testing.allocator;

    const main_path = try tempDbPath(a, "syncfor-main");
    defer a.free(main_path);
    defer zcode.File.DeleteQuiet(main_path);
    const second_path = try tempDbPath(a, "syncfor-second");
    defer a.free(second_path);
    defer zcode.File.DeleteQuiet(second_path);

    const main_cs = try connStr(a, main_path);
    defer a.free(main_cs);

    var dal = zcode.Dal.initWithModel(a, main_cs, try zcode.EntityModel.parse(a, model_xml)) catch |e| {
        std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer dal.deinit();

    const second_cs = try connStr(a, second_path);
    defer a.free(second_cs);
    try dal.attachConnection("Second", second_cs);
    try std.testing.expectEqual(@as(usize, 1), dal.connectionCount());

    var s = try dal.openSession();
    defer s.deinit();

    // ① 只建 Main 连接的表：MainRow 建、SecondRow 被过滤跳过
    const r1 = try dal.syncSchemaFor(&s, "Main", true);
    try std.testing.expectEqual(@as(usize, 1), r1.tables_created);
    try std.testing.expectEqual(@as(usize, 1), r1.tables_skipped);
    try std.testing.expect(try tableExists(&s, "SyncFor_Main"));

    var s2 = try dal.sessionForConn("Second");
    defer s2.deinit();
    try std.testing.expect(!try tableExists(&s2, "SyncFor_Second"));

    // ② 连接名大小写不敏感（与模型比对口径一致）
    const r2 = try dal.syncSchemaFor(&s, "second", false);
    try std.testing.expectEqual(@as(usize, 1), r2.tables_created);
    // MainRow 无表级 ConnName 且 include_model_level=false → 跳过
    try std.testing.expectEqual(@as(usize, 1), r2.tables_skipped);
    try std.testing.expect(try tableExists(&s2, "SyncFor_Second"));
    try std.testing.expect(try tableExists(&s, "SyncFor_Main")); // Main 库不受影响

    // ③ 幂等：再跑一次不再建表
    const r3 = try dal.syncSchemaFor(&s, "Main", true);
    try std.testing.expectEqual(@as(usize, 0), r3.tables_created);
    try std.testing.expectEqual(@as(usize, 0), r3.columns_added);
    try std.testing.expectEqual(@as(usize, 0), r3.indexes_created);

    // ④ 目标连接名匹配不到任何表 → 表级表全部跳过，**不去连未挂载的连接**
    //    （过滤先于路由：`Ghost` 不在模型里出现，所以不会报 UnknownConnection）
    //    注意 `include_model_level=true` 时模型级表照常处理，与被查连接名无关。
    const r4 = try dal.syncSchemaFor(&s, "Ghost", true);
    try std.testing.expectEqual(@as(usize, 0), r4.tables_created);
    try std.testing.expectEqual(@as(usize, 1), r4.tables_skipped); // 只有表级的 SecondRow
}

test "syncSchemaForAny：多个连接别名命中任一即归属；空列表 = 不过滤" {
    const a = std.testing.allocator;

    const main_path = try tempDbPath(a, "syncforany-main");
    defer a.free(main_path);
    defer zcode.File.DeleteQuiet(main_path);
    const second_path = try tempDbPath(a, "syncforany-second");
    defer a.free(second_path);
    defer zcode.File.DeleteQuiet(second_path);

    const main_cs = try connStr(a, main_path);
    defer a.free(main_cs);

    var dal = zcode.Dal.initWithModel(a, main_cs, try zcode.EntityModel.parse(a, model_xml)) catch |e| {
        std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer dal.deinit();
    const second_cs = try connStr(a, second_path);
    defer a.free(second_cs);
    try dal.attachConnection("Second", second_cs);

    var s = try dal.openSession();
    defer s.deinit();

    // 别名链：Second 在列表里 → SecondRow 归属；MainRow 因 include_model_level=false 跳过
    const r1 = try dal.syncSchemaForAny(&s, &.{ "AliasA", "Second", "AliasB" }, false);
    try std.testing.expectEqual(@as(usize, 1), r1.tables_created);
    try std.testing.expectEqual(@as(usize, 1), r1.tables_skipped);

    var s2 = try dal.sessionForConn("Second");
    defer s2.deinit();
    try std.testing.expect(try tableExists(&s2, "SyncFor_Second"));
    try std.testing.expect(!try tableExists(&s, "SyncFor_Main"));

    // 空列表 = 不按连接过滤 → 等价全量：把还没建的 MainRow 补上
    const r2 = try dal.syncSchemaForAny(&s, &.{}, true);
    try std.testing.expectEqual(@as(usize, 1), r2.tables_created); // MainRow
    try std.testing.expectEqual(@as(usize, 0), r2.tables_skipped);
    try std.testing.expect(try tableExists(&s, "SyncFor_Main"));

    // conn_name = null 等同不过滤
    const r3 = try dal.syncSchemaFor(&s, null, false);
    try std.testing.expectEqual(@as(usize, 0), r3.tables_skipped);
    try std.testing.expectEqual(@as(usize, 0), r3.tables_created);
}
