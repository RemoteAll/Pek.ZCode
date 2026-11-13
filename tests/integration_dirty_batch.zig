//! 集成测试：脏数据驱动的「列裁剪 + 合并 UPDATE」。
//!
//! 两个硬要求（用户原话）：
//! - 「未改的话那不是应该不要写么？」→ SQL 里不能出现未改的列；
//! - 「同时多个业务系统同时读写某个表」→ 不能整行/整组覆盖，只能写自己改过的列。
//!
//! 用 SQL 日志 sink 直接断言 SQL 文本，不靠猜。

const std = @import("std");
const zcode = @import("zcode");
const zzig = @import("zzig");

const User = zcode.membership.entities.User;

const Env = struct {
    gpa: std.mem.Allocator,
    dal: zcode.Dal,
    db: []u8,
    log_db: []u8,

    fn open(gpa: std.mem.Allocator) !Env {
        const db = try zcode.File.UniqueTempName(gpa, "dirty", ".db");
        errdefer gpa.free(db);
        const log_db = try zcode.File.UniqueTempName(gpa, "dirty-log", ".db");
        errdefer gpa.free(log_db);

        const m = try zcode.EntityModel.load(gpa, "tests/fixtures/dh-ncode-model.xml");
        const conn = try std.fmt.allocPrint(gpa, "Data Source={s};Provider=SQLite", .{db});
        defer gpa.free(conn);
        var dal = try zcode.Dal.initWithModel(gpa, conn, m);
        errdefer dal.deinit();

        const log_conn = try std.fmt.allocPrint(gpa, "Data Source={s};Provider=SQLite", .{log_db});
        defer gpa.free(log_conn);
        try dal.attachConnection("Log", log_conn);

        return .{ .gpa = gpa, .dal = dal, .db = db, .log_db = log_db };
    }

    fn deinit(self: *Env) void {
        self.dal.deinit();
        zcode.File.DeleteQuiet(self.db);
        zcode.File.DeleteQuiet(self.log_db);
        self.gpa.free(self.db);
        self.gpa.free(self.log_db);
    }

    fn ready(self: *Env) !void {
        var s = try self.dal.openSession();
        defer s.deinit();
        _ = try self.dal.syncSchema(&s);
    }
};

/// 捕获 SQL 日志（只收本用例的语句）。
const Sink = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    calls: usize = 0,

    fn write(ctx: ?*anyopaque, line: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx orelse return));
        self.buf.appendSlice(self.a, line) catch return;
        self.buf.append(self.a, '\n') catch return;
        self.calls += 1;
    }

    fn install(self: *Sink) zcode.session.SqlSink {
        const prev = zcode.session.sqlSinkSnapshot();
        zcode.session.setSqlSink(.{ .ctx = self, .writeFn = write });
        return prev;
    }

    fn deinit(self: *Sink) void {
        self.buf.deinit(self.a);
    }

    fn reset(self: *Sink) void {
        self.buf.clearRetainingCapacity();
        self.calls = 0;
    }

    fn all(self: *const Sink) []const u8 {
        return self.buf.items;
    }
};

fn newUser(dal: *zcode.Dal, s: *zcode.Session, name: []const u8) !i32 {
    var u = User{};
    u.setName(name);
    u.setEnable(true);
    const id = try zcode.entity.insert(dal, &u, s);
    return @intCast(id);
}

test "脏列裁剪：只改一列，SQL 里不出现其它列" {
    const gpa = std.testing.allocator;
    var env = try Env.open(gpa);
    defer env.deinit();
    try env.ready();

    const old = zcode.setting.snapshot();
    defer zcode.setting.restore(old);
    zcode.setting.resetToDefaults();
    zcode.setting.current().show_sql = true;

    var sink = Sink{ .a = gpa };
    defer sink.deinit();
    const prev_sink = sink.install();
    defer zcode.session.setSqlSink(prev_sink);

    var s = try env.dal.openSession();
    defer s.deinit();

    const id = try newUser(&env.dal, &s, "u1");

    // 取回来（dirty 清空），只改 DisplayName
    var u = (try zcode.entity.findByPk(&env.dal, User, &s, &.{.{ .int = id }})).?;
    u.setDisplayName("新昵称");

    sink.reset();
    _ = try zcode.entity.update(&env.dal, &u, &s);
    try std.testing.expectEqual(@as(usize, 1), sink.calls);

    const sql = sink.all();
    try std.testing.expect(std.mem.indexOf(u8, sql, "DisplayName") != null);
    // 未改的列一个都不能出现在 SET 里
    try std.testing.expect(std.mem.indexOf(u8, sql, "Password") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "Remark") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "Mail") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CreateTime") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "UpdateTime") == null);
}

