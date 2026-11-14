//! 高并发验证（用户口径：**「至少上百万甚至上亿物联网设备高并发」**）。
//!
//! 这里验证的不是「能编译」，而是**多线程 + 多连接 + 同一个库文件**时的真实行为：
//! - 并发插入不丢行、不自增冲突（连接池/驱动/事务边界）；
//! - 并发累加不丢更新（`col = col + ?` 的 SQL 侧原子性，这是「多系统共用表 + 统计字段」的地基）。
//!
//! 为什么用**多个 `Dal`（各自独立连接）**而不是一个 Dal 多线程共用：
//! 连接的会话状态（事务、临时表、语句缓存）本来就不是线程安全的，真实部署也是
//! 「一个进程一个连接 / 一个实例一条池化连接」。用多连接才测得到「WAL + busy_timeout
//! 能否扛住并发写」，这才是现场会遇到的问题。
//!
//! 规模刻意压小（4 线程 × 100 次）：并发用例要进回归门禁，必须在秒级完成；
//! 它验证的是**正确性**，吞吐数字看 `zig build bench`。

const std = @import("std");
const zcode = @import("zcode");

const model_xml =
    \\<EntityModel><Tables><Table Name="Counter" TableName="DH_Counter">
    \\  <Columns>
    \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\    <Column Name="Code" DataType="String" Length="64" />
    \\    <Column Name="Total" DataType="Int64" />
    \\  </Columns>
    \\</Table>
    \\<Table Name="LockRow" TableName="DH_LockRow">
    \\  <Columns>
    \\    <Column Name="Code" DataType="String" Length="64" PrimaryKey="True" />
    \\    <Column Name="Total" DataType="Int64" />
    \\  </Columns>
    \\</Table></Tables></EntityModel>
;

const threads = 4;
const per_thread_ops = 100;

/// 打开一个「独立连接」的 Dal（WAL + NORMAL：多连接并发写的前提，见 `dal.zig` 的并发档位说明）。
fn openConn(a: std.mem.Allocator, db_path: []const u8) !zcode.Dal {
    var m = try zcode.EntityModel.parse(a, model_xml);
    errdefer m.deinit();
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite;JournalMode=WAL;Synchronous=NORMAL", .{db_path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

/// 线程体用 page_allocator（线程安全）做 arena，避免跨线程共用测试分配器。
fn workerArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
}

/// 线程里的错误收集：用原子标记，线程结束后由主线程断言。
const Failure = struct {
    hit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    message: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn insertWorker(db_path: []const u8, worker_id: usize, fail: *Failure) void {
    var arena = workerArena();
    defer arena.deinit();
    const a = arena.allocator();

    var dal = openConn(a, db_path) catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发插入] worker {d} 开连接失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer dal.deinit();

    var s = dal.openSession() catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发插入] worker {d} 开会话失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer s.deinit();

    const table = dal.table("Counter") catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发插入] worker {d} 取表失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };

    var i: usize = 0;
    while (i < per_thread_ops) : (i += 1) {
        const code = std.fmt.allocPrint(a, "w{d}-{d}", .{ worker_id, i }) catch return;
        _ = table.insert(&s, &[_]zcode.sqlbuild.Field{
            .{ .name = "Code", .value = .{ .text = code } },
            .{ .name = "Total", .value = .{ .int = 0 } },
        }) catch |e| {
            fail.hit.store(true, .release);
            std.debug.print("[并发插入] worker {d} 第 {d} 条失败：{s}\n", .{ worker_id, i, @errorName(e) });
            return;
        };
    }
}

