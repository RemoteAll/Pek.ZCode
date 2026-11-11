//! 集成测试：真实 SQLite（动态加载 DLL）上的端到端链路。
//!
//! 覆盖：`Model.xml` 解析 → 增量建表 → 插入/按主键取/更新/分页查询/计数/删除，
//! 以及时间（XCode 7 位小数秒）与十进制（尾随零）在库里的往返。

const std = @import("std");
const zcode = @import("zcode");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
    \\  <Option><Namespace>Test.Entity</Namespace><ConnName>DH</ConnName></Option>
    \\  <Tables>
    \\    <Table Name="JiLiYu" TableName="DH_JiLiYu" Description="激励语">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Code" DataType="String" Length="50" Master="True" Description="编码" />
    \\        <Column Name="Title" DataType="String" Description="标题" />
    \\        <Column Name="Amount" DataType="Decimal" Precision="18" Scale="4" />
    \\        <Column Name="Ok" DataType="Boolean" />
    \\        <Column Name="CreateTime" DataType="DateTime" />
    \\      </Columns>
    \\      <Indexes>
    \\        <Index Columns="Code" Unique="True" />
    \\        <Index Columns="CreateTime" />
    \\      </Indexes>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

fn openDal(a: std.mem.Allocator, db_path: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

/// 在临时目录下生成唯一库文件路径（调用方负责 free + 删文件）。
fn tempDbPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    return zcode.File.UniqueTempName(a, tag, ".db");
}

test "端到端：建表 → CRUD → 分页 → 聚合" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "crud");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = openDal(a, db_path) catch |e| {
        std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    const report = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 1), report.tables_created);
    try std.testing.expectEqual(@as(usize, 2), report.indexes_created);

    const table = try dal.table("JiLiYu");

    // 插入两行
    const now = zcode.DateTime.nowLocal();
    const id1 = try table.insert(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Code", .value = .{ .text = "k1" } },
        .{ .name = "Title", .value = .{ .text = "第一条" } },
        .{ .name = "Amount", .value = .{ .decimal = try zcode.Decimal.parse("12.3400") } },
        .{ .name = "Ok", .value = .{ .boolean = true } },
        .{ .name = "CreateTime", .value = .{ .datetime = now } },
    });
    try std.testing.expectEqual(@as(i64, 1), id1);

    _ = try table.insert(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Code", .value = .{ .text = "k2" } },
        .{ .name = "Title", .value = .{ .text = "第二条" } },
        .{ .name = "Amount", .value = .{ .decimal = try zcode.Decimal.parse("0") } },
        .{ .name = "Ok", .value = .{ .boolean = false } },
        .{ .name = "CreateTime", .value = .{ .datetime = now } },
    });

    // 计数
    try std.testing.expectEqual(@as(i64, 2), try table.count(&s, null));

    // 按主键取
    const row = (try table.findByPk(&s, &.{.{ .int = id1 }})).?;
    try std.testing.expectEqualStrings("k1", row.get("Code").?.text);
    try std.testing.expect(row.get("Ok").?.boolean);
    // 十进制：SQLite 的 `decimal` 列是 NUMERIC 亲和度，尾随零在存储层就丢了（C# 同样如此），
    // 这里断言的是**数值相等**，不是文本逐字相等。
    const amount = row.get("Amount").?.asDecimal().?;
    try std.testing.expect(amount.eql(try zcode.Decimal.parse("12.34")));
    // 时间按 7 位小数秒往返
    const dt = row.get("CreateTime").?.datetime;
    try std.testing.expectEqual(now.year, dt.year);
    try std.testing.expectEqual(now.month, dt.month);
    try std.testing.expectEqual((now.nanos / 100) * 100, (dt.nanos / 100) * 100);

    // 条件查询 + 分页（按 Status 不存在，用 Ok 条件）
    var w = zcode.Where.init(a);
    defer w.deinit();
    _ = try w.eq("Ok", .{ .boolean = true });

    var q = zcode.Query.init(a);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = try q.orderBy("Id", false);
    _ = q.page(1, 10);

    const rows = try table.queryRows(&s, &q);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("k1", rows[0].get("Code").?.text);

    // 更新
    var uw = zcode.Where.init(a);
    defer uw.deinit();
    _ = try uw.eq("Id", .{ .int = id1 });
    const affected = try table.update(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Title", .value = .{ .text = "改过" } },
    }, &uw);
    try std.testing.expectEqual(@as(usize, 1), affected);

    const row2 = (try table.findByPk(&s, &.{.{ .int = id1 }})).?;
    try std.testing.expectEqualStrings("改过", row2.get("Title").?.text);

    // 删除
    const deleted = try table.delete(&s, &uw);
    try std.testing.expectEqual(@as(usize, 1), deleted);
    try std.testing.expectEqual(@as(i64, 1), try table.count(&s, null));
}

test "二次 sync_schema 幂等，且新增列自动补齐" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "evolve");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    {
        var dal = try openDal(a, db_path);
        defer dal.deinit();
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    // 模型新增一列 → 再次同步应补列（不重建表、不动历史数据）
    const evolved_xml =
        \\<EntityModel><Tables><Table Name="JiLiYu" TableName="DH_JiLiYu">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Code" DataType="String" Length="50" Master="True" />
        \\    <Column Name="Extra" DataType="String" Length="20" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m2 = try zcode.EntityModel.parse(a, evolved_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);
    var dal2 = try zcode.Dal.initWithModel(a, conn, m2);
    defer dal2.deinit();

    var s2 = try dal2.openSession();
    defer s2.deinit();
    const r2 = try dal2.syncSchema(&s2);
    try std.testing.expectEqual(@as(usize, 0), r2.tables_created);
    try std.testing.expectEqual(@as(usize, 1), r2.columns_added);
}
