//! 实体延迟写队列（对应 C# `EntityDeferredQueue` / `EntityExtension` 的队列写、
//! Rust `Pek.RCode/src/entity_queue.rs`）。
//!
//! 用途：高频写入场景（日志、采集、心跳）不要每条一次往返。把实体塞进队列，
//! 到量（`max_count`）或到期（`max_latency_ms`）时一次性 `saveBatch`。
//!
//! ## 语义（与 `saveBatch` 一致）
//!
//! - 新增行合并成一条多行 INSERT（按方言参数上限自动分批）；
//! - 已存在实体按脏列逐条更新；
//! - **批量插入不回写每行自增 ID**（只有最后一条能由 `lastInsertId` 得到，这是 SQL 语义决定的，
//!   不是实现取舍）。
//!
//! ## 失败语义（重点）
//!
//! - `flush` 失败时**保留待写队列**（不丢数据），并把 `last_error` 记下来；
//!   调用方可以在修好连接后重试，或显式 `clearPending()` 丢弃。
//! - `deinit` **不自动 flush**：析构里做 IO 失败无处上报，宁可让调用方显式管理，
//!   并在 `pending() > 0` 时打印告警（提示漏了 flush）。
//!
//! ## 生命周期
//!
//! 队列只持有实体**指针**，不复制实体；调用方必须保证实体存活到 flush 完成
//! （典型用法：实体放 arena 或调用方自己的集合里）。

const std = @import("std");
const entity = @import("entity.zig");
const dal_mod = @import("dal.zig");
const Dal = dal_mod.Dal;
const Session = @import("session.zig").Session;
const clock = @import("clock.zig");

// ---------------------------------------------------------------------------
// 全局凑批队列（对应 C# `Entity.SaveAsync(msDelay)` → `Meta.Session.Queue.Add(entity, msDelay)`）
//
// C# 的 `SaveAsync` **不是"每次一个线程"**，而是把实体丢进 `EntityQueue`：
// - `msDelay == 0` → 近实时桶，下一次定时器 tick（默认 1000ms）就写；
// - `msDelay > 0` → 延迟桶，到点才写；
// - 写的时候按表**合并成多行 INSERT**（新增）+ 逐条脏列更新（已存在）。
//
// 这里用一个**类型擦除**的全局队列实现同一语义：入队时把实体拷贝到堆上，
// 并记录它的「建行字段」与「保存函数」；flush 时按表分组，新增的合并成
// 一次 `insertBatch`，已存在的逐条 `save`（同一会话内，减少往返）。
// ---------------------------------------------------------------------------

