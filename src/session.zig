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
const tds = @import("zzig").tds;
const tdengine = @import("zzig").tdengine;
const influxdb = @import("zzig").influxdb;
const clickhouse = @import("zzig").clickhouse;
const mongodb = @import("zzig").mongodb;
const Value = @import("zzig").db.Value;
const DatabaseKind = @import("dialect.zig").DatabaseKind;
const setting = @import("setting.zig");
const clock = @import("clock.zig");

pub const Row = sqlite.Row; // == zzig.db.Row，两个驱动共用同一行结构

// ── SQL 日志接收器 ──────────────────────────────────────────────
//
// 口径对齐 C# `DbSession.WriteSQL`：是否输出由 `ShowSQL` 决定，写到 `SQLPath` 目录或当前日志。
// 本库**不自己造文件日志**（轮转/目录/追加策略各项目已有），而是把拼好的文本交给接收器：
//   - `writeFn` 为空 → 写 stderr（开发期最省事）；
//   - 应用启动时 `setSqlSink` 一次，接到自己的日志（写文件、上报、面板「SQL 列表」都可以）。
// `SQLPath` 的语义因此由应用层实现（把接收到的文本写到该目录）。

pub const SqlSink = struct {
    ctx: ?*anyopaque = null,
    writeFn: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
};

var sql_sink: SqlSink = .{};

/// 设置 SQL 日志接收器（应用启动时调一次）。
pub fn setSqlSink(sink: SqlSink) void {
    sql_sink = sink;
}

/// 取当前接收器（用例里保存/恢复用）。
pub fn sqlSinkSnapshot() SqlSink {
    return sql_sink;
}

fn writeSqlLog(text: []const u8) void {
    if (sql_sink.writeFn) |f| {
        f(sql_sink.ctx, text);
        return;
    }
    std.debug.print("{s}\n", .{text});
}

/// 追加 `text`，超过 `max` 时截断：INSERT 前后各留一半（C# `GetSql` 同口径），其余截尾部。
fn appendTruncated(b: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, text: []const u8, max: usize) !void {
    if (max == 0 or text.len <= max) {
        try b.appendSlice(a, text);
        return;
    }
    // 上限小到没法「前后各半」时直接截断，别产出比原文还长的“截断文本”
    if (max < 16) {
        try b.appendSlice(a, text[0..max]);
        return;
    }
    if (text.len >= 6 and std.ascii.eqlIgnoreCase(text[0..6], "insert")) {
        const half = max / 2;
        try b.appendSlice(a, text[0..half]);
        try b.appendSlice(a, "......");
        try b.appendSlice(a, text[text.len - half ..]);
    } else {
        try b.appendSlice(a, text[0..max]);
        try b.appendSlice(a, "...");
    }
}

/// 渲染一个绑定参数（超长文本按 `budget` 截断并标出原长度）。
fn appendParamValue(b: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: Value, budget: usize) !void {
    switch (v) {
        .null => try b.appendSlice(a, "null"),
        .boolean => |x| try b.appendSlice(a, if (x) "true" else "false"),
        .int => |x| {
            var nb: [32]u8 = undefined;
            try b.appendSlice(a, std.fmt.bufPrint(&nb, "{d}", .{x}) catch "?");
        },
        .float => |x| {
            var nb: [40]u8 = undefined;
            try b.appendSlice(a, std.fmt.bufPrint(&nb, "{d}", .{x}) catch "?");
        },
        .decimal => |x| {
            var nb: [64]u8 = undefined;
            try b.appendSlice(a, std.fmt.bufPrint(&nb, "{}", .{x}) catch "?");
        },
        .datetime => |x| {
            var nb: [64]u8 = undefined;
            try b.appendSlice(a, std.fmt.bufPrint(&nb, "{}", .{x}) catch "?");
        },
        .text => |t| {
            if (budget > 0 and t.len > budget) {
                var nb: [32]u8 = undefined;
                try b.appendSlice(a, std.fmt.bufPrint(&nb, "[{d}]", .{t.len}) catch "");
                try b.appendSlice(a, t[0..budget]);
                try b.appendSlice(a, "...");
            } else {
                try b.appendSlice(a, t);
            }
        },
        .blob => |t| {
            var nb: [32]u8 = undefined;
            try b.appendSlice(a, std.fmt.bufPrint(&nb, "[{d}]0x{x}", .{ t.len, t[0..@min(t.len, 8)] }) catch "[blob]");
            if (t.len > 8) try b.appendSlice(a, "...");
        },
    }
}

