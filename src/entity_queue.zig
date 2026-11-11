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

pub const Policy = struct {
    /// 队列长度达到该值即自动 flush（0 = 不按条数触发）
    max_count: usize = 100,
    /// 距上次 flush 超过该毫秒数即自动 flush（0 = 不按时间触发）
    max_latency_ms: u64 = 1_000,
};

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        dal: *Dal,
        policy: Policy,
        items: std.ArrayListUnmanaged(*T) = .empty,
        last_flush_ms: i64,

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
            if (self.items.items.len > 0) {
                std.debug.print(
                    "[zcode] 延迟写队列：析构时仍有 {d} 条未写入（请确认是否漏了 flush）\n",
                    .{self.items.items.len},
                );
            }
            self.items.deinit(self.gpa);
        }

        pub fn pending(self: *const Self) usize {
            return self.items.items.len;
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