fn accumulateWorker(db_path: []const u8, worker_id: usize, fail: *Failure) void {
    var arena = workerArena();
    defer arena.deinit();
    const a = arena.allocator();

    var dal = openConn(a, db_path) catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发累加] worker {d} 开连接失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer dal.deinit();

    var s = dal.openSession() catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发累加] worker {d} 开会话失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer s.deinit();

    const table = dal.table("Counter") catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发累加] worker {d} 取表失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };

    // 只打一行（Id=1），四个连接对同一行做 `Total = Total + 1`
    var w = zcode.Where.init(a);
    _ = w.eq("Id", .{ .int = 1 }) catch return;

    var i: usize = 0;
    while (i < per_thread_ops) : (i += 1) {
        _ = table.accumulate(&s, &[_]zcode.sqlbuild.AccumulateField{
            .{ .name = "Total", .value = .{ .int = 1 }, .mode = .add },
        }, &w) catch |e| {
            fail.hit.store(true, .release);
            std.debug.print("[并发累加] worker {d} 第 {d} 次失败：{s}\n", .{ worker_id, i, @errorName(e) });
            return;
        };
    }
}

test "并发插入：4 线程 × 100 行（各自连接，WAL）→ 400 行不丢不重" {
    const a = std.testing.allocator;

    const db_path = try zcode.File.UniqueTempName(a, "concurrency_ins", ".db");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    // 建表（用一条独立连接先 sync）
    {
        var dal = openConn(a, db_path) catch |e| {
            std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
            return;
        };
        defer dal.deinit();
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    var fail = Failure{};
    var handles: [threads]std.Thread = undefined;
    for (&handles, 0..) |*h, id| {
        h.* = try std.Thread.spawn(.{}, insertWorker, .{ db_path, id, &fail });
    }
    for (&handles) |*h| h.join();

    try std.testing.expect(!fail.hit.load(.acquire));

    var dal = try openConn(a, db_path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const table = try dal.table("Counter");
    const n = try table.count(&s, null);
    try std.testing.expectEqual(@as(i64, @intCast(threads * per_thread_ops)), n);

    // 主键唯一 + Code 不重复（并发下最容易出的两类错误）
    const rows = try s.queryRows("SELECT COUNT(DISTINCT Id) AS ids, COUNT(DISTINCT Code) AS codes FROM DH_Counter", &.{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, @intCast(threads * per_thread_ops)), rows[0].get("ids").?.asI64().?);
    try std.testing.expectEqual(@as(i64, @intCast(threads * per_thread_ops)), rows[0].get("codes").?.asI64().?);
}

test "并发累加：4 线程 × 100 次对同一行 Total+1 → 恰好 400（不丢更新）" {
    const a = std.testing.allocator;

    const db_path = try zcode.File.UniqueTempName(a, "concurrency_acc", ".db");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    {
        var dal = openConn(a, db_path) catch |e| {
            std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
            return;
        };
        defer dal.deinit();
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);

        const table = try dal.table("Counter");
        _ = try table.insert(&s, &[_]zcode.sqlbuild.Field{
            .{ .name = "Code", .value = .{ .text = "shared" } },
            .{ .name = "Total", .value = .{ .int = 0 } },
        });
    }

    var fail = Failure{};
    var handles: [threads]std.Thread = undefined;
    for (&handles, 0..) |*h, id| {
        h.* = try std.Thread.spawn(.{}, accumulateWorker, .{ db_path, id, &fail });
    }
    for (&handles) |*h| h.join();

    try std.testing.expect(!fail.hit.load(.acquire));

    var dal = try openConn(a, db_path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const table = try dal.table("Counter");
    const total = try table.maxValue(&s, "Total", null);
    try std.testing.expectEqual(@as(i64, @intCast(threads * per_thread_ops)), total.?.asI64().?);
}

// ── getOrAdd：多线程同键并发（验证进程内条带锁 + 双重检查 + 事务） ──────────────
//
// 这张表的物理主键是 `Code`（非自增），所以 `insert` 会显式写主键，
// 能真正测到「两个线程同时判定『没有』→ 各插一条」这个竞态。
// **物理表上没有唯一索引**（模型里 Code 是主键，但 SQLite 建表时主键列本身唯一）——
// 这里的关键是：若锁失效，行数就会 > 1，用例立即变红。

/// 测试专用实体：`fromRow` / `insert` / `getOrAdd` 只要求
/// `meta` / `columnValue` / `setColumnValue` / `dirty` 这四样，不必依赖 `examples/entities` 生成物。
const LockEntity = struct {
    Code: []const u8 = "",
    Total: i64 = 0,
    dirty: zcode.entity.DirtyBits = 0,

    pub const meta = zcode.entity.checkMeta(zcode.entity.EntityMeta{
        .name = "LockRow",
        .table_name = "DH_LockRow",
        .fields = &.{
            .{ .name = "Code", .data_type = .string, .length = 64, .primary_key = true },
            .{ .name = "Total", .data_type = .int64 },
        },
    });

    pub fn columnValue(self: LockEntity, index: usize) zcode.Value {
        return switch (index) {
            0 => .{ .text = self.Code },
            1 => .{ .int = self.Total },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *LockEntity, index: usize, v: zcode.Value) !void {
        switch (index) {
            0 => switch (v) {
                .text => |t| self.Code = t,
                .null => self.Code = "",
                else => {},
            },
            1 => self.Total = v.asI64() orelse 0,
            else => {},
        }
    }
};

fn createLockRow(_: *anyopaque) anyerror!LockEntity {
    return .{ .Code = "shared", .Total = 0 };
}

const GetOrAddOps = 25;

fn getOrAddWorker(db_path: []const u8, worker_id: usize, fail: *Failure, created: *std.atomic.Value(usize)) void {
    var arena = workerArena();
    defer arena.deinit();
    const a = arena.allocator();

    var dal = openConn(a, db_path) catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[getOrAdd] worker {d} 开连接失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer dal.deinit();

    var s = dal.openSession() catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[getOrAdd] worker {d} 开会话失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer s.deinit();

    var dummy: u8 = 0;
    const ctx: *anyopaque = @ptrCast(&dummy);

    var i: usize = 0;
    while (i < GetOrAddOps) : (i += 1) {
        const r = zcode.entity.getOrAdd(&dal, LockEntity, &s, &.{.{ .text = "shared" }}, ctx, createLockRow) catch |e| {
            fail.hit.store(true, .release);
            std.debug.print("[getOrAdd] worker {d} 第 {d} 次失败：{s}\n", .{ worker_id, i, @errorName(e) });
            return;
        };
        if (r.created) _ = created.fetchAdd(1, .monotonic);
        // 命中已有记录时也必须读回内容（证明「查到的是同一行」而不是空实体）
        if (!std.mem.eql(u8, r.entity.Code, "shared")) {
            fail.hit.store(true, .release);
            std.debug.print("[getOrAdd] worker {d} 读回的 Code 不对：{s}\n", .{ worker_id, r.entity.Code });
            return;
        }
    }
}

test "getOrAdd：4 线程 × 25 次同键并发 → 只插 1 行，只有 1 次 created" {
    const a = std.testing.allocator;

    const db_path = try zcode.File.UniqueTempName(a, "concurrency_getoradd", ".db");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    {
        var dal = openConn(a, db_path) catch |e| {
            std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
            return;
        };
        defer dal.deinit();
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    var fail = Failure{};
    var created = std.atomic.Value(usize).init(0);
    var handles: [threads]std.Thread = undefined;
    for (&handles, 0..) |*h, id| {
        h.* = try std.Thread.spawn(.{}, getOrAddWorker, .{ db_path, id, &fail, &created });
    }
    for (&handles) |*h| h.join();

    try std.testing.expect(!fail.hit.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), created.load(.acquire));

    var dal = try openConn(a, db_path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const table = try dal.table("LockRow");
    const n = try table.count(&s, null);
    try std.testing.expectEqual(@as(i64, 1), n);
}

// ── 连接池：多线程共享同一个池（验证内部加锁 + 名额预留不超上限 + 不泄漏） ────────

const pool_threads = 8;
const pool_ops = 40;
const pool_max = 4;

const PoolCtx = struct {
    pool: *zcode.pool.SessionPool,
    fail: *Failure,
    acquired: *std.atomic.Value(usize),
    exhausted: *std.atomic.Value(usize),
};

/// 上限只有 4、线程有 8：`PoolExhausted` 是**约定行为**（不阻塞不排队），
/// 这里自旋重试；重试次数有上界，等不到就判失败而不是挂死。
fn acquireWithRetry(ctx: PoolCtx, worker_id: usize) ?zcode.Session {
    var tries: usize = 0;
    while (tries <= 5_000_000) : (tries += 1) {
        if (ctx.pool.acquire()) |session| {
            return session;
        } else |e| {
            if (e != error.PoolExhausted) {
                ctx.fail.hit.store(true, .release);
                std.debug.print("[连接池] worker {d} 借连接失败：{s}\n", .{ worker_id, @errorName(e) });
                return null;
            }
            _ = ctx.exhausted.fetchAdd(1, .monotonic);
            std.atomic.spinLoopHint();
        }
    }
    ctx.fail.hit.store(true, .release);
    std.debug.print("[连接池] worker {d} 等不到空闲连接（已重试 {d} 次）\n", .{ worker_id, tries });
    return null;
}

fn poolWorker(ctx: PoolCtx, worker_id: usize) void {
    var i: usize = 0;
    while (i < pool_ops) : (i += 1) {
        var s = acquireWithRetry(ctx, worker_id) orelse return;

        const rows = s.queryRows("SELECT 1 AS one", &.{}) catch |e| {
            ctx.fail.hit.store(true, .release);
            std.debug.print("[连接池] worker {d} 查询失败：{s}\n", .{ worker_id, @errorName(e) });
            ctx.pool.release(s);
            return;
        };
        if (rows.len != 1 or rows[0].get("one").?.asI64().? != 1) {
            ctx.fail.hit.store(true, .release);
            std.debug.print("[连接池] worker {d} 查询结果不对（行数 {d}）\n", .{ worker_id, rows.len });
            ctx.pool.release(s);
            return;
        }

        ctx.pool.release(s);
        _ = ctx.acquired.fetchAdd(1, .monotonic);
    }
}

test "连接池：8 线程 × 40 次共享借还，上限 4 → 不超限、不泄漏、无错误" {
    const a = std.testing.allocator;

    const db_path = try zcode.File.UniqueTempName(a, "concurrency_pool", ".db");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = openConn(a, db_path) catch |e| {
        std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer dal.deinit();

    if (!dal.supportsPooling()) {
        std.debug.print("[SKIP] 该连接不支持池化（{s}）\n", .{@tagName(dal.opts.provider)});
        return;
    }

    // 先建表 + 探一次版本，避免把「Dal 首次懒初始化」算进并发窗口
    {
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
        _ = try s.queryRows("SELECT COUNT(*) AS n FROM DH_LockRow", &.{});
    }

    var p = dal.makePool(.{ .max_size = pool_max, .idle_timeout_ms = 0 });
    defer p.deinit();
    _ = p.prewarm(pool_max);

    var fail = Failure{};
    var acquired = std.atomic.Value(usize).init(0);
    var exhausted = std.atomic.Value(usize).init(0);
    const ctx = PoolCtx{ .pool = &p, .fail = &fail, .acquired = &acquired, .exhausted = &exhausted };

    var handles: [pool_threads]std.Thread = undefined;
    for (&handles, 0..) |*h, id| {
        h.* = try std.Thread.spawn(.{}, poolWorker, .{ ctx, id });
    }
    for (&handles) |*h| h.join();

    try std.testing.expect(!fail.hit.load(.acquire));
    try std.testing.expectEqual(@as(usize, pool_threads * pool_ops), acquired.load(.acquire));

    const st = p.stats();
    try std.testing.expect(st.created <= pool_max); // 并发首访没有突破上限
    try std.testing.expect(st.peak_in_use <= pool_max);
    try std.testing.expectEqual(@as(usize, 0), st.in_use); // 全部归还
    try std.testing.expectEqual(pool_max, p.idleCount()); // 空闲回到上限，说明没漏
    try std.testing.expectEqual(@as(usize, 0), st.discarded);
    std.debug.print("[连接池] 新建 {d} / 复用 {d}（{d:.1}%）/ 抢空 {d} 次\n", .{
        st.created, st.reused, st.reuseRatio() * 100.0, exhausted.load(.acquire),
    });
}
