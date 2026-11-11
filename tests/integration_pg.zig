//! PostgreSQL 接线的集成用例：连接串解析、端口回落、初始化期校验。
//!
//! 协议层（握手 / MD5 / SCRAM / 简单与扩展查询）由 `zzig` 的回环假服务端用例覆盖
//! （`zzig/src/db/postgres_loopback_test.zig`），本文件只验证 **ZCode 侧接线**：
//! `Provider=PostgreSQL` 能否被正确识别、端口是否回落到 5432、缺库名是否在
//! 初始化阶段就报错（而不是拖到第一次查询）。

const std = @import("std");
const zcode = @import("zcode");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="Pg" TableName="pg_demo">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

test "PostgreSQL：连接串键名（Server/Port/Database/UserID/Password）被正确解析" {
    const a = std.testing.allocator;

    var opts = try zcode.parseConnectionString(
        a,
        "Provider=PostgreSQL;Server=127.0.0.1;Port=5433;Database=demo;UserID=pg;Password=pg_pwd",
    );
    defer opts.deinit(a);

    try std.testing.expectEqual(zcode.DatabaseKind.postgresql, opts.provider);
    try std.testing.expectEqual(@as(u16, 5433), opts.port);
    try std.testing.expectEqualStrings("127.0.0.1", opts.server);
    try std.testing.expectEqualStrings("demo", opts.database);
    try std.testing.expectEqualStrings("pg", opts.user);
    try std.testing.expectEqualStrings("pg_pwd", opts.password);
}

test "PostgreSQL：未写 Port 时回落到 5432（不能沿用 MySQL 的 3306）" {
    const a = std.testing.allocator;
    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = try zcode.Dal.initWithModel(
        a,
        "Provider=PostgreSQL;Server=127.0.0.1;Database=demo;UserID=pg;Password=pg",
        m,
    );
    defer dal.deinit();

    try std.testing.expectEqual(zcode.DatabaseKind.postgresql, dal.opts.provider);
    try std.testing.expectEqual(@as(u16, 5432), dal.opts.port);
    // PG 走 TCP，适合池化（真正建连发生在 acquire）
    try std.testing.expect(dal.supportsPooling());
}

test "PostgreSQL：缺 Database 时初始化即报错（不拖到第一次查询）" {
    const a = std.testing.allocator;
    const m = try zcode.EntityModel.parse(a, model_xml);
    try std.testing.expectError(
        error.NoDatabase,
        zcode.Dal.initWithModel(a, "Provider=PostgreSQL;Server=127.0.0.1;UserID=pg;Password=pg", m),
    );
}
