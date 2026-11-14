//! 会话连接池（对应 Rust `Pek.RCode/src/pool.rs`；C# 由 ADO.NET 连接池提供同等能力）。
//!
//! ## 为什么需要
//!
//! 同步单连接模型下，每次取会话都真的 `open`（SQLite 打开文件 / MySQL 走 TCP 握手 + 鉴权），
//! 高频短请求会被连接开销吃掉。池化后一次握手可复用多次。
//!
//! ## 语义（与 ADO.NET 连接池对齐的部分）
//!
//! - `max_size`：**上限**，池 + 借出总数达到上限后再借返回 `error.PoolExhausted`（不阻塞、不排队，
//!   避免在同步库里引入隐式等待）；调用方应自己控制并发度。
//! - `idle_timeout_ms`：空闲超过该时长的会话在下次借出时被关闭回收（防止连着一夜的半死连接）。
//! - 借出前**不**做 `SELECT 1` 探活：探活本身是一次往返，池的价值会被抵消；
//!   改为「用坏了就丢」——`release` 时若会话已断（`broken` / 句柄为空）直接关闭，不放回池。
//! - **事务中的会话不放回池**：`tx_depth > 0` 时 `release` 直接关闭该连接
//!   （宁可多一次握手，也不让未提交事务污染下一个调用方）。
//! - `:memory:` 库必须关闭池化：每个连接是**独立数据库**，复用会让调用方看到不同的库。
//!   由 `Dal.supportsPooling()` 判定，本模块只负责机制。
//!
//! ## 线程模型
//!
//! 本库是同步单连接模型，`SessionPool` **不是线程安全的**；多线程共享需外层加锁。

const std = @import("std");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const clock = @import("clock.zig");

pub const Options = struct {
    /// 池 + 借出总数上限
    max_size: usize = 16,
    /// 空闲回收阈值（0 = 不回收）
    idle_timeout_ms: u64 = 300_000,
    /// 初始化时预热数量（0 = 不预热）
    prewarm: usize = 0,
};

pub const Stats = struct {
    /// 当前空闲数
    idle: usize = 0,
    /// 当前借出数
    in_use: usize = 0,
    /// 累计新建连接数
    created: usize = 0,
    /// 累计复用次数（命中空闲）
    reused: usize = 0,
    /// 累计丢弃数（用坏 / 事务中 / 空闲超时）
    discarded: usize = 0,
    /// 借出峰值
    peak_in_use: usize = 0,
    max_size: usize = 0,

    /// 复用率 = 复用 / (复用 + 新建)；无任何借出时为 0。
    pub fn reuseRatio(self: Stats) f64 {
        const total = self.reused + self.created;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.reused)) / @as(f64, @floatFromInt(total));
    }

    pub fn describeAlloc(self: Stats, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            gpa,
            "连接池：空闲 {d} / 借出 {d} / 上限 {d}；新建 {d} / 复用 {d}（{d:.1}%）/ 丢弃 {d}；峰值 {d}",
            .{
                self.idle,      self.in_use,      self.max_size,
                self.created,   self.reused,      @as(f64, self.reuseRatio() * 100.0),
                self.discarded, self.peak_in_use,
            },
        );
    }
};

/// 打开新会话的工厂（由 `Dal` 注入，避免 `pool` 反向依赖 `dal` 形成循环）。
pub const Factory = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque) anyerror!Session,
};

const Idle = struct {
    session: Session,
    last_used_ms: i64,
};