/// 深拷贝行集：行结构、列名、以及 `text` / `blob` 的字节都重新分配。
///
/// 为什么必须深拷贝：`Session.queryRows` 返回的行**指向会话内存**，会话 `deinit` 后全部失效。
/// 想把结果带出会话作用域（如 `Dal.queryAlloc` 直查询），必须整份复制，不能只 `dupe(Row)`——
/// 那样只复制了行结构，字符串仍是悬垂指针（读到已释放内存会得到乱数据，甚至触发 union 标签错乱）。
pub fn dupRowsAlloc(gpa: std.mem.Allocator, rows: []const Row) ![]Row {
    const out = try gpa.alloc(Row, rows.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |r| freeRow(gpa, r);
        gpa.free(out);
    }

    for (rows, 0..) |row, i| {
        const names = try gpa.alloc([]const u8, row.names.len);
        for (row.names, 0..) |n, k| names[k] = try gpa.dupe(u8, n);

        const values = try gpa.alloc(Value, row.values.len);
        for (row.values, 0..) |v, k| {
            values[k] = switch (v) {
                .text => |t| .{ .text = try gpa.dupe(u8, t) },
                .blob => |b| .{ .blob = try gpa.dupe(u8, b) },
                else => v,
            };
        }
        out[i] = .{ .names = names, .values = values };
        filled = i + 1;
    }
    return out;
}

/// 释放 `dupRowsAlloc` 产出的行集。
pub fn freeRows(gpa: std.mem.Allocator, rows: []const Row) void {
    for (rows) |r| freeRow(gpa, r);
    gpa.free(rows);
}

fn freeRow(gpa: std.mem.Allocator, row: Row) void {
    for (row.names) |n| gpa.free(n);
    gpa.free(row.names);
    for (row.values) |v| {
        switch (v) {
            .text => |t| gpa.free(t),
            .blob => |b| gpa.free(b),
            else => {},
        }
    }
    gpa.free(row.values);
}

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

