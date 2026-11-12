//! PostgreSQL **真库**集成用例（需 `-Dpg-conn=...`，未提供时显式 SKIP）。
//!
//! 与 `integration_pg.zig`（纯接线、不需要实例）互补：这里连**真的** PostgreSQL，
//! 覆盖只有真库才能证明的三件事：
//!
//! 1. **执行链路**：`syncSchema` 建表 → 插入 / 按主键取 / 更新 / 批量插 / 条件查询 / 计数 / 删除；
//! 2. **反向工程**：`reverse.readTables` + `modelXmlAlloc` 读回表结构（此前只有类型映射单测）；
//! 3. **SCRAM 鉴权**：可选再给一个 `-Dpg-conn-scram`（指向要求 `scram-sha-256` 的库）验证密码握手。
//!
//! 用法（先起项目内实例：`tools/pg-local.ps1 -Action setup`，它会打印两条连接串）：
//! ```text
//! zig build integration \
//!   -Dpg-conn="Provider=PostgreSQL;Server=127.0.0.1;Port=5433;Database=postgres;UserID=postgres;Password=" \
//!   -Dpg-conn-scram="Provider=PostgreSQL;Server=127.0.0.1;Port=5433;Database=zcode_it;UserID=postgres;Password=zcode_pwd"
//! ```
//!
//! 注：本仓 `pg-local.ps1` 的 pg_hba 是「`postgres` 库 trust、其它库 scram」，所以
//! 主流程用 trust 连接跑（任意库都行），SCRAM 单独用第二条连接串验证。

const std = @import("std");
const zcode = @import("zcode");
const build_options = @import("build_options");

const conn_str = build_options.pg_conn;
const scram_conn_str = build_options.pg_conn_scram;

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel>
    \\  <Option><ConnName>PG</ConnName></Option>
    \\  <Tables>
    \\    <Table Name="Demo" TableName="zcode_it_demo" Description="PG 真库用例表">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" PrimaryKey="True" />
    \\        <Column Name="Name" DataType="String" Length="50" />
    \\        <Column Name="Amount" DataType="Decimal" Precision="18" Scale="4" Nullable="True" />
    \\        <Column Name="CreateTime" DataType="DateTime" />
    \\      </Columns>
    \\      <Indexes>
    \\        <Index Name="IX_zcode_it_demo_name" Columns="Name" />
    \\      </Indexes>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

