//! 会话：一次连接 + 结果集 arena。
//!
//! 与 DH.NCode `IDbSession` 的对应关系：
//! - `execute` ≈ `Execute`（增删改）
//! - `queryRows` ≈ `Query`（返回行集）
//! - `lastInsertId` ≈ `Identity` 回写
//! - `beginTransaction` / `commit` / `rollback` ≈ `BeginTransaction` / `Commit` / `Rollback`
//!   （**可嵌套、按计数**：只有计数回到 0 才真正 COMMIT/ROLLBACK，与 C# `Transaction` 一致）
//!
//! 生命周期约定：查询返回的行/字符串都分配在会话自己的 arena 上，**下一次查询不会失效**；
//! 需要长期持有请 `dupe` 出去，或定期 `resetResults()` 回收。

const std = @import("std");
const sqlite = @import("zzig").sqlite;
const mysql = @import("zzig").mysql;
const postgres = @import("zzig").postgres;
const Value = @import("zzig").db.Value;
const DatabaseKind = @import("dialect.zig").DatabaseKind;

pub const Row = sqlite.Row; // == zzig.db.Row，两个驱动共用同一行结构

/// 事务隔离级别（对应 `System.Data.IsolationLevel`）。
/// `default` = 用数据库默认级别（SQLite 无从设置，MySQL 默认 REPEATABLE READ）。
pub const IsolationLevel = enum {
    default,
    read_uncommitted,
    read_committed,
    repeatable_read,
    serializable,
    /// 快照隔离（SQL Server 系）；SQLite/MySQL 显式 `error.Unsupported`
    snapshot,

    pub fn sqlText(self: IsolationLevel) ?[]const u8 {
        return switch (self) {
            .default => null,
            .read_uncommitted => "READ UNCOMMITTED",
            .read_committed => "READ COMMITTED",
            .repeatable_read => "REPEATABLE READ",
            .serializable => "SERIALIZABLE",
            .snapshot => null,
        };
    }
};

