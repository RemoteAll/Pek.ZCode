//! 集成测试（第三批）：统计累加（`stat`）与数据抽取器（`extract`）。
//!
//! 全部在真实 SQLite 临时库上跑：建表 → 写数据 → 抽取 / 累加 → 回读断言。
//! 断言口径都是「值与行数」，不依赖日志文本。

const std = @import("std");
const zcode = @import("zcode");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
    \\  <Option><Namespace>Test.Entity</Namespace><ConnName>DH</ConnName></Option>
    \\  <Tables>
    \\    <Table Name="Stat" TableName="DH_Stat">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Level" DataType="Int32" />
    \\        <Column Name="Time" DataType="DateTime" />
    \\        <Column Name="Total" DataType="Int64" Additional="True" />
    \\        <Column Name="Hits" DataType="Int32" Additional="True" />
    \\        <Column Name="Peak" DataType="Int32" Additional="True" Nullable="True" />
    \\        <Column Name="Low" DataType="Int32" Additional="True" Nullable="True" />
    \\        <Column Name="CreateTime" DataType="DateTime" Nullable="True" />
    \\        <Column Name="UpdateTime" DataType="DateTime" Nullable="True" />
    \\      </Columns>
    \\      <Indexes><Index Columns="Level,Time" Unique="True" /></Indexes>
    \\    </Table>
    \\    <Table Name="Item" TableName="DH_Item">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Name" DataType="String" Length="50" Nullable="True" />
    \\        <Column Name="CreateTime" DataType="DateTime" Nullable="True" />
    \\      </Columns>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

fn tempDbPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    return zcode.File.UniqueTempName(a, tag, ".db");
}

fn openDalFile(a: std.mem.Allocator, db_path: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

// ───────────────────────── 统计累加 ─────────────────────────

test "统计：累加字段按 SQL 原子累加（sum / count / max / min）" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "stat");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("Stat");

    // 模型声明成累加字段了吗？
    const adds = try table.table.additionalFields(a);
    defer a.free(adds);
    try std.testing.expectEqual(@as(usize, 4), adds.len);

    var repo = zcode.stat.Repository.init(table);

    // 2024-03-15 10:37:22 的「日」层级 → 库里应存 2024-03-15 00:00:00 / Level=3
    const day_dt = try zcode.DateTime.parse("2024-03-15 10:37:22");
    const model = zcode.stat.StatModel.at(day_dt, .day);

    const insert_fields = [_]zcode.sqlbuild.Field{
        .{ .name = "Total", .value = .{ .int = 0 } },
        .{ .name = "Hits", .value = .{ .int = 0 } },
        .{ .name = "Peak", .value = .{ .int = 0 } },
        // 最小值字段的初值取一个大数：min(999, 3) = 3，才能验证「取小」而不是「保持初值」
        .{ .name = "Low", .value = .{ .int = 999 } },
    };

    // 第一次：Total += 5，Hits += 1（count），Peak = max(0,7)，Low = min(0,3)
    var affected = try repo.addValues(&s, model, &insert_fields, &[_]zcode.stat.Entry{
        .{ .column = "Total", .value = .{ .int = 5 }, .mode = .sum },
        .{ .column = "Hits", .mode = .count },
        .{ .column = "Peak", .value = .{ .int = 7 }, .mode = .max },
        .{ .column = "Low", .value = .{ .int = 3 }, .mode = .min },
    });
    try std.testing.expectEqual(@as(usize, 1), affected);

    // 第二次：Total += 3，Hits += 1，Peak = max(7,2)=7，Low = min(3,9)=3
    affected = try repo.addValues(&s, model, &insert_fields, &[_]zcode.stat.Entry{
        .{ .column = "Total", .value = .{ .int = 3 }, .mode = .sum },
        .{ .column = "Hits", .mode = .count },
        .{ .column = "Peak", .value = .{ .int = 2 }, .mode = .max },
        .{ .column = "Low", .value = .{ .int = 9 }, .mode = .min },
    });
    try std.testing.expectEqual(@as(usize, 1), affected);

    // 只有一个统计行（唯一索引生效：同一层级同一时间只累加不新增）
    try std.testing.expectEqual(@as(i64, 1), try table.count(&s, null));

    const row = (try repo.find(&s, model)).?;
    try std.testing.expectEqual(@as(i64, 8), row.get("Total").?.asI64().?);
    try std.testing.expectEqual(@as(i64, 2), row.get("Hits").?.asI64().?);
    try std.testing.expectEqual(@as(i64, 7), row.get("Peak").?.asI64().?);
    try std.testing.expectEqual(@as(i64, 3), row.get("Low").?.asI64().?);

    // 时间按层级截断后落库
    const stored = row.get("Time").?.asDatetime().?;
    try std.testing.expectEqual(@as(u8, 0), stored.hour);
    try std.testing.expectEqual(@as(u8, 15), stored.day);
    try std.testing.expectEqual(@as(u8, 3), @as(u8, @intCast(row.get("Level").?.asI64().?)));

    // 不同层级 = 不同行：小时层级单独一行
    const hour_model = zcode.stat.StatModel.at(day_dt, .hour);
    _ = try repo.addValues(&s, hour_model, &insert_fields, &[_]zcode.stat.Entry{
        .{ .column = "Total", .value = .{ .int = 1 }, .mode = .sum },
    });
    try std.testing.expectEqual(@as(i64, 2), try table.count(&s, null));

    // avg 明确报错（不静默算出个错的）
    try std.testing.expectError(error.Unsupported, repo.accumulate(&s, model, &[_]zcode.stat.Entry{
        .{ .column = "Total", .mode = .avg },
    }));
}