test "PostgreSQL 真库：建表 + CRUD + 批量插 + 反向工程" {
    if (conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dpg-conn（先跑 tools/pg-local.ps1 -Action setup，再带连接串）\n", .{});
        return error.SkipZigTest;
    }

    const a = std.testing.allocator;
    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = try zcode.Dal.initWithModel(a, conn_str, m);
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    try std.testing.expectEqual(zcode.DatabaseKind.postgresql, dal.opts.provider);

    // 1) 建表（幂等：第二次同步应当是 0 变更）
    const report = try dal.syncSchema(&s);
    try std.testing.expect(report.executed);
    const again = try dal.syncSchema(&s);
    try std.testing.expectEqual(
        @as(usize, 0),
        again.tables_created + again.columns_added + again.indexes_created,
    );

    const table = try dal.table("Demo");
    _ = try table.delete(&s, null);

    // 2) 单行插入 + 按主键取（顺带验证 decimal / datetime 在 PG 上的往返）
    const create_time = zcode.DateTime.fromUnixSeconds(1_700_000_000);
    {
        const fields = [_]zcode.sqlbuild.Field{
            .{ .name = "Id", .value = .{ .int = 1 } },
            .{ .name = "Name", .value = .{ .text = "悟空" } },
            .{ .name = "Amount", .value = .{ .decimal = try zcode.Decimal.parse("12.3400") } },
            .{ .name = "CreateTime", .value = .{ .datetime = create_time } },
        };
        _ = try table.insert(&s, &fields);
    }

    const found = (try table.findByPk(&s, &.{.{ .int = 1 }})).?;
    try std.testing.expectEqualStrings("悟空", found.get("Name").?.text);
    try std.testing.expectEqual(@as(i64, 12), found.get("Amount").?.decimal.toI64().?);
    try std.testing.expectEqual(create_time.toUnixSeconds(), found.get("CreateTime").?.datetime.toUnixSeconds());

    // 3) 更新 + 计数
    {
        const sets = [_]zcode.sqlbuild.Field{.{ .name = "Name", .value = .{ .text = "八戒" } }};
        var w = zcode.Where.init(a);
        defer w.deinit();
        _ = try w.eq("Id", .{ .int = 1 });
        const n = try table.update(&s, &sets, &w);
        try std.testing.expectEqual(@as(usize, 1), n);
    }
    try std.testing.expectEqual(@as(i64, 1), try table.count(&s, null));

    // 4) 批量插入（多行 VALUES）
    {
        var rows: [3][]const zcode.sqlbuild.Field = undefined;
        var storage: [3][3]zcode.sqlbuild.Field = undefined;
        for (0..3) |i| {
            storage[i] = .{
                .{ .name = "Id", .value = .{ .int = @intCast(i + 2) } },
                .{ .name = "Name", .value = .{ .text = "批量" } },
                .{ .name = "CreateTime", .value = .{ .datetime = create_time } },
            };
            rows[i] = &storage[i];
        }
        const n = try table.insertBatch(&s, &rows);
        try std.testing.expectEqual(@as(usize, 3), n);
    }
    try std.testing.expectEqual(@as(i64, 4), try table.count(&s, null));

    // 5) 条件查询 + 排序（PG 走扩展协议，参数为 text 格式）
    {
        var w = zcode.Where.init(a);
        defer w.deinit();
        _ = try w.eq("Name", .{ .text = "八戒" });
        var q = zcode.Query.init(a);
        defer q.deinit();
        _ = q.filterWhere(&w);
        _ = try q.orderBy("Id", false);
        const rows = try table.queryRows(&s, &q);
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows[0].get("Id").?.int);
    }

    // 6) 反向工程：读回刚才这张表的结构
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();

        const tables = try zcode.reverse.readTables(aa, &s, .{ .only = &.{"zcode_it_demo"} });
        try std.testing.expectEqual(@as(usize, 1), tables.len);
        const t = tables[0];
        try std.testing.expect(std.ascii.eqlIgnoreCase(t.name, "zcode_it_demo"));

        var saw_id = false;
        var saw_amount = false;
        for (t.columns) |col| {
            if (std.ascii.eqlIgnoreCase(col.name, "id")) {
                saw_id = true;
                try std.testing.expect(col.primary_key);
                try std.testing.expect(col.data_type == .int32);
            }
            if (std.ascii.eqlIgnoreCase(col.name, "amount")) {
                saw_amount = true;
                try std.testing.expect(col.data_type == .decimal);
            }
        }
        try std.testing.expect(saw_id and saw_amount);

        // 索引也读到了（用例自己建的 IX_zcode_it_demo_name）
        var saw_index = false;
        for (t.indexes) |idx| {
            for (idx.columns) |c| {
                if (std.ascii.eqlIgnoreCase(c, "name")) saw_index = true;
            }
        }
        try std.testing.expect(saw_index);

        // 生成的 Model.xml 能被再次解析
        const xml = try zcode.reverse.modelXmlAlloc(aa, &s, .{ .only = &.{"zcode_it_demo"} });
        try std.testing.expect(std.mem.indexOf(u8, xml, "zcode_it_demo") != null);
        var reparsed = try zcode.EntityModel.parse(a, xml);
        defer reparsed.deinit();
        try std.testing.expect(reparsed.table("zcode_it_demo") != null);
    }

    // 7) 清理
    _ = try table.delete(&s, null);
}

test "PostgreSQL 真库：scram-sha-256 鉴权（可选 -Dpg-conn-scram）" {
    if (scram_conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dpg-conn-scram，跳过密码鉴权验证\n", .{});
        return error.SkipZigTest;
    }

    const a = std.testing.allocator;
    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = try zcode.Dal.initWithModel(a, scram_conn_str, m);
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    const rows = try s.queryRows("SELECT 1", &.{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
}
