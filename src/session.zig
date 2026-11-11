//! 会话：一次连接 + 结果集 arena。
//!
//! 与 DH.NCode `IDbSession` 的对应关系（第一轮只实现同步、单连接）：
//! - `execute` ≈ `Execute`（增删改）
//! - `queryRows` ≈ `Query`（返回行集）
//! - `lastInsertId` ≈ `Identity` 回写
//!
//! 生命周期约定：查询返回的行/字符串都分配在会话自己的 arena 上，**下一次查询不会失效**；
//! 需要长期持有请 `dupe` 出去，或定期 `resetResults()` 回收。

const std = @import("std");
const sqlite = @import("zzig").sqlite;
const mysql = @import("zzig").mysql;
const Value = @import("zzig").db.Value;
const DatabaseKind = @import("dialect.zig").DatabaseKind;

pub const Row = sqlite.Row; // == zzig.db.Row，两个驱动共用同一行结构

/// 会话底层驱动（当前只支持 SQLite / MySQL；其它方言在 Dal 层已报 `error.Unsupported`）。
pub const Driver = union(enum) {
    sqlite: sqlite.Db,
    mysql: mysql.Conn,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    driver: Driver,
    read_only: bool = false,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, kind: DatabaseKind, db: sqlite.Db) Session {
        return initWithDriver(gpa, kind, .{ .sqlite = db });
    }

    pub fn initWithDriver(gpa: std.mem.Allocator, kind: DatabaseKind, driver: Driver) Session {
        return .{ .gpa = gpa, .kind = kind, .driver = driver, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
        switch (self.driver) {
            .sqlite => |*db| db.close(),
            .mysql => |*conn| conn.deinit(),
        }
    }

    /// 结果集 allocator（行/字符串都从这里分配）。
    pub fn resultAllocator(self: *Session) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// 回收此前所有结果集内存（调用方须确认不再引用旧行）。
    pub fn resetResults(self: *Session) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// 执行增删改（写会话才允许；只读副本在调用点即失败）。
    pub fn execute(self: *Session, sql: []const u8, params: []const Value) !usize {
        if (self.read_only) return error.ReadOnly;
        switch (self.driver) {
            .sqlite => |*db| {
                const stmt = try db.prepare(self.gpa, sql);
                defer stmt.finalize();
                stmt.bindAll(params) catch |e| {
                    std.debug.print("[zcode] 参数绑定失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, db.lastError() });
                    return e;
                };
                stmt.run() catch |e| {
                    std.debug.print("[zcode] SQL 执行失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, db.lastError() });
                    return e;
                };
                return db.changes();
            },
            .mysql => |*conn| {
                const n = conn.exec(sql, params) catch |e| {
                    std.debug.print("[zcode] SQL 执行失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, conn.lastError() });
                    return e;
                };
                return @intCast(n);
            },
        }
    }

    /// 查询（返回行集，含列名）。
    pub fn queryRows(self: *Session, sql: []const u8, params: []const Value) ![]const Row {
        switch (self.driver) {
            .sqlite => |*db| {
                const stmt = try db.prepare(self.gpa, sql);
                defer stmt.finalize();
                try stmt.bindAll(params);

                const arena = self.arena.allocator();
                var rows: std.ArrayList(Row) = .empty;
                while (true) {
                    const rc = db.lib.step(stmt.handle);
                    if (rc == sqlite.sqlite_row) {
                        try rows.append(arena, try stmt.readRow(arena));
                        continue;
                    }
                    if (rc == sqlite.sqlite_done) break;
                    return error.Sqlite;
                }
                return rows.toOwnedSlice(arena);
            },
            .mysql => |*conn| {
                const r = conn.queryAlloc(self.arena.allocator(), sql, params) catch |e| {
                    std.debug.print("[zcode] 查询失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, conn.lastError() });
                    return e;
                };
                return switch (r) {
                    .rows => |rows| rows.rows,
                    // DDL 等无结果集语句：返回空行集（与 SQLite 侧行为一致）
                    .ok => &.{},
                };
            },
        }
    }

    /// 查询单值（第一列第一行）；无行返回 null。
    pub fn queryScalar(self: *Session, sql: []const u8, params: []const Value) !?Value {
        const rows = try self.queryRows(sql, params);
        if (rows.len == 0) return null;
        if (rows[0].values.len == 0) return null;
        return rows[0].values[0];
    }

    pub fn lastInsertId(self: *Session) i64 {
        return switch (self.driver) {
            .sqlite => |*db| db.lastInsertId(),
            .mysql => |*conn| conn.lastInsertId(),
        };
    }

    pub fn lastError(self: *Session) []const u8 {
        return switch (self.driver) {
            .sqlite => |*db| db.lastError(),
            .mysql => |*conn| conn.lastError(),
        };
    }

    /// 预编译语句，供批量写/游标读取复用（调用方负责 finalize）。
    /// MySQL 侧走预处理协议但不由上层复用（每次 prepare/execute/close），故不支持。
    pub fn prepare(self: *Session, sql: []const u8) !sqlite.Stmt {
        return switch (self.driver) {
            .sqlite => |*db| db.prepare(self.gpa, sql),
            .mysql => error.Unsupported,
        };
    }
};

test "会话基本 CRUD（内存库）" {
    const a = std.testing.allocator;
    var lib = sqlite.Lib.load(a) catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer lib.deinit();

    const db = try sqlite.Db.open(&lib, ":memory:");
    var s = Session.init(a, .sqlite, db);
    defer s.deinit();

    _ = try s.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try s.execute("INSERT INTO t (name) VALUES (?)", &.{.{ .text = "abc" }});
    try std.testing.expectEqual(@as(i64, 1), s.lastInsertId());

    const rows = try s.queryRows("SELECT id, name FROM t", &.{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("abc", rows[0].get("name").?.text);

    const n = try s.queryScalar("SELECT COUNT(*) FROM t", &.{});
    try std.testing.expectEqual(@as(i64, 1), n.?.int);
}

test "只读会话在调用点拒绝写入" {
    const a = std.testing.allocator;
    var lib = sqlite.Lib.load(a) catch return;
    defer lib.deinit();

    const db = try sqlite.Db.open(&lib, ":memory:");
    var s = Session.init(a, .sqlite, db);
    s.read_only = true;
    defer s.deinit();

    try std.testing.expectError(error.ReadOnly, s.execute("CREATE TABLE t (id INTEGER)", &.{}));
}