// ───────────────────────── 抽取器 ─────────────────────────

fn seedItems(table: *const zcode.dbtable.TableRef, s: *zcode.session.Session, count: usize) !void {
    var i: usize = 1;
    while (i <= count) : (i += 1) {
        const name = try std.fmt.allocPrint(s.resultAllocator(), "n-{d}", .{i});
        _ = try table.insert(s, &[_]zcode.sqlbuild.Field{
            .{ .name = "Name", .value = .{ .text = name } },
        });
    }
}

test "抽取：IdExtractor 按主键步进，批大小与总数正确" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "extract-id");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("Item");
    try seedItems(&table, &s, 25);

    var ex = zcode.extract.IdExtractor.init(table, "Id");
    ex.batch_size = 10;

    var batches: usize = 0;
    var sizes = [_]usize{ 0, 0, 0, 0 };
    var last_id: i64 = 0;
    while (try ex.next(&s)) |rows| {
        try std.testing.expect(batches < sizes.len);
        sizes[batches] = rows.len;
        // 批内与跨批都必须严格递增（主键步进的前提）
        for (rows) |row| {
            const id = row.get("Id").?.asI64().?;
            try std.testing.expect(id > last_id);
            last_id = id;
        }
        batches += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), batches);
    try std.testing.expectEqual(@as(usize, 10), sizes[0]);
    try std.testing.expectEqual(@as(usize, 10), sizes[1]);
    try std.testing.expectEqual(@as(usize, 5), sizes[2]);
    try std.testing.expectEqual(@as(usize, 25), ex.total);
    try std.testing.expect(ex.done);
    try std.testing.expect(try ex.next(&s) == null);
}

test "抽取：PagingExtractor 分页兜底，批大小与总数正确" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "extract-page");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("Item");
    try seedItems(&table, &s, 25);

    var ex = zcode.extract.PagingExtractor.init(table, "Id");
    ex.batch_size = 7;

    var batches: usize = 0;
    while (try ex.next(&s)) |rows| {
        try std.testing.expect(rows.len <= 7);
        batches += 1;
    }

    try std.testing.expectEqual(@as(usize, 4), batches); // 7 + 7 + 7 + 4
    try std.testing.expectEqual(@as(usize, 25), ex.total);
    try std.testing.expect(ex.done);
}