/// 全局凑批队列（进程内一个即可；`dal` 在 `init` 时绑定）。
pub const Global = struct {
    const Entry = struct {
        ctx: *anyopaque,
        /// 模型里的基础表名（未分片时的物理表名）
        base_table: []const u8,
        /// 实际写入的连接名（**由 Model.xml 解析得出**，不在这里拼）
        conn: []const u8,
        /// 实际写入的物理表名（分片时为分片表名；未分片时等于 base_table）
        table_name: []const u8,
        /// 分片键（时间为分片时就是时间列的值）。非空时在 flush 阶段才解析目标，
        /// 这样“分表分库 + 凑批”能按真实分片归组。支持 datetime / int 键。
        shard_value: ?@import("zzig").db.Value = null,
        due_ms: i64,
        /// 新增实体的建行字段（已存在实体为 null）
        fieldsFn: ?*const fn (ctx: *anyopaque, a: std.mem.Allocator) anyerror![]@import("sqlbuild.zig").Field,
        /// 已存在实体的保存（脏列更新）
        saveFn: *const fn (ctx: *anyopaque, dal: *Dal, s: *Session) anyerror!void,
        /// 释放堆上的实体副本
        destroyFn: *const fn (ctx: *anyopaque, a: std.mem.Allocator) void,
    };

    gpa: std.mem.Allocator,
    dal: *Dal,
    period_ms: u64 = 1_000,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    lock: @import("zzig").compat.Mutex = .{},
    thread: ?std.Thread = null,
    stop_flag: bool = false,

    // 统计
    total_enqueued: usize = 0,
    total_flushed: usize = 0,
    flush_count: usize = 0,
    error_count: usize = 0,
    last_error: ?anyerror = null,

    pub fn init(gpa: std.mem.Allocator, dal: *Dal) Global {
        return .{ .gpa = gpa, .dal = dal };
    }

    /// 停线程 + 把剩余项写完（失败只记错）。
    pub fn deinit(self: *Global) void {
        self.stop();
        self.flushAll() catch {};
        self.entries.deinit(self.gpa);
    }

    fn ensureStarted(self: *Global) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.thread != null) return;
        self.stop_flag = false;
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    fn worker(self: *Global) void {
        while (true) {
            const step = if (self.period_ms == 0) 100 else self.period_ms;
            @import("zzig").compat.sleep(step * std.time.ns_per_ms);

            self.lock.lock();
            const should_stop = self.stop_flag;
            self.lock.unlock();
            if (should_stop) return;

            self.flushAll() catch |err| {
                std.debug.print(
                    "[zcode] 凑批队列（后台）：flush 失败（{s}），{d} 条待重试\n",
                    .{ @errorName(err), self.pending() },
                );
            };
        }
    }

    pub fn start(self: *Global) !void {
        try self.ensureStarted();
    }

    pub fn stop(self: *Global) void {
        self.lock.lock();
        const has = self.thread != null;
        self.stop_flag = true;
        self.lock.unlock();
        if (!has) return;
        if (self.thread) |th| th.join();
        self.thread = null;
    }

    pub fn pending(self: *Global) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.entries.items.len;
    }

    /// 入队（并确保后台线程已启动）。
    pub fn enqueue(self: *Global, entry: Entry) !void {
        self.lock.lock();
        try self.entries.append(self.gpa, entry);
        self.total_enqueued += 1;
        self.lock.unlock();

        try self.ensureStarted();
    }

    /// 立即写出所有到期项：**先按「连接 + 物理表」解析目标，再按目标分组**。
    ///
    /// 这就是「分表分库 + 自动凑批」的关键：只有**落到同一分片表**的实体才合并成
    /// 一条多行 INSERT，不同分片各自一批；同一批共用一次会话与一次提交。
    pub fn flushAll(self: *Global) !void {
        var taken: std.ArrayListUnmanaged(Entry) = .empty;
        defer taken.deinit(self.gpa);

        const now = clock.nowMs();
        self.lock.lock();
        var keep: std.ArrayListUnmanaged(Entry) = .empty;
        for (self.entries.items) |e| {
            if (e.due_ms <= now) {
                try taken.append(self.gpa, e);
            } else {
                try keep.append(self.gpa, e);
            }
        }
        self.entries.deinit(self.gpa);
        self.entries = keep;
        self.lock.unlock();

        if (taken.items.len == 0) return;

        // 1) 解析目标（分片键 → 连接 + 物理表）。解析失败的条目重新入队，不丢数据。
        const Target = struct {
            conn: []const u8,
            table_name: []const u8,
            shard: ?@import("shards.zig").ShardModel = null,
        };
        const targets = try self.gpa.alloc(Target, taken.items.len);
        defer {
            for (targets) |t| {
                // 分片模型由 **策略的分配器**（即 `Dal` 的 gpa）分配，不能用队列自己的 gpa 释放
                if (t.shard) |sm| sm.deinit(self.dal.gpa);
            }
            self.gpa.free(targets);
        }

        var failed = false;
        for (taken.items, 0..) |entry, i| {
            targets[i] = .{ .conn = entry.conn, .table_name = entry.table_name };
            if (entry.shard_value) |v| {
                const sm = self.dal.shardOfTable(entry.base_table, v) catch |err| {
                    self.error_count += 1;
                    self.last_error = err;
                    std.debug.print(
                        "[zcode] 凑批队列：表 {s} 分片解析失败（{s}），条目已回队列\n",
                        .{ entry.base_table, @errorName(err) },
                    );
                    targets[i] = .{ .conn = "", .table_name = "" };
                    self.pushBack(entry);
                    failed = true;
                    continue;
                };
                targets[i] = .{ .conn = sm.conn_name, .table_name = sm.table_name, .shard = sm };
            }
        }

        // 2) 按目标分组，逐组一次会话、一次多行 INSERT
        const done = try self.gpa.alloc(bool, taken.items.len);
        defer self.gpa.free(done);
        @memset(done, false);

        var flushed: usize = 0;

        for (taken.items, 0..) |_, i| {
            if (done[i] or targets[i].conn.len == 0) continue;

            var group: std.ArrayListUnmanaged(usize) = .empty;
            defer group.deinit(self.gpa);
            for (targets, 0..) |t, j| {
                if (done[j] or t.conn.len == 0) continue;
                if (!std.ascii.eqlIgnoreCase(t.conn, targets[i].conn)) continue;
                if (!std.mem.eql(u8, t.table_name, targets[i].table_name)) continue;
                try group.append(self.gpa, j);
                done[j] = true;
            }
            if (group.items.len == 0) continue;

            const err_opt = self.flushGroup(taken.items, targets[i], group.items);
            if (err_opt) |err| {
                self.error_count += 1;
                self.last_error = err;
                failed = true;
                // 整组回队列（不丢数据）；已写入的不会重放（本组在失败点之后的部分）
                for (group.items) |j| self.pushBack(taken.items[j]);
            } else {
                flushed += group.items.len;
                for (group.items) |j| taken.items[j].destroyFn(taken.items[j].ctx, self.gpa);
            }
        }

        self.total_flushed += flushed;
        self.flush_count += 1;
        if (!failed) self.last_error = null;
    }

    /// 写一组（同连接同物理表）：新增合并多行 INSERT，已存在逐条保存。
    fn flushGroup(self: *Global, entries: []const Entry, target: anytype, group: []const usize) ?anyerror {
        var s = self.dal.sessionForConn(target.conn) catch |err| {
            std.debug.print(
                "[zcode] 凑批队列：连接 {s} 开会话失败（{s}）\n",
                .{ target.conn, @errorName(err) },
            );
            return err;
        };
        defer s.deinit();

        const base = entries[group[0]].base_table;
        const shard_model = @import("shards.zig").ShardModel{
            .conn_name = target.conn,
            .table_name = target.table_name,
        };
        if (target.shard != null) {
            _ = self.dal.ensureShardTable(base, shard_model) catch |err| {
                std.debug.print(
                    "[zcode] 凑批队列：分片表 {s}#{s} 建表失败（{s}）\n",
                    .{ target.conn, target.table_name, @errorName(err) },
                );
                return err;
            };
        }

        const ref = self.dal.tableShardOn(base, shard_model) catch |err| {
            std.debug.print("[zcode] 凑批队列：表 {s} 句柄失败（{s}）\n", .{ base, @errorName(err) });
            return err;
        };

        // 新增：合并多行 INSERT（一条语句写一组，性能提升的主要来源）
        var rows: std.ArrayListUnmanaged([]@import("sqlbuild.zig").Field) = .empty;
        defer {
            for (rows.items) |r| self.gpa.free(r);
            rows.deinit(self.gpa);
        }
        var existing: std.ArrayListUnmanaged(usize) = .empty;
        defer existing.deinit(self.gpa);

        for (group) |j| {
            const e = entries[j];
            if (e.fieldsFn) |build| {
                const built = build(e.ctx, self.gpa) catch |err| return err;
                rows.append(self.gpa, built) catch |err| return err;
            } else {
                existing.append(self.gpa, j) catch |err| return err;
            }
        }

        if (rows.items.len > 0) {
            _ = ref.insertBatch(&s, rows.items) catch |err| {
                std.debug.print(
                    "[zcode] 凑批队列：表 {s}#{s} 多行插入失败（{s}）\n",
                    .{ target.conn, target.table_name, @errorName(err) },
                );
                return err;
            };
        }

        for (existing.items) |j| {
            const e = entries[j];
            e.saveFn(e.ctx, self.dal, &s) catch |err| {
                std.debug.print(
                    "[zcode] 凑批队列：表 {s}#{s} 保存失败（{s}）\n",
                    .{ target.conn, target.table_name, @errorName(err) },
                );
                return err;
            };
        }
        return null;
    }

    /// 把条目放回待写队列（失败重试）。
    fn pushBack(self: *Global, entry: Entry) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.entries.append(self.gpa, entry) catch {};
    }
};

