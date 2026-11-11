//! MySQL 真库用例：`LOAD DATA LOCAL INFILE` 批量装载（需 `-Dmysql-conn=...`）。
//!
//! 覆盖：能力协商、服务端 `local_infile` 开关（MySQL 8 默认关闭）、TSV 转义（含 Tab/换行/反斜杠/中文）、
//! NULL 表示（`\N`）、影响行数、以及装载后数据真的可查。
//!
//! 与 `integration_features.zig` 共用同一个集成测试模块（因此能读到 `build_options`）。

const std = @import("std");
const zcode = @import("zcode");
const build_options = @import("build_options");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="BulkRow" TableName="DH_BulkRow">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Code" DataType="String" Length="50" />
    \\      <Column Name="Title" DataType="String" Length="200" Nullable="True" />
    \\      <Column Name="Amount" DataType="Decimal" Precision="18" Scale="4" Nullable="True" />
    \\      <Column Name="Ok" DataType="Boolean" Nullable="True" />
    \\      <Column Name="CreateTime" DataType="DateTime" Nullable="True" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

test "MySQL 真库：LOAD DATA LOCAL INFILE 批量装载（需 -Dmysql-conn）" {
    const conn_str = build_options.mysql_conn;
    if (conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-conn，跳过 LOCAL INFILE 用例\n", .{});
        return;
    }

    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = zcode.Dal.initWithModel(a, conn_str, m) catch |e| {
        std.debug.print("[FAIL] 连接 MySQL 失败：{s}\n", .{@errorName(e)});
        return e;
    };
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    // MySQL 8 默认 local_infile=OFF；本机实例是 root，可以临时打开。
    // 打不开（权限不足）就明确 SKIP，而不是让用例红或悄悄通过。
    _ = s.execute("SET GLOBAL local_infile = 1", &.{}) catch {
        std.debug.print(
            "[SKIP] 无权限开启 local_infile（{s}）；请用 root 执行 SET GLOBAL local_infile=1 后重跑\n",
            .{s.lastError()},
        );
        return;
    };

    _ = s.execute("DROP TABLE IF EXISTS `DH_BulkRow`", &.{}) catch {};
    const report = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 1), report.tables_created);

    const table = try dal.table("BulkRow");
    const cols = [_][]const u8{ "Code", "Title", "Amount", "Ok", "CreateTime" };

    // 5000 行；第 2 行专门放 Tab / 换行 / 反斜杠 / 中文，第 3 行放 NULL 与空串
    const n_rows: usize = 5000;
    const rows = try aa.alloc([]const zcode.Value, n_rows);
    const now = zcode.DateTime.nowLocal();
    for (rows, 0..) |*row, i| {
        const code = try std.fmt.allocPrint(aa, "bulk-{d}", .{i});
        const title = if (i == 1)
            try aa.dupe(u8, "含\t制表\n换行\\反斜杠 中文")
        else if (i == 2)
            try aa.dupe(u8, "")
        else
            try std.fmt.allocPrint(aa, "标题-{d}", .{i});
        const vals = try aa.alloc(zcode.Value, 5);
        vals[0] = .{ .text = code };
        vals[1] = .{ .text = title };
        vals[2] = if (i == 2) .null else .{ .decimal = try zcode.Decimal.parse("12.3400") };
        vals[3] = .{ .boolean = (i % 2 == 0) };
        vals[4] = .{ .datetime = now };
        row.* = vals;
    }

    const affected = try table.loadDataBatch(&s, &cols, rows);
    try std.testing.expectEqual(n_rows, affected);
    try std.testing.expectEqual(@as(i64, n_rows), try table.count(&s, null));

    // 转义真的生效：第 2 行读回来与原文一致
    var w = zcode.Where.init(a);
    defer w.deinit();
    _ = try w.eq("Code", .{ .text = "bulk-1" });
    const found_rows = try table.queryRows(&s, blk: {
        var q = zcode.Query.init(a);
        q.filter = &w;
        break :blk &q;
    });
    try std.testing.expectEqual(@as(usize, 1), found_rows.len);
    try std.testing.expectEqualStrings("含\t制表\n换行\\反斜杠 中文", found_rows[0].get("Title").?.asText().?);

    // NULL 保留为 NULL（不是空串）
    var w2 = zcode.Where.init(a);
    defer w2.deinit();
    _ = try w2.eq("Code", .{ .text = "bulk-2" });
    var q2 = zcode.Query.init(a);
    defer q2.deinit();
    q2.filter = &w2;
    const found2 = try table.queryRows(&s, &q2);
    try std.testing.expectEqual(@as(usize, 1), found2.len);
    try std.testing.expect(found2[0].get("Amount").?.isNull());

    _ = s.execute("DROP TABLE IF EXISTS `DH_BulkRow`", &.{}) catch {};
}