pub const SessionPool = struct {
    gpa: std.mem.Allocator,
    factory: Factory,
    opts: Options,
    idle: std.ArrayListUnmanaged(Idle) = .empty,
    in_use: usize = 0,
    created: usize = 0,
    reused: usize = 0,
    discarded: usize = 0,
    peak_in_use: usize = 0,

    pub fn init(gpa: std.mem.Allocator, factory: Factory, opts: Options) SessionPool {
        return .{ .gpa = gpa, .factory = factory, .opts = opts };
    }

    pub fn deinit(self: *SessionPool) void {
        self.clear();
        self.idle.deinit(self.gpa);
    }

    /// 预热：事先建好 `n` 个空闲连接（不超过上限）。
    pub fn prewarm(self: *SessionPool, n: usize) usize {
        var made: usize = 0;
        while (made < n and self.totalCount() < self.opts.max_size) : (made += 1) {
            const s = self.factory.open(self.factory.ctx) catch break;
            self.idle.append(self.gpa, .{ .session = s, .last_used_ms = clock.nowMs() }) catch {
                var owned = s;
                owned.deinit();
                break;
            };
            self.created += 1;
        }
        return made;
    }

    /// 借一个会话：优先复用空闲；否则在上限内新建；超限报 `error.PoolExhausted`。
    pub fn acquire(self: *SessionPool) !Session {
        _ = self.purgeExpired();

        while (self.idle.items.len > 0) {
            const entry = self.idle.pop().?;
            if (isUsable(&entry.session)) {
                self.reused += 1;
                self.noteAcquired();
                return entry.session;
            }
            var dead = entry.session;
            dead.deinit();
            self.discarded += 1;
        }

        if (self.totalCount() >= self.opts.max_size) return error.PoolExhausted;

        const s = try self.factory.open(self.factory.ctx);
        self.created += 1;
        self.noteAcquired();
        return s;
    }

    /// 归还会话。事务中 / 已断开的会话**关闭丢弃**，其余放回空闲。
    pub fn release(self: *SessionPool, s: Session) void {
        var owned = s;
        if (owned.tx_depth > 0) {
            std.debug.print("[zcode] 连接池：归还的会话仍处于事务中（depth={d}），已丢弃以免污染后续调用\n", .{owned.tx_depth});
            owned.deinit();
            self.discarded += 1;
            self.noteReleased();
            return;
        }
        if (!isUsable(&owned)) {
            owned.deinit();
            self.discarded += 1;
            self.noteReleased();
            return;
        }

        owned.resetResults();
        self.idle.append(self.gpa, .{ .session = owned, .last_used_ms = clock.nowMs() }) catch {
            owned.deinit();
            self.discarded += 1;
            self.noteReleased();
            return;
        };
        self.noteReleased();
    }

    /// 清空空闲连接（借出的不受影响）。
    pub fn clear(self: *SessionPool) void {
        for (self.idle.items) |*entry| {
            entry.session.deinit();
            self.discarded += 1;
        }
        self.idle.clearRetainingCapacity();
    }

    pub fn idleCount(self: *const SessionPool) usize {
        return self.idle.items.len;
    }

    pub fn totalCount(self: *const SessionPool) usize {
        return self.idle.items.len + self.in_use;
    }

    pub fn stats(self: *const SessionPool) Stats {
        return .{
            .idle = self.idle.items.len,
            .in_use = self.in_use,
            .created = self.created,
            .reused = self.reused,
            .discarded = self.discarded,
            .peak_in_use = self.peak_in_use,
            .max_size = self.opts.max_size,
        };
    }

    /// 丢弃超时未使用的空闲连接（调用方不需要关心，`acquire` 会自动做）。
    pub fn purgeExpired(self: *SessionPool) usize {
        if (self.opts.idle_timeout_ms == 0 or self.idle.items.len == 0) return 0;
        const now = clock.nowMs();
        const limit: i64 = @intCast(self.opts.idle_timeout_ms);

        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.idle.items.len) {
            const age = now - self.idle.items[i].last_used_ms;
            if (age > limit) {
                var entry = self.idle.swapRemove(i);
                entry.session.deinit();
                self.discarded += 1;
                removed += 1;
                continue;
            }
            i += 1;
        }
        return removed;
    }

    fn noteAcquired(self: *SessionPool) void {
        self.in_use += 1;
        if (self.in_use > self.peak_in_use) self.peak_in_use = self.in_use;
    }

    fn noteReleased(self: *SessionPool) void {
        if (self.in_use > 0) self.in_use -= 1;
    }
};