/// 会话底层驱动（SQLite / MySQL / PostgreSQL / SQL Server / TDengine / InfluxDB）。
pub const Driver = union(enum) {
    sqlite: sqlite.Db,
    mysql: mysql.Conn,
    postgres: postgres.Conn,
    sqlserver: tds.Conn,
    /// TDengine：REST `/rest/sql`；无自增、无事务
    tdengine: tdengine.Conn,
    /// InfluxDB：`execute` = 写 Line Protocol，`queryRows` = Flux / InfluxQL
    influxdb: influxdb.Conn,
    /// ClickHouse：HTTP 8123，SQL 文本直发，`default_format=JSONCompact`
    clickhouse: clickhouse.Conn,
    /// MongoDB：**文档库**，SQL 路径不适用；用 `Session.mongodbConn()` 走文档 API
    mongodb: mongodb.Conn,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    driver: Driver,
    read_only: bool = false,
    arena: std.heap.ArenaAllocator,
    /// 事务嵌套计数（0 = 不在事务中；1 = 最外层，真正持有 BEGIN）
    tx_depth: u32 = 0,

    // ---- SQL 日志（对应 C# `DbSession.ShowSQL` / `GetSql` / `WriteSQL`）----
    /// SQL 输出开关：`null` = 跟随全局 `Setting.current().show_sql`
    /// （配置文件 `Config/XCode.config:ShowSQL=true` 打开）
    show_sql: ?bool = null,
    /// 输出日志时 SQL 最大长度（0 = 跟随全局 `sql_max_length`；<0 = 不截断）
    sql_max_length: i32 = 0,
    /// 慢 SQL 阈值毫秒（<0 = 跟随全局 `trace_sql_time`；0 = 不跟踪）
    trace_sql_time: i32 = -1,
    /// 日志前缀里的连接名（由 `Dal` 填，**只借用不拥有**）
    conn_name: []const u8 = "",

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
            .sqlserver => |*conn| conn.deinit(),
            .tdengine => |*conn| conn.deinit(),
            .influxdb => |*conn| conn.deinit(),
            .clickhouse => |*conn| conn.deinit(),
            .mongodb => |*conn| conn.deinit(),
        }
    }

    /// MongoDB 是**文档库**，没有 SQL：需要集合/文档操作时用这个入口（≂ C# 侧直接用 MongoDB.Driver）。
    pub fn mongodbConn(self: *Session) ?*mongodb.Conn {
        return switch (self.driver) {
            .mongodb => |*conn| conn,
            else => null,
        };
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

    // ── SQL 输出开关（对应 C# `IDbSession.ShowSQL` / `SetShowSql`）──────

    /// 本会话是否输出 SQL：会话级显式设置优先，否则看全局 `Setting.show_sql`
    /// （配置文件 `Config/XCode.config:ShowSQL=true`）。
    pub fn shouldShowSql(self: *const Session) bool {
        if (self.show_sql) |v| return v;
        return setting.current().show_sql;
    }

    /// 覆盖本会话的 SQL 输出开关（作用域用法见 `showSqlScoped`）。
    pub fn setShowSql(self: *Session, value: bool) void {
        self.show_sql = value;
    }

    /// 恢复“跟随全局配置”。
    pub fn followGlobalShowSql(self: *Session) void {
        self.show_sql = null;
    }

    /// 作用域内临时开关（对应 C# `SetShowSql` 返回的 `IDisposable`）：
    /// ```
    /// var scoped = s.showSqlScoped(false);
    /// defer scoped.restore(s);
    /// ```
    pub const ShowSqlScope = struct { previous: ?bool = null };
    pub fn showSqlScoped(self: *Session, value: bool) ShowSqlScope {
        const sc = ShowSqlScope{ .previous = self.show_sql };
        self.show_sql = value;
        return sc;
    }
    pub fn restoreShowSql(self: *Session, sc: ShowSqlScope) void {
        self.show_sql = sc.previous;
    }

    /// 是否需要计时（要么要输出 SQL，要么开了慢 SQL 跟踪）。
    /// **两个都关时完全不取时间戳**，不给热路径增加开销。
    fn sqlTimingNeeded(self: *const Session) bool {
        if (self.shouldShowSql()) return true;
        const cfg = setting.current();
        const trace_ms: i32 = if (self.trace_sql_time >= 0) self.trace_sql_time else cfg.trace_sql_time;
        return trace_ms > 0;
    }

    /// 输出一条 SQL 日志（口径对齐 C# `DbSession.GetSql` / `WriteSQL`）：
    /// - 前缀 `[连接名]`，参数拼成 ` [0=值, 1=值]`（C# 用参数名，本仓只有位置参数，用序号）；
    /// - 超过 `sql_max_length` 截断（INSERT 前后各留一半，其余截尾部）；
    /// - **慢 SQL**（`>= trace_sql_time` 毫秒）即使 `ShowSQL=false` 也输出，并附 `(N ms)`；
    /// - `SQLPath` 由应用层的 `SqlSink` 实现（本库不自己造文件日志）。
    fn logSql(self: *Session, sql: []const u8, params: []const Value, elapsed_ms: u64) void {
        if (sql.len == 0) return;

        const cfg = setting.current();
        const trace_ms: i32 = if (self.trace_sql_time >= 0) self.trace_sql_time else cfg.trace_sql_time;
        const slow = trace_ms > 0 and elapsed_ms >= @as(u64, @intCast(trace_ms));
        if (!self.shouldShowSql() and !slow) return;

        const max_len: i32 = if (self.sql_max_length != 0) self.sql_max_length else cfg.sql_max_length;
        const a = self.gpa;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);

        buf.append(a, '[') catch return;
        buf.appendSlice(a, if (self.conn_name.len > 0) self.conn_name else "-") catch return;
        buf.appendSlice(a, "] ") catch return;

        // 先按长度截断 SQL 本体，再拼参数——避免超长 SQL + 参数把日志撑爆
        appendTruncated(&buf, a, sql, if (max_len > 0) @intCast(max_len) else 0) catch return;

        if (params.len > 0) {
            buf.appendSlice(a, " [") catch return;
            for (params, 0..) |v, i| {
                if (i > 0) buf.appendSlice(a, ", ") catch return;
                var nb: [24]u8 = undefined;
                buf.appendSlice(a, std.fmt.bufPrint(&nb, "{d}=", .{i}) catch "") catch return;
                appendParamValue(&buf, a, v, 64) catch return;
            }
            buf.append(a, ']') catch return;
        }

        if (slow) {
            var tb: [40]u8 = undefined;
            buf.appendSlice(a, std.fmt.bufPrint(&tb, "  ({d} ms)", .{elapsed_ms}) catch "") catch return;
        }

        writeSqlLog(buf.items);
    }

    /// 执行增删改（写会话才允许；只读副本在调用点即失败）。
    pub fn execute(self: *Session, sql: []const u8, params: []const Value) !usize {
        if (!self.sqlTimingNeeded()) return self.executeInner(sql, params);
        const t0 = clock.nowNs();
        const n = try self.executeInner(sql, params);
        self.logSql(sql, params, clock.nsToMs(clock.nowNs() - t0));
        return n;
    }

    fn executeInner(self: *Session, sql: []const u8, params: []const Value) !usize {
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
            .sqlserver => |*conn| {
                const n = conn.exec(sql, params) catch |e| {
                    std.debug.print("[zcode] SQL 执行失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, conn.lastError() });
                    return e;
                };
                return @intCast(n);
            },
            .tdengine => |*conn| {
                const n = conn.exec(self.arena.allocator(), sql, params) catch |e| {
                    std.debug.print("[zcode] SQL 执行失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, conn.lastError() });
                    return e;
                };
                return @intCast(n);
            },
            .influxdb => |*conn| {
                // InfluxDB 的「执行」= 写 Line Protocol（与 C# `InfluxDBSession.Insert` 一致）
                conn.write(self.arena.allocator(), sql) catch |e| {
                    std.debug.print("[zcode] InfluxDB 写入失败：{s}\n  数据（前 200 字节）: {s}\n  原因: {s}\n", .{ @errorName(e), sql[0..@min(sql.len, 200)], conn.lastError() });
                    return e;
                };
                return 0;
            },
            .clickhouse => |*conn| {
                const n = conn.exec(self.arena.allocator(), sql, params) catch |e| {
                    std.debug.print("[zcode] SQL 执行失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, conn.lastError() });
                    return e;
                };
                return @intCast(n);
            },
            .mongodb => {
                // 文档库没有 SQL：不编造一种「看起来能用」的语法（与 C# `MongoDBSession` 同口径）
                std.debug.print("[zcode] MongoDB 是文档库，不支持 SQL 执行：{s}\n  请用 `Session.mongodbConn()` 走文档 API（insert/find/update/delete）\n", .{sql[0..@min(sql.len, 120)]});
                return error.Unsupported;
            },
        }
    }

    /// 查询（返回行集，含列名）。
    pub fn queryRows(self: *Session, sql: []const u8, params: []const Value) ![]const Row {
        if (!self.sqlTimingNeeded()) return self.queryRowsInner(sql, params);
        const t0 = clock.nowNs();
        const rows = try self.queryRowsInner(sql, params);
        self.logSql(sql, params, clock.nsToMs(clock.nowNs() - t0));
        return rows;
    }

    fn queryRowsInner(self: *Session, sql: []const u8, params: []const Value) ![]const Row {
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
            .sqlserver => |*conn| {
                const r = conn.queryAlloc(self.arena.allocator(), sql, params) catch |e| {
                    std.debug.print("[zcode] 查询失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, conn.lastError() });
                    return e;
                };
                return switch (r) {
                    // TDS 侧行结构与本仓 `Row` 相同（都是 zzig.db.Row）
                    .rows => |rows| rows.rows,
                    .ok => &.{},
                };
            },
            .tdengine => |*conn| {
                const r = conn.queryAlloc(self.arena.allocator(), sql, params) catch |e| {
                    std.debug.print("[zcode] 查询失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, conn.lastError() });
                    return e;
                };
                return switch (r) {
                    .rows => |rows| rows.rows,
                    .ok => &.{},
                };
            },
            .influxdb => |*conn| {
                const r = conn.queryAlloc(self.arena.allocator(), sql, params) catch |e| {
                    std.debug.print("[zcode] 查询失败：{s}\n  语句: {s}\n  原因: {s}\n", .{ @errorName(e), sql[0..@min(sql.len, 200)], conn.lastError() });
                    return e;
                };
                return switch (r) {
                    .rows => |rows| rows.rows,
                    .ok => &.{},
                };
            },
            .clickhouse => |*conn| {
                const r = conn.queryAlloc(self.arena.allocator(), sql, params) catch |e| {
                    std.debug.print("[zcode] 查询失败：{s}\n  SQL: {s}\n  原因: {s}\n", .{ @errorName(e), sql, conn.lastError() });
                    return e;
                };
                return switch (r) {
                    .rows => |rows| rows.rows,
                    .ok => &.{},
                };
            },
            .mongodb => {
                std.debug.print("[zcode] MongoDB 是文档库，不支持 SQL 查询：{s}\n  请用 `Session.mongodbConn()` 走 `findAlloc`\n", .{sql[0..@min(sql.len, 120)]});
                return error.Unsupported;
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
            // SQL Server：插入后自动取 `SCOPE_IDENTITY()`
            .sqlserver => |*conn| conn.lastInsertId(),
            // 时序库无自增语义（主键就是时间戳）
            .tdengine => 0,
            .influxdb => 0,
            .clickhouse => 0,
            .mongodb => 0,
        };
    }

    pub fn lastError(self: *Session) []const u8 {
        return switch (self.driver) {
            .sqlite => |*db| db.lastError(),
            .mysql => |*conn| conn.lastError(),
            .postgres => |*conn| conn.lastError(),
            .sqlserver => |*conn| conn.lastError(),
            .tdengine => |*conn| conn.lastError(),
            .influxdb => |*conn| conn.lastError(),
            .clickhouse => |*conn| conn.lastError(),
            .mongodb => |*conn| conn.lastError(),
        };
    }

    /// 预编译语句，供批量写/游标读取复用（调用方负责 finalize）。
    /// MySQL / PG / SQL Server / TDengine / InfluxDB / ClickHouse 不支持这条旁路（各走驱动自己的批量 API）。
    pub fn prepare(self: *Session, sql: []const u8) !sqlite.Stmt {
        return switch (self.driver) {
            .sqlite => |*db| db.prepare(self.gpa, sql),
            .mysql => error.Unsupported,
            .postgres => error.Unsupported,
            .sqlserver => error.Unsupported,
            .tdengine => error.Unsupported,
            .influxdb => error.Unsupported,
            .clickhouse => error.Unsupported,
            .mongodb => error.Unsupported,
        };
    }

    /// `LOAD DATA LOCAL INFILE` 批量装载：**只有 MySQL 支持**，其它方言返回 `error.Unsupported`。
    /// `data` 是已按 SQL 里 `FIELDS/LINES` 规则格式化好的全部文本（由 `dbtable.loadDataBatch` 生成）。
    pub fn loadDataLocal(self: *Session, sql: []const u8, data: []const u8) !u64 {
        if (self.read_only) return error.ReadOnly;
        return switch (self.driver) {
            .mysql => |*conn| conn.loadDataLocal(sql, data) catch |e| {
                std.debug.print(
                    "[zcode] LOAD DATA LOCAL 失败：{s}\n  SQL: {s}\n  数据: {d} 字节\n  原因: {s}\n  （MySQL 8 需服务端 SET GLOBAL local_infile=1）\n",
                    .{ @errorName(e), sql, data.len, conn.lastError() },
                );
                return e;
            },
            .sqlite, .postgres, .sqlserver, .tdengine, .influxdb, .clickhouse, .mongodb => error.Unsupported,
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
            .sqlserver => {
                if (level != .default) {
                    // SQL Server 的快照隔离用 `SNAPSHOT`（库级需先 `ALLOW_SNAPSHOT_ISOLATION ON`）
                    const text = if (level == .snapshot) "SNAPSHOT" else level.sqlText() orelse {
                        std.debug.print("[zcode] 事务：SQL Server 不支持隔离级别 {s}\n", .{@tagName(level)});
                        return error.Unsupported;
                    };
                    const sql = try std.fmt.allocPrint(self.gpa, "SET TRANSACTION ISOLATION LEVEL {s}", .{text});
                    defer self.gpa.free(sql);
                    _ = try self.execute(sql, &.{});
                }
                _ = try self.execute("BEGIN TRANSACTION", &.{});
            },
            else => {
                std.debug.print("[zcode] 事务：{s} 不支持跨语句事务（时序/文档库无事务语义），已拒绝\n", .{self.kind.name()});
                return error.Unsupported;
            },
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
                .sqlite, .mysql, .postgresql, .sqlserver => _ = try self.execute("COMMIT", &.{}),
                else => {
                    std.debug.print("[zcode] 提交：{s} 不支持事务\n", .{self.kind.name()});
                    return error.Unsupported;
                },
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
            .sqlite, .mysql, .postgresql, .sqlserver => {
                _ = self.execute("ROLLBACK", &.{}) catch |e| {
                    if (ignore_exception) {
                        std.debug.print("[zcode] 回滚失败（已忽略）：{s}；{s}\n", .{ @errorName(e), self.lastError() });
                        return 0;
                    }
                    return e;
                };
            },
            else => {
                std.debug.print("[zcode] 回滚：{s} 不支持事务\n", .{self.kind.name()});
                return error.Unsupported;
            },
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
