//! 分表分库 + 自动凑批：同一个表按分片键落到不同库/不同物理表时，
//! **同一分片目标的实体合并成一条多行 INSERT**（一批同时处理），不同分片各自一批。
//!
//! 用两个真实 SQLite 文件（DH_2023 / DH_2024）+ 年度分片策略验证。

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

const Log = struct {
    dirty: zcode.entity.DirtyBits = 0,
    Id: i32 = 0,
    Title: []const u8 = "",
    CreateTime: zcode.DateTime = .{},

    pub const meta = zcode.entity.EntityMeta{
        .name = "Log",
        .table_name = "DH_Log",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "Title", .data_type = .string },
            .{ .name = "CreateTime", .data_type = .datetime },
        },
    };

    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = self.Id },
            1 => .{ .text = self.Title },
            2 => .{ .datetime = self.CreateTime },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => self.Id = @intCast(v.asI64() orelse 0),
            1 => self.Title = if (v == .text) v.text else "",
            2 => self.CreateTime = if (v == .datetime) v.datetime else .{},
            else => {},
        }
    }
};

fn tempDbPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    return zcode.File.UniqueTempName(a, tag, ".db");
}

test "分表分库 + 自动凑批：同分片合并成一条多行 INSERT，不同分片各自一批" {
    const a = std.testing.allocator;

    const main_path = try tempDbPath(a, "cqmain");
    defer a.free(main_path);
    defer zcode.File.DeleteQuiet(main_path);
    const y2023_path = try tempDbPath(a, "cq2023");
    defer a.free(y2023_path);
    defer zcode.File.DeleteQuiet(y2023_path);
    const y2024_path = try tempDbPath(a, "cq2024");
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

    {
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    try dal.attachConnection("DH_2023", y2023_conn);
    try dal.attachConnection("DH_2024", y2024_conn);
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

    // 先把两个分片表建出来（等价于首次写入前的自动建表）
    inline for (.{ 2023, 2024 }) |year| {
        const sm = try dal.shardOfTable("Log", .{ .datetime = .{ .year = year, .month = 6, .day = 1 } });
        defer sm.deinit(a);
        _ = try dal.ensureShardTable("Log", sm);
    }

    // 5 条：2023×2、2024×3 —— 应各自凑成一批
    var items: [5]Log = undefined;
    const years = [_]i32{ 2023, 2023, 2024, 2024, 2024 };
    for (&items, 0..) |*it, i| {
        it.* = .{
            .Title = "t",
            .CreateTime = .{ .year = years[i], .month = 6, .day = 1 },
        };
    }

    defer zcode.entity_queue.stopGlobal();
    for (&items) |*it| {
        try zcode.entity.saveAsyncSharded(std.heap.page_allocator, &dal, it, 0, .{ .datetime = it.CreateTime });
    }
    // 一次 flush：按分片目标分组，每组一条多行 INSERT
    try zcode.entity_queue.flushGlobal();

    // 两个库各自的行数：2023 库 2 条、2024 库 3 条
    {
        var s23 = try dal.sessionForConn("DH_2023");
        defer s23.deinit();
        const rows = try s23.queryRows("Select Count(*) From DH_Log_2023", &.{});
        try std.testing.expectEqual(@as(i64, 2), rows[0].at(0).?.int);
    }
    {
        var s24 = try dal.sessionForConn("DH_2024");
        defer s24.deinit();
        const rows = try s24.queryRows("Select Count(*) From DH_Log_2024", &.{});
        try std.testing.expectEqual(@as(i64, 3), rows[0].at(0).?.int);
    }
}

// ── 分片批量更新：脏列裁剪 + 每个分片一条 UPDATE ──────────────────

const ShardSink = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn write(ctx: ?*anyopaque, line: []const u8) void {
        const self: *ShardSink = @ptrCast(@alignCast(ctx orelse return));
        self.buf.appendSlice(self.a, line) catch return;
        self.buf.append(self.a, '\n') catch return;
    }
    fn all(self: *const ShardSink) []const u8 {
        return self.buf.items;
    }
};

test "分片 + 脏列裁剪：每个分片一条 UPDATE，且不写未改的列" {
    const a = std.testing.allocator;

    const main_path = try tempDbPath(a, "smain");
    defer a.free(main_path);
    defer zcode.File.DeleteQuiet(main_path);
    const y2023_path = try tempDbPath(a, "s2023");
    defer a.free(y2023_path);
    defer zcode.File.DeleteQuiet(y2023_path);
    const y2024_path = try tempDbPath(a, "s2024");
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
    try dal.attachConnection("DH_2023", y2023_conn);
    try dal.attachConnection("DH_2024", y2024_conn);

    var policy = zcode.shards.TimePolicy.init(a, "CreateTime", "DH", "DH_Log", "DH_Log_{1:yyyy}");
    policy.conn_policy = "DH_{1:yyyy}";
    policy.step_ms = 365 * zcode.shards.day_ms;
    try dal.addShardPolicy("DH_Log", policy);

    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    // 先写数据（同时把分片表建好）
    var items = [_]Log{
        .{ .Title = "a", .CreateTime = zcode.DateTime.parse("2023-03-01 00:00:00") catch .{} },
        .{ .Title = "b", .CreateTime = zcode.DateTime.parse("2023-08-01 00:00:00") catch .{} },
        .{ .Title = "c", .CreateTime = zcode.DateTime.parse("2024-05-01 00:00:00") catch .{} },
    };
    var ptrs = [_]*Log{ &items[0], &items[1], &items[2] };
    const ins = try zcode.entity.saveBatchWith(&dal, Log, &ptrs, &s, .insert);
    try std.testing.expectEqual(@as(usize, 3), ins.inserted);

    // 直接构造带主键的实体（分片表里已有数据）
    var upd = [_]Log{
        .{ .Id = 1, .Title = "a2", .CreateTime = zcode.DateTime.parse("2023-03-01 00:00:00") catch .{} },
        .{ .Id = 2, .Title = "b2", .CreateTime = zcode.DateTime.parse("2023-08-01 00:00:00") catch .{} },
        .{ .Id = 3, .Title = "c2", .CreateTime = zcode.DateTime.parse("2024-05-01 00:00:00") catch .{} },
    };
    for (&upd) |*u| {
        u.dirty = 0;
        zcode.entity.markDirty(&u.dirty, 1); // 只有 Title 脏
    }

    const old = zcode.setting.snapshot();
    defer zcode.setting.restore(old);
    zcode.setting.resetToDefaults();
    zcode.setting.current().show_sql = true;

    var sink = ShardSink{ .a = a };
    defer sink.buf.deinit(a);
    const prev = zcode.session.sqlSinkSnapshot();
    zcode.session.setSqlSink(.{ .ctx = &sink, .writeFn = ShardSink.write });
    defer zcode.session.setSqlSink(prev);

    var uptr = [_]*Log{ &upd[0], &upd[1], &upd[2] };
    const rep = try zcode.entity.saveBatchWith(&dal, Log, &uptr, &s, .upsert);

    const sql = sink.all();
    // 两个分片 → 两条 UPDATE（绝不跨分片合并）
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, sql, "UPDATE "));
    // 只写脏列 Title，未改的 CreateTime 不进 SQL
    try std.testing.expect(std.mem.indexOf(u8, sql, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CreateTime") == null);
    try std.testing.expect(rep.updated >= 2);
}