/// 会话底层驱动（SQLite / MySQL / PostgreSQL；其它方言在 Dal 层已报 `error.Unsupported`）。
pub const Driver = union(enum) {
    sqlite: sqlite.Db,
    mysql: mysql.Conn,
    postgres: postgres.Conn,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    driver: Driver,
    read_only: bool = false,
    arena: std.heap.ArenaAllocator,
    /// 事务嵌套计数（0 = 不在事务中；1 = 最外层，真正持有 BEGIN）
    tx_depth: u32 = 0,

    /// SQLite 预处理语句缓存（同一 SQL 文本复用，省去每次 prepare/finalize）
    stmt_cache: std.ArrayListUnmanaged(CachedStmt) = .empty,
    /// 缓存上限（超过后新 SQL 不再入缓存，直接即时 prepare）
    stmt_cache_limit: usize = 64,
    stmt_cache_hits: usize = 0,
    stmt_cache_misses: usize = 0,

    const CachedStmt = struct {
        sql: []const u8,
        stmt: sqlite.Stmt,
    };

    pub fn init(gpa: std.mem.Allocator, kind: DatabaseKind, db: sqlite.Db) Session {
        return initWithDriver(gpa, kind, .{ .sqlite = db });
    }

    pub fn initWithDriver(gpa: std.mem.Allocator, kind: DatabaseKind, driver: Driver) Session {
        return .{ .gpa = gpa, .kind = kind, .driver = driver, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Session) void {
        for (self.stmt_cache.items) |*e| {
            e.stmt.finalize();
            self.gpa.free(e.sql);
        }
        self.stmt_cache.deinit(self.gpa);
        self.arena.deinit();
        switch (self.driver) {
            .sqlite => |*db| db.close(),
            .mysql => |*conn| conn.deinit(),
            .postgres => |*conn| conn.deinit(),
        }
    }

    /// 取一个已重置的缓存语句（SQLite）。返回 null 表示该会话不走缓存
    /// （MySQL，或缓存已满）。
    ///
    /// 注意：返回的指针只在**本次调用内**有效（中间不要插入新的缓存写入）。
    fn cachedStmt(self: *Session, sql: []const u8) !?*sqlite.Stmt {
        switch (self.driver) {
            .sqlite => {},
            else => return null,
        }
        for (self.stmt_cache.items) |*e| {
            if (std.mem.eql(u8, e.sql, sql)) {
                self.stmt_cache_hits += 1;
                e.stmt.reset();
                return &e.stmt;
            }
        }
        self.stmt_cache_misses += 1;
        if (self.stmt_cache.items.len >= self.stmt_cache_limit) return null;

        const stmt = try self.driver.sqlite.prepare(self.gpa, sql);
        const owned_sql = self.gpa.dupe(u8, sql) catch |e| {
            stmt.finalize();
            return e;
        };
        try self.stmt_cache.append(self.gpa, .{ .sql = owned_sql, .stmt = stmt });
        const entry = &self.stmt_cache.items[self.stmt_cache.items.len - 1];
        return &entry.stmt;
    }

    /// 语句缓存统计（命中/未命中），用于观察热点 SQL 是否真的被复用。
    pub fn stmtCacheStats(self: *const Session) struct { hits: usize, misses: usize, size: usize } {
        return .{ .hits = self.stmt_cache_hits, .misses = self.stmt_cache_misses, .size = self.stmt_cache.items.len };
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
                // 快路径：命中缓存则直接重置复用（省去每次 prepare/finalize）
                if (try self.cachedStmt(sql)) |stmt| {
                    stmt.bindAll(params) catch |e| {
                        std.debug.print("[zcode] 参数绑定失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, db.lastError() });
                        stmt.reset();
                        return e;
                    };
                    stmt.run() catch |e| {
                        std.debug.print("[zcode] SQL 执行失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, db.lastError() });
                        stmt.reset();
                        return e;
                    };
                    stmt.reset();
                    return db.changes();
                }

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
            .postgres => |*conn| {
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
                const arena = self.arena.allocator();
                var rows: std.ArrayList(Row) = .empty;

                if (try self.cachedStmt(sql)) |stmt| {
                    stmt.bindAll(params) catch |e| {
                        std.debug.print("[zcode] 参数绑定失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, db.lastError() });
                        stmt.reset();
                        return e;
                    };
                    defer stmt.reset();
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
                }

                const stmt = try db.prepare(self.gpa, sql);
                defer stmt.finalize();
                try stmt.bindAll(params);

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
            .postgres => |*conn| {
                const r = conn.queryAlloc(self.arena.allocator(), sql, params) catch |e| {
                    std.debug.print("[zcode] 查询失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, conn.lastError() });
                    return e;
                };
                return switch (r) {
                    .rows => |rows| rows.rows,
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
            // PostgreSQL 无自增回写（需 `RETURNING`），恒为 0
            .postgres => |*conn| conn.lastInsertId(),
        };
    }

    pub fn lastError(self: *Session) []const u8 {
        return switch (self.driver) {
            .sqlite => |*db| db.lastError(),
            .mysql => |*conn| conn.lastError(),
            .postgres => |*conn| conn.lastError(),
        };
    }

    /// 预编译语句，供批量写/游标读取复用（调用方负责 finalize）。
    /// MySQL 侧走预处理协议但不由上层复用（每次 prepare/execute/close），故不支持。
    pub fn prepare(self: *Session, sql: []const u8) !sqlite.Stmt {
        return switch (self.driver) {
            .sqlite => |*db| db.prepare(self.gpa, sql),
            .mysql => error.Unsupported,
            .postgres => error.Unsupported,
        };
    }

    // ── 事务（对应 C# `DbSession.BeginTransaction/Commit/Rollback`）──────────

    pub fn inTransaction(self: *const Session) bool {
        return self.tx_depth > 0;
    }

    /// 开始（或嵌套进入）事务，返回剩余计数。
    /// 与 C# 一致：**只有计数从 0 变为 1 时才真正 BEGIN**，嵌套只是计数。
    pub fn beginTransaction(self: *Session, level: IsolationLevel) !u32 {
        if (self.read_only) return error.ReadOnly;

        const is_outer = self.tx_depth == 0;
        self.tx_depth += 1;
        errdefer self.tx_depth -= 1;

        if (!is_outer) return self.tx_depth;

        switch (self.kind) {
            .sqlite => {
                _ = try self.execute("BEGIN", &.{});
            },
            .mysql => {
                if (level != .default) {
                    const text = level.sqlText() orelse {
                        std.debug.print("[zcode] 事务：MySQL 不支持隔离级别 {s}\n", .{@tagName(level)});
                        return error.Unsupported;
                    };
                    const sql = try std.fmt.allocPrint(self.gpa, "SET TRANSACTION ISOLATION LEVEL {s}", .{text});
                    defer self.gpa.free(sql);
                    _ = try self.execute(sql, &.{});
                }
                _ = try self.execute("START TRANSACTION", &.{});
            },
            .postgresql => {
                if (level != .default) {
                    const text = level.sqlText() orelse {
                        std.debug.print("[zcode] 事务：PostgreSQL 不支持隔离级别 {s}\n", .{@tagName(level)});
                        return error.Unsupported;
                    };
                    const sql = try std.fmt.allocPrint(self.gpa, "BEGIN ISOLATION LEVEL {s}", .{text});
                    defer self.gpa.free(sql);
                    _ = try self.execute(sql, &.{});
                } else {
                    _ = try self.execute("BEGIN", &.{});
                }
            },
            else => return error.Unsupported,
        }
        return self.tx_depth;
    }

    /// 提交（计数减一；减到 0 时才真正 COMMIT），返回剩余计数。
    pub fn commit(self: *Session) !u32 {
        if (self.tx_depth == 0) return error.NoTransaction;

        self.tx_depth -= 1;
        errdefer self.tx_depth += 1;

        if (self.tx_depth == 0) {
            switch (self.kind) {
                .sqlite, .mysql, .postgresql => _ = try self.execute("COMMIT", &.{}),
                else => return error.Unsupported,
            }
        }
        return self.tx_depth;
    }

    /// 回滚（计数减一；减到 0 时才真正 ROLLBACK），返回剩余计数。
    /// `ignore_exception` = true 时吞掉数据库错误（与 C# `Rollback(ignoreException = true)` 一致）。
    pub fn rollback(self: *Session, ignore_exception: bool) !u32 {
        if (self.tx_depth == 0) {
            if (ignore_exception) return 0;
            return error.NoTransaction;
        }

        self.tx_depth -= 1;
        if (self.tx_depth > 0) return self.tx_depth;

        switch (self.kind) {
            .sqlite, .mysql, .postgresql => {
                _ = self.execute("ROLLBACK", &.{}) catch |e| {
                    if (ignore_exception) {
                        std.debug.print("[zcode] 回滚失败（已忽略）：{s}；{s}\n", .{ @errorName(e), self.lastError() });
                        return 0;
                    }
                    return e;
                };
            },
            else => return error.Unsupported,
        }
        return 0;
    }

    /// 作用域事务（对应 C# `EntityTransaction<T>`）：`deinit` 时未提交即自动回滚。
    pub const Scoped = struct {
        session: *Session,
        finished: bool = false,

        pub fn begin(session: *Session) !Scoped {
            return beginWith(session, .default);
        }

        pub fn beginWith(session: *Session, level: IsolationLevel) !Scoped {
            _ = try session.beginTransaction(level);
            return .{ .session = session };
        }

        pub fn commit(self: *Scoped) !void {
            _ = try self.session.commit();
            self.finished = true;
        }

        pub fn rollback(self: *Scoped) void {
            _ = self.session.rollback(true) catch 0;
            self.finished = true;
        }

        /// 未提交就离开作用域 → 回滚（吞掉异常，保证 defer ��不会炸）
        pub fn deinit(self: *Scoped) void {
            if (!self.finished) self.rollback();
        }
    };
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