/// 进程级默认队列（懒建；调用方在 `Dal` 释放前必须先 `stopGlobal()`）。
var global_instance: ?*Global = null;
var global_lock: @import("zzig").compat.Mutex = .{};

/// 取/建默认凑批队列。
pub fn globalFor(gpa: std.mem.Allocator, dal: *Dal) !*Global {
    global_lock.lock();
    defer global_lock.unlock();
    if (global_instance) |q| {
        if (q.dal != dal) {
            std.debug.print("[zcode] 凑批队列：已绑定另一个 Dal，请先 stopGlobal()\n", .{});
            return error.QueueBusy;
        }
        return q;
    }
    const q = try gpa.create(Global);
    q.* = Global.init(gpa, dal);
    global_instance = q;
    return q;
}

/// 停默认队列并释放（**在 `Dal` 释放之前调用**）。
pub fn stopGlobal() void {
    global_lock.lock();
    const q = global_instance;
    global_instance = null;
    global_lock.unlock();
    if (q) |queue| {
        queue.deinit();
        queue.gpa.destroy(queue);
    }
}

/// 立即 flush 默认队列（等价于定时器 tick；单测与“进程退出前落盘”用）。
pub fn flushGlobal() !void {
    global_lock.lock();
    const inst = global_instance;
    global_lock.unlock();
    if (inst) |queue| try queue.flushAll();
}