test "赋相同值不置脏：batch 里这类实体一条 SQL 都不发" {
    const gpa = std.testing.allocator;
    var env = try Env.open(gpa);
    defer env.deinit();
    try env.ready();

    var s = try env.dal.openSession();
    defer s.deinit();

    const id = try newUser(&env.dal, &s, "same");
    var u = (try zcode.entity.findByPk(&env.dal, User, &s, &.{.{ .int = id }})).?;
    try std.testing.expect(!zcode.entity_ext.hasDirty(&u));

    // 赋与原值完全相同的值 → setter 判定相等，不置脏
    u.setName("same");
    u.setEnable(true);
    try std.testing.expect(!zcode.entity_ext.hasDirty(&u));

    const p: *User = &u;
    const report = try zcode.entity.saveBatchWith(&env.dal, User, &.{p}, &s, .upsert);
    try std.testing.expectEqual(@as(usize, 0), report.inserted);
    try std.testing.expectEqual(@as(usize, 0), report.updated);
    try std.testing.expectEqual(@as(usize, 1), report.unchanged);
}

test "批量更新：同脏列合并成一条多行 UPDATE（3 行 1 次往返）" {
    const gpa = std.testing.allocator;
    var env = try Env.open(gpa);
    defer env.deinit();
    try env.ready();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var s = try env.dal.openSession();
    defer s.deinit();

    var ids: [3]i32 = undefined;
    for (&ids, 0..) |*id, i| {
        var buf: [16]u8 = undefined;
        id.* = try newUser(&env.dal, &s, try std.fmt.bufPrint(&buf, "m{d}", .{i}));
    }

    var users: [3]User = undefined;
    for (&users, 0..) |*u, i| {
        u.* = (try zcode.entity.findByPk(&env.dal, User, &s, &.{.{ .int = ids[i] }})).?;
        // 必须用 arena 分配：`bufPrint` 的栈缓冲会被下一轮覆写，
        // 三个实体的 DisplayName 会全部指向同一块内存（曾踩过）
        u.setDisplayName(try std.fmt.allocPrint(a, "昵称{d}", .{i}));
    }

    // 计数一次批量写发出几条 SQL
    const old = zcode.setting.snapshot();
    defer zcode.setting.restore(old);
    zcode.setting.resetToDefaults();
    zcode.setting.current().show_sql = true;

    var sink = Sink{ .a = a };
    defer sink.deinit();
    const prev_sink = sink.install();
    defer zcode.session.setSqlSink(prev_sink);

    const ptrs = [_]*User{ &users[0], &users[1], &users[2] };
    sink.reset();
    const report = try zcode.entity.saveBatchWith(&env.dal, User, &ptrs, &s, .upsert);

    try std.testing.expectEqual(@as(usize, 3), report.updated);
    // 3 行同脏列 → 一条 UPDATE（一次往返）。SQLite 走 `SELECT ? AS .. UNION ALL`，
    // PG/SQL Server 走 `(VALUES ...)`，都是一条语句多行。
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    const sql = sink.all();
    try std.testing.expect(std.mem.indexOf(u8, sql, "FROM (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "UNION ALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "DisplayName") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "Password") == null);

    // 数据确实写进去了
    for (ids, 0..) |id, i| {
        const got = (try zcode.entity.findByPk(&env.dal, User, &s, &.{.{ .int = id }})).?;
        var buf: [16]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "昵称{d}", .{i}), got.DisplayName);
    }
}