test "抽取：TimeExtractor 按时间窗推进，全部行取一次且能终止" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "extract-time");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("Item");

    // 5 分钟，每分钟两行（:00 与 :30），共 10 行
    var minute: u8 = 0;
    while (minute < 5) : (minute += 1) {
        for ([_]u8{ 0, 30 }) |sec| {
            const dt = zcode.DateTime{ .year = 2024, .month = 1, .day = 1, .hour = 0, .minute = minute, .second = sec };
            const name = try std.fmt.allocPrint(s.resultAllocator(), "t-{d}-{d}", .{ minute, sec });
            _ = try table.insert(&s, &[_]zcode.sqlbuild.Field{
                .{ .name = "Name", .value = .{ .text = name } },
                .{ .name = "CreateTime", .value = .{ .datetime = dt } },
            });
        }
    }

    var ex = zcode.extract.TimeExtractor.init(table, "CreateTime", .{
        .start = try zcode.DateTime.parse("2024-01-01 00:00:00"),
        .end = try zcode.DateTime.parse("2024-01-01 00:05:00"),
        .batch_size = 2,
    });
    // 固定「当前时间」，用例不随系统时钟漂移
    ex.now_override = try zcode.DateTime.parse("2024-01-01 01:00:00");

    var seen: usize = 0;
    var guard: usize = 0;
    while (try ex.next(&s)) |rows| {
        seen += rows.len;
        guard += 1;
        try std.testing.expect(guard < 100); // 死循环护栏
    }

    try std.testing.expectEqual(@as(usize, 10), seen);
    try std.testing.expectEqual(@as(usize, 10), ex.total);
    try std.testing.expect(ex.done);
}

test "抽取：时间空档不会死循环（C# 会原地打转，这里明确收工）" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "extract-gap");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("Item");
    // 只有 00:00:00 一行，之后 10 分钟全空
    _ = try table.insert(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Name", .value = .{ .text = "only" } },
        .{ .name = "CreateTime", .value = .{ .datetime = try zcode.DateTime.parse("2024-01-01 00:00:00") } },
    });

    var ex = zcode.extract.TimeExtractor.init(table, "CreateTime", .{
        .start = try zcode.DateTime.parse("2024-01-01 00:00:00"),
        .end = try zcode.DateTime.parse("2024-01-01 00:10:00"),
        .batch_size = 100,
    });
    ex.now_override = try zcode.DateTime.parse("2024-01-01 01:00:00");

    var seen: usize = 0;
    var guard: usize = 0;
    while (try ex.next(&s)) |rows| {
        seen += rows.len;
        guard += 1;
        try std.testing.expect(guard < 1000);
    }

    try std.testing.expectEqual(@as(usize, 1), seen);
    try std.testing.expect(ex.done);
}

// ───────────────────────── MS 传统分页（真库验证） ─────────────────────────

test "分页：MSPageSplit 的 rowNumber 算法在真库上翻页正确" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "pagesplit");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("Item");
    try seedItems(&table, &s, 10);

    // 生成的 SQL 是 SQL Server 2005 口径，但 `rowNumber` 分支本身是标准窗口函数，SQLite 也能跑
    var spec = zcode.pagesplit.Spec{
        .table = "\"DH_Item\"",
        .column = "\"Id\", \"Name\"",
        .order_by = "\"Id\" Asc",
        .key = "\"Id\"",
        .key_is_int = true,
    };

    const page2 = try zcode.pagesplit.rowNumberAlloc(a, spec, 4, 3); // 第 5~7 行
    defer a.free(page2);

    const rows = try s.queryRows(page2, &.{});
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(i64, 5), rows[0].get("Id").?.asI64().?);
    try std.testing.expectEqual(@as(i64, 7), rows[2].get("Id").?.asI64().?);
    try std.testing.expectEqualStrings("n-5", rows[0].get("Name").?.asText().?);

    // 最后一页只有 1 行（10 条数据，取第 10 行）
    const last = try zcode.pagesplit.rowNumberAlloc(a, spec, 9, 5);
    defer a.free(last);
    const last_rows = try s.queryRows(last, &.{});
    try std.testing.expectEqual(@as(usize, 1), last_rows.len);
    try std.testing.expectEqual(@as(i64, 10), last_rows[0].get("Id").?.asI64().?);

    // 页大小为 0（从某行到末尾）
    const open_end = try zcode.pagesplit.rowNumberAlloc(a, spec, 7, 0);
    defer a.free(open_end);
    const rest = try s.queryRows(open_end, &.{});
    try std.testing.expectEqual(@as(usize, 3), rest.len);

    _ = &spec;
}