pub const Policy = struct {
    /// 队列长度达到该值即自动 flush（0 = 不按条数触发）
    max_count: usize = 100,
    /// 距上次 flush 超过该毫秒数即自动 flush（0 = 不按时间触发）
    max_latency_ms: u64 = 1_000,
    /// 后台线程的轮询周期（毫秒）。对齐 C# `EntityQueue.Period`（默认 1000）
    period_ms: u64 = 1_000,
    /// 队列上限。超过时 `add` 报 `error.QueueFull`（C# 是堵塞等待，Zig 侧不阻塞业务线程）
    max_entity: usize = 1_000_000,
};

/// 写入方式（对齐 C# `DataMethod`）。
pub const Method = enum {
    /// 新增/更新（按主键判断，走 `saveBatch` 语义）
    insert,
    /// 插入或更新（`SaveModes.upsert`）
    upsert,
    /// 替换（`SaveModes.replace`）
    replace,
    /// 只插入（实体必须主键为 0）
    insert_only,
    /// 删除（按主键）
    delete,
};

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// 延迟桶元素
        const Delayed = struct { e: *T, due_ms: i64 };

        gpa: std.mem.Allocator,
        dal: *Dal,
        policy: Policy,
        items: std.ArrayListUnmanaged(*T) = .empty,
        last_flush_ms: i64,

        /// 延迟保存桶（C# `DelayEntities`）：到期才写
        delayed: std.ArrayListUnmanaged(Delayed) = .empty,
        /// 写入方式（C# `EntityQueue.Method`）
        method: Method = .insert,
        /// 保护 `items` / `delayed` / `stop_flag`（后台线程与调用方共享）
        lock: @import("zzig").compat.Mutex = .{},
        thread: ?std.Thread = null,
        stop_flag: bool = false,

        // ── 统计（可观测，避免「队列悄悄堆积」）──
        total_added: usize = 0,
        total_flushed: usize = 0,
        flush_count: usize = 0,
        error_count: usize = 0,
        /// 最近一次 flush 的失败原因（成功时清空）
        last_error: ?anyerror = null,

        pub fn init(gpa: std.mem.Allocator, dal: *Dal, policy: Policy) Self {
            return .{ .gpa = gpa, .dal = dal, .policy = policy, .last_flush_ms = clock.nowMs() };
        }

        pub fn deinit(self: *Self) void {
            // 对齐 C# `Dispose`：先停后台线程（它会做最后一次 flush）
            self.stop();
            if (self.items.items.len > 0 or self.delayed.items.len > 0) {
                std.debug.print(
                    "[zcode] 延迟写队列：析构时仍有 {d} 条未写入（请确认是否漏了 flush）\n",
                    .{self.items.items.len + self.delayed.items.len},
                );
            }
            self.items.deinit(self.gpa);
            self.delayed.deinit(self.gpa);
        }

        /// 启动后台自动凑批（对齐 C# `EntityQueue` 的 `TimerX` 定时器）。
        ///
        /// 后台线程按 `policy.period_ms` 醒来，把「近实时桶 + 到期延迟桶」一次性写库；
        /// 会话由 `dal.openSessionForTable(...)` 按 **Model.xml 的表归属连接**新开，
        /// 不共用调用方的 `Session`。
        pub fn start(self: *Self) !void {
            if (self.thread != null) return;
            self.stop_flag = false;
            self.thread = try std.Thread.spawn(.{}, worker, .{self});
        }

        /// 停后台线程并做最后一次 flush（自己开会话）。
        pub fn stop(self: *Self) void {
            self.lock.lock();
            const has_thread = self.thread != null;
            self.stop_flag = true;
            self.lock.unlock();
            if (!has_thread) return;

            if (self.thread) |th| th.join();
            self.thread = null;
            // 最后一次：把剩下的写完（失败只能记错，析构没地方上报）
            self.flushOwned() catch {};
        }

        fn worker(self: *Self) void {
            while (true) {
                const step = if (self.policy.period_ms == 0) 100 else self.policy.period_ms;
                @import("zzig").compat.sleep(step * std.time.ns_per_ms);

                self.lock.lock();
                const should_stop = self.stop_flag;
                self.lock.unlock();
                if (should_stop) return;

                self.flushOwned() catch |err| {
                    std.debug.print(
                        "[zcode] 延迟写队列（后台）：flush 失败（{s}），{d} 条待重试\n",
                        .{ @errorName(err), self.pending() },
                    );
                };
            }
        }

        /// 从两个桶取走待写项，自己开会话写库；失败时**把项放回队列**（不丢数据）。
        fn flushOwned(self: *Self) !void {
            var batch: std.ArrayListUnmanaged(*T) = .empty;
            defer batch.deinit(self.gpa);

            self.lock.lock();
            for (self.items.items) |it| try batch.append(self.gpa, it);
            self.items.clearRetainingCapacity();

            const now = clock.nowMs();
            var keep: std.ArrayListUnmanaged(Delayed) = .empty;
            for (self.delayed.items) |d| {
                if (d.due_ms <= now) {
                    try batch.append(self.gpa, d.e);
                } else {
                    try keep.append(self.gpa, d);
                }
            }
            self.delayed.deinit(self.gpa);
            self.delayed = keep;
            self.lock.unlock();

            if (batch.items.len == 0) {
                self.last_flush_ms = clock.nowMs();
                return;
            }

            var s = self.dal.openSessionForTable(T.meta.table_name) catch |err| {
                self.requeue(batch.items);
                self.error_count += 1;
                self.last_error = err;
                std.debug.print(
                    "[zcode] 延迟写队列：表 {s} 开会话失败（{s}）\n",
                    .{ T.meta.table_name, @errorName(err) },
                );
                return err;
            };
            defer s.deinit();

            self.writeBatch(&s, batch.items) catch |err| {
                self.requeue(batch.items);
                self.error_count += 1;
                self.last_error = err;
                std.debug.print(
                    "[zcode] 延迟写队列（后台）：flush 失败（{s}），保留 {d} 条待重试\n",
                    .{ @errorName(err), batch.items.len },
                );
                return err;
            };
            self.total_flushed += batch.items.len;
            self.flush_count += 1;
            self.last_error = null;
            self.last_flush_ms = clock.nowMs();
        }

        fn requeue(self: *Self, list: []const *T) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.items.insertSlice(self.gpa, 0, list) catch {};
        }

        /// 按 `method` 写一批（新增/更新/upsert/replace/delete）。
        fn writeBatch(self: *Self, s: *Session, list: []const *T) !void {
            switch (self.method) {
                .delete => {
                    for (list) |e| _ = entity.delete(self.dal, e, s) catch |err| return err;
                },
                .insert => _ = try entity.saveBatch(self.dal, T, list, s),
                .upsert => _ = try entity.saveBatchWith(self.dal, T, list, s, .upsert),
                .replace => _ = try entity.saveBatchWith(self.dal, T, list, s, .replace),
                .insert_only => _ = try entity.saveBatchWith(self.dal, T, list, s, .insert),
            }
        }

        /// 入队延迟保存（对应 C# `EntityQueue.Add(entity, msDelay)`）：到期后由后台线程写入。
        pub fn addDelayed(self: *Self, e: *T, ms_delay: u64) !void {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.pendingTotal() >= self.policy.max_entity) {
                std.debug.print("[zcode] 延迟写队列：超过上限 {d}，拒绝入队\n", .{self.policy.max_entity});
                return error.QueueFull;
            }
            try self.delayed.append(self.gpa, .{ .e = e, .due_ms = clock.nowMs() + @as(i64, @intCast(ms_delay)) });
            self.total_added += 1;
        }

        /// 待写总数（近实时桶 + 延迟桶，对齐 C# `EntityQueue._count`）
        pub fn pending(self: *const Self) usize {
            return self.items.items.len + self.delayed.items.len;
        }

        fn pendingTotal(self: *const Self) usize {
            return self.pending();
        }

        /// 入队；达到条数上限时自动 flush。
        pub fn add(self: *Self, s: *Session, e: *T) !void {
            try self.items.append(self.gpa, e);
            self.total_added += 1;

            if (self.policy.max_count > 0 and self.items.items.len >= self.policy.max_count) {
                _ = try self.flush(s);
            }
        }

        /// 入队并在「到期」时 flush（按条数或按时间，任一满足即写）。
        pub fn addTimed(self: *Self, s: *Session, e: *T) !void {
            try self.items.append(self.gpa, e);
            self.total_added += 1;
            if (self.isDue()) _ = try self.flush(s);
        }

        /// 是否已到应该 flush 的时机。
        pub fn isDue(self: *const Self) bool {
            if (self.items.items.len == 0) return false;
            if (self.policy.max_count > 0 and self.items.items.len >= self.policy.max_count) return true;
            if (self.policy.max_latency_ms > 0) {
                const elapsed = clock.nowMs() - self.last_flush_ms;
                if (elapsed >= @as(i64, @intCast(self.policy.max_latency_ms))) return true;
            }
            return false;
        }

        /// 立即写出队列。成功清空；失败**保留队列**并记下原因，便于重试。
        pub fn flush(self: *Self, s: *Session) !entity.SaveBatchReport {
            if (self.items.items.len == 0) {
                self.last_flush_ms = clock.nowMs();
                return .{};
            }

            const report = entity.saveBatch(self.dal, T, self.items.items, s) catch |e| {
                self.error_count += 1;
                self.last_error = e;
                std.debug.print(
                    "[zcode] 延迟写队列：flush 失败（{s}），保留 {d} 条待重试\n",
                    .{ @errorName(e), self.items.items.len },
                );
                return e;
            };

            // 只有真正写成功才清空（saveBatch 内部按新增/更新分别处理，部分成功也按整体回滚语义处理：
            // 不做补偿，保留队列会让已写成功的新增行重复插入——因此这里清空并如实返回报告）
            self.total_flushed += self.items.items.len;
            self.items.clearRetainingCapacity();
            self.flush_count += 1;
            self.last_error = null;
            self.last_flush_ms = clock.nowMs();
            return report;
        }

        /// 丢弃待写数据（明确放弃，不做任何写入）。
        pub fn clearPending(self: *Self) usize {
            const n = self.items.items.len;
            self.items.clearRetainingCapacity();
            return n;
        }

        pub fn describeAlloc(self: *const Self, a: std.mem.Allocator) ![]u8 {
            return std.fmt.allocPrint(
                a,
                "延迟写队列：待写 {d} / 累计入队 {d} / 已写 {d}（{d} 次 flush）/ 失败 {d}",
                .{ self.items.items.len, self.total_added, self.total_flushed, self.flush_count, self.error_count },
            );
        }
    };
}