/// 会话是否还能用（MySQL 已断 / SQLite 句柄已关都算不可用）。
fn isUsable(s: *const Session) bool {
    return switch (s.driver) {
        .sqlite => |db| db.handle != null,
        .mysql => |conn| !conn.closed,
        .postgres => |conn| !conn.closed,
        .sqlserver => |conn| !conn.closed,
        // HTTP 驱动没有可探测的连接句柄：只要会话还在就视为可用（探活靠 ping，不在池路径上做）
        .tdengine, .influxdb, .clickhouse, .mongodb => true,
        // DuckDB 是嵌入式单进程库：连接池没有意义（且同名文件多开会抢锁）
        .duckdb => false,
        // Oracle（OCI）：会话在手就可用（断线由 `lastError` + 业务重试兜底）
        .oracle => |conn| conn.svc != null,
        // ODBC：连接句柄还在就可用
        .odbc => |conn| conn.dbc != null,
    };
}

// ───────────────────────────── 测试 ─────────────────────────────

const sqlite = @import("zzig").sqlite;

/// 测试用工厂：打开独立的内存库并建一张表（够验证池的复用/丢弃语义）。
const TestCtx = struct {
    lib: *sqlite.Lib,
    opened: usize = 0,

    fn open(ctx: *anyopaque) anyerror!Session {
        const self: *TestCtx = @ptrCast(@alignCast(ctx));
        const db = try sqlite.Db.open(self.lib, ":memory:");
        self.opened += 1;
        return Session.init(std.heap.page_allocator, .sqlite, db);
    }
};

fn makeTestPool(a: std.mem.Allocator, ctx: *TestCtx, opts: Options) !SessionPool {
    return SessionPool.init(a, .{ .ctx = @ptrCast(ctx), .open = TestCtx.open }, opts);
}

test "连接池：复用、上限、统计" {
    const a = std.testing.allocator;
    var lib = sqlite.Lib.load(a) catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer lib.deinit();

    var ctx = TestCtx{ .lib = &lib };
    var pool = try makeTestPool(a, &ctx, .{ .max_size = 2, .idle_timeout_ms = 0 });
    defer pool.deinit();

    // 第一次借：新建
    const s1 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().created);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().in_use);

    // 归还后复用
    pool.release(s1);
    try std.testing.expectEqual(@as(usize, 1), pool.idleCount());
    const s2 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().created);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().reused);

    // 第二个连接
    const s3 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 2), pool.stats().created);
    try std.testing.expectEqual(@as(usize, 2), pool.stats().in_use);
    try std.testing.expectEqual(@as(usize, 2), pool.stats().peak_in_use);

    // 超上限：不排队、直接报错（避免同步库里隐式阻塞）
    try std.testing.expectError(error.PoolExhausted, pool.acquire());

    pool.release(s2);
    pool.release(s3);
    try std.testing.expectEqual(@as(usize, 2), pool.idleCount());
    try std.testing.expectEqual(@as(usize, 0), pool.stats().in_use);

    const desc = try pool.stats().describeAlloc(a);
    defer a.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "新建 2") != null);
}

test "连接池：事务中的会话归还即丢弃" {
    const a = std.testing.allocator;
    var lib = sqlite.Lib.load(a) catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer lib.deinit();

    var ctx = TestCtx{ .lib = &lib };
    var pool = try makeTestPool(a, &ctx, .{ .max_size = 4, .idle_timeout_ms = 0 });
    defer pool.deinit();

    var s = try pool.acquire();
    _ = try s.beginTransaction(.default);
    pool.release(s);

    // 事务中不放回池
    try std.testing.expectEqual(@as(usize, 0), pool.idleCount());
    try std.testing.expectEqual(@as(usize, 1), pool.stats().discarded);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().in_use);
}

test "连接池：预热与清空" {
    const a = std.testing.allocator;
    var lib = sqlite.Lib.load(a) catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer lib.deinit();

    var ctx = TestCtx{ .lib = &lib };
    var pool = try makeTestPool(a, &ctx, .{ .max_size = 3, .idle_timeout_ms = 0 });
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 2), pool.prewarm(2));
    try std.testing.expectEqual(@as(usize, 2), pool.idleCount());
    try std.testing.expectEqual(@as(usize, 2), pool.stats().created);

    // 预热不超过上限
    try std.testing.expectEqual(@as(usize, 1), pool.prewarm(5));
    try std.testing.expectEqual(@as(usize, 3), pool.totalCount());

    pool.clear();
    try std.testing.expectEqual(@as(usize, 0), pool.idleCount());
    try std.testing.expectEqual(@as(usize, 3), pool.stats().discarded);
}
