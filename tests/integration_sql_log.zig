//! 集成测试：SQL 输出开关（`Setting.show_sql` / 连接串 `ShowSQL` / 慢 SQL / 截断）。
//!
//! 全部用**真 SQLite** + 真执行：验证开关真的决定「有没有输出」，而不是只解析了配置。

const std = @import("std");
const zcode = @import("zcode");
const zzig = @import("zzig");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
    \\  <Option><Namespace>Test.SqlLog</Namespace><ConnName>DH</ConnName></Option>
    \\  <Tables>
    \\    <Table Name="Item" TableName="BH_Item">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Code" DataType="String" Length="50" />
    \\      </Columns>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

fn tempDbPath(a: std.mem.Allocator) ![]u8 {
    return zcode.File.UniqueTempName(a, "sqllog", ".db");
}

fn openDal(a: std.mem.Allocator, db_path: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

/// 把 SQL 日志收集到内存（默认 sink 写 stderr，测试里换掉才能断言内容）。
const CaptureSink = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    calls: usize = 0,

    fn write(ctx: ?*anyopaque, line: []const u8) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx orelse return));
        self.buf.appendSlice(self.a, line) catch return;
        self.buf.append(self.a, '\n') catch return;
        self.calls += 1;
    }

    fn install(self: *CaptureSink) zcode.session.SqlSink {
        const previous = zcode.session.sqlSinkSnapshot();
        zcode.session.setSqlSink(.{ .ctx = self, .writeFn = write });
        return previous;
    }

    fn deinit(self: *CaptureSink) void {
        self.buf.deinit(self.a);
    }

    fn all(self: *const CaptureSink) []const u8 {
        return self.buf.items;
    }
};

test "SQL 日志：默认关 → 全局打开才输出；会话可覆盖；超长截断" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a);
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    const old_setting = zcode.setting.snapshot();
    defer zcode.setting.restore(old_setting);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var sink = CaptureSink{ .a = a };
    defer sink.deinit();
    const old_sink = sink.install();
    defer zcode.session.setSqlSink(old_sink);

    // 1) 默认（`Setting.show_sql` 默认 false）→ 一条 SQL 都不输出
    zcode.setting.resetToDefaults();
    s.followGlobalShowSql();
    _ = try s.execute("Insert Into BH_Item (Code) Values (?)", &.{.{ .text = "a1" }});
    try std.testing.expectEqual(@as(usize, 0), sink.calls);

    // 2) 全局打开 → 输出，且带连接名前缀与参数
    zcode.setting.current().show_sql = true;
    _ = try s.execute("Insert Into BH_Item (Code) Values (?)", &.{.{ .text = "a2" }});
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    const first = sink.all();
    try std.testing.expect(std.mem.indexOf(u8, first, "[DH] ") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "Insert Into BH_Item") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "0=a2") != null);

    // 3) 会话级覆盖（对应 C# `SetShowSql(false)`）→ 即使全局开也不输出
    const before = sink.calls;
    const scoped = s.showSqlScoped(false);
    _ = try s.execute("Insert Into BH_Item (Code) Values (?)", &.{.{ .text = "a3" }});
    try std.testing.expectEqual(before, sink.calls);
    s.restoreShowSql(scoped);
    _ = try s.execute("Insert Into BH_Item (Code) Values (?)", &.{.{ .text = "a4" }});
    try std.testing.expectEqual(before + 1, sink.calls);

    // 4) 超长截断：上限 16 字节 → 输出里只剩 SQL 前 16 字节 + `...`
    s.sql_max_length = 16;
    const calls_before_trunc = sink.calls;
    _ = try s.execute("Insert Into BH_Item (Code) Values (?)", &.{.{ .text = "a5" }});
    try std.testing.expectEqual(calls_before_trunc + 1, sink.calls);
    const truncated = sink.all();
    // INSERT 超长 → 前后各留一半（C# `GetSql` 同口径）
    try std.testing.expect(std.mem.indexOf(u8, truncated, "Insert I......") != null);
    try std.testing.expect(std.mem.indexOf(u8, truncated, "0=a5") != null);

    // 数据确实落库（日志开关不影响执行）
    const n = (try s.queryScalar("Select count(*) From BH_Item", &.{})).?;
    try std.testing.expectEqual(@as(i64, 5), n.asI64().?);
}

test "SQL 日志：ShowSQL=false 时慢 SQL 仍然输出并附耗时" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a);
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    const old_setting = zcode.setting.snapshot();
    defer zcode.setting.restore(old_setting);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    var sink = CaptureSink{ .a = a };
    defer sink.deinit();
    const old_sink = sink.install();
    defer zcode.session.setSqlSink(old_sink);

    // 全部关，只开慢 SQL 跟踪（阈值 1ms）
    zcode.setting.resetToDefaults();
    zcode.setting.current().show_sql = false;
    s.followGlobalShowSql();
    s.trace_sql_time = 1;

    // 递归 CTE 跑 30 万次，稳定超过 1ms（比 sleep 更接近真实场景）
    const rows = try s.queryRows(
        "WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt WHERE x < 300000) SELECT sum(x) FROM cnt",
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(sink.calls >= 1);
    try std.testing.expect(std.mem.indexOf(u8, sink.all(), " ms)") != null);

    // 阈值关闭后同一 SQL 不再因为“慢”而输出
    s.trace_sql_time = 0;
    const before = sink.calls;
    _ = try s.queryRows("Select 1", &.{});
    try std.testing.expectEqual(before, sink.calls);
}

test "SQL 日志：连接串 ShowSQL=True 覆盖全局默认（不改全局设置也输出）" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a);
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    const old_setting = zcode.setting.snapshot();
    defer zcode.setting.restore(old_setting);
    zcode.setting.resetToDefaults(); // 全局 show_sql = false
    zcode.setting.current().show_sql = false;

    // 连接串显式打开
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite;ShowSQL=True", .{path});
    defer a.free(conn);
    var dal = try zcode.Dal.initWithModel(a, conn, m);
    defer dal.deinit();

    var sink = CaptureSink{ .a = a };
    defer sink.deinit();
    const old_sink = sink.install();
    defer zcode.session.setSqlSink(old_sink);

    var s = try dal.openSession();
    defer s.deinit();
    try std.testing.expect(s.shouldShowSql());
    _ = try s.queryRows("Select 1", &.{});
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expect(std.mem.indexOf(u8, sink.all(), "[DH] Select 1") != null);
}