// ───────────────────────────── 测试 ─────────────────────────────

const sqlite = @import("zzig").sqlite;

const Item = struct {
    Id: i32 = 0,
    Name: []const u8 = "",
    dirty: entity.DirtyBits = 0,

    pub const meta = entity.EntityMeta{
        .name = "QueueItem",
        .table_name = "Queue_Item",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "Name", .data_type = .string },
        },
    };

    pub fn columnValue(self: @This(), i: usize) @import("zzig").db.Value {
        return switch (i) {
            0 => .{ .int = self.Id },
            1 => .{ .text = self.Name },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: @import("zzig").db.Value) !void {
        switch (i) {
            0 => self.Id = v.asI32() orelse 0,
            1 => self.Name = v.asText() orelse "",
            else => return error.ColumnNotFound,
        }
    }
};

fn openQueueDal(a: std.mem.Allocator) !Dal {
    const xml =
        \\<EntityModel><Tables><Table Name="QueueItem" TableName="Queue_Item">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Name" DataType="String" Length="50" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m = try @import("model.zig").EntityModel.parse(a, xml);
    return Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
}

test "延迟写队列：满额自动 flush，数据真的落库" {
    const a = std.testing.allocator;
    var dal = openQueueDal(a) catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer dal.deinit();
    // **必须在 Dal 定址之后**再开会话：会话里的 `db.lib` 指向 `Dal.lib`，
    // 若在辅助函数里先开会话再把 Dal 按值返回，指针会指向已失效的栈副本。
    var s = dal.openSession() catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var q = Queue(Item).init(a, &dal, .{ .max_count = 3, .max_latency_ms = 0 });
    defer q.deinit();

    var items: [4]Item = undefined;
    for (&items, 0..) |*it, i| {
        it.* = .{ .Name = try std.fmt.allocPrint(a, "n-{d}", .{i}) };
        defer a.free(it.Name);
        try q.add(&s, it);
    }

    // 第 3 条触发一次 flush，第 4 条还留在队列
    try std.testing.expectEqual(@as(usize, 1), q.flush_count);
    try std.testing.expectEqual(@as(usize, 1), q.pending());

    const t = try dal.table("QueueItem");
    try std.testing.expectEqual(@as(i64, 3), try t.count(&s, null));

    _ = try q.flush(&s);
    try std.testing.expectEqual(@as(i64, 4), try t.count(&s, null));
    try std.testing.expectEqual(@as(usize, 2), q.flush_count);
    try std.testing.expectEqual(@as(usize, 4), q.total_flushed);
}

test "延迟写队列：按时间到期触发" {
    const a = std.testing.allocator;
    var dal = openQueueDal(a) catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer dal.deinit();
    var s = dal.openSession() catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var q = Queue(Item).init(a, &dal, .{ .max_count = 0, .max_latency_ms = 0 });
    defer q.deinit();

    // max_latency_ms = 0 → 不按时间触发
    var it = Item{ .Name = "x" };
    try q.addTimed(&s, &it);
    try std.testing.expectEqual(@as(usize, 1), q.pending());
    try std.testing.expect(!q.isDue());

    // 改成立即到期
    q.policy.max_latency_ms = 1;
    q.last_flush_ms = clock.nowMs() - 10;
    try std.testing.expect(q.isDue());
    _ = try q.flush(&s);
    try std.testing.expectEqual(@as(usize, 0), q.pending());
}
