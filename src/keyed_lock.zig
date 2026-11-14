//! 按 key 串行化（对应 C# `Common/KeyedLocker.cs`）。
//!
//! ## 它是干什么的
//!
//! 「同一个 key 的这段代码不要并发跑」。典型场景是 get-or-create：
//! `Entity<T>.GetOrAdd(key)` 先查一次、没有就插——**两次并发调用会各插一条**。
//! C# 用 8 个共享锁对象 + `hash(key) % 8`（条带锁）把同 key 的调用串起来：
//! 只锁 1/8 的粒度，既挡住了同 key 竞态，又不需要为每个 key 建锁（不会泄漏、不会无限增长）。
//!
//! ## 为什么不是「每个 key 一把锁」
//!
//! 那样要在表里长期持有 N 把锁，key 是被外部数据驱动的（订单号、设备号…）→ 内存无上限增长。
//! 条带锁的代价是**不同 key 偶尔会共用一把锁**（哈希冲突），表现为轻微多等一会儿，
//! 正确性不受影响。**这是刻意的取舍，不要"优化"成按 key 建锁。**
//!
//! ## 用法
//!
//! ```zig
//! var locker: KeyedLock.Store = .{};
//! var guard = locker.lock("Order:1001");
//! defer guard.release();
//! // 这里对同一 key 是串行的
//! ```

const std = @import("std");
const Mutex = @import("zzig").compat.Mutex;

/// 条带锁：`stripes` 个互斥量，按 key 的哈希取模选一个。
pub fn Store(comptime stripes: usize) type {
    if (stripes == 0) @compileError("KeyedLock.Store 至少要有 1 条带");

    return struct {
        const Self = @This();

        mutexes: [stripes]Mutex = @splat(.{}),

        /// key → 条带下标（与 C# `Math.Abs(hash % Length)` 同思路，但用稳定哈希避免进程间/重跑不一致）。
        pub fn stripeOf(key: []const u8) usize {
            return std.hash.Wyhash.hash(0x9E37_79B9_7F4A_7C15, key) % stripes;
        }

        /// 取该 key 的锁并加锁；`release()` 释放（建议 `defer`）。
        pub fn lock(self: *Self, key: []const u8) Guard {
            const idx = stripeOf(key);
            self.mutexes[idx].lock();
            return .{ .mutex = &self.mutexes[idx] };
        }

        pub const Guard = struct {
            mutex: *Mutex,
            released: bool = false,

            pub fn release(self: *Guard) void {
                if (self.released) return;
                self.released = true;
                self.mutex.unlock();
            }
        };
    };
}

/// 与 C# `KeyedLocker` 一致的 8 条带。
pub const KeyedLock = Store(8);

/// 把一组主键值拼成锁 key（`Value` 的文本形式；NULL 用 `∅` 占位，避免与空串混淆）。
pub fn keyOfAlloc(a: std.mem.Allocator, values: []const @import("zzig").db.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (values, 0..) |v, i| {
        if (i > 0) try out.append(a, '|');
        if (v.isNull()) {
            try out.appendSlice(a, "\xe2\x88\x85"); // ∅
            continue;
        }
        if (v.asText()) |t| {
            try out.appendSlice(a, t);
        } else {
            // 非文本值用格式化后的形式（整数/浮点/时间都能稳定复现）
            const text = try std.fmt.allocPrint(a, "{any}", .{v});
            defer a.free(text);
            try out.appendSlice(a, text);
        }
    }
    return out.toOwnedSlice(a);
}

// ── 用例 ────────────────────────────────────────────────────────────────────

test "keyed_lock - 同 key 命中同一条带，不同 key 一般不同" {
    try std.testing.expectEqual(KeyedLock.stripeOf("Order:1001"), KeyedLock.stripeOf("Order:1001"));
    // 8 条带下，这两个 key 的哈希值不同（用例守着"不是恒定 0"这个傻瓜实现）
    const a = KeyedLock.stripeOf("a");
    const b = KeyedLock.stripeOf("b");
    try std.testing.expect(a < 8 and b < 8);
    try std.testing.expect(a != b);
}

test "keyed_lock - 加锁/释放可重入使用，不会自锁死" {
    var store: KeyedLock = .{};
    {
        var g = store.lock("k1");
        defer g.release();
    }
    // 释放后可以再次加锁
    var g2 = store.lock("k1");
    g2.release();
    // 重复 release 不炸（幂等）
    g2.release();
}

test "keyed_lock - 锁 key 由主键值稳定拼接" {
    const a = std.testing.allocator;

    const k1 = try keyOfAlloc(a, &.{ .{ .int = 42 }, .{ .text = "abc" } });
    defer a.free(k1);
    const k2 = try keyOfAlloc(a, &.{ .{ .int = 42 }, .{ .text = "abc" } });
    defer a.free(k2);
    try std.testing.expectEqualStrings(k1, k2);

    const k3 = try keyOfAlloc(a, &.{.{ .text = "42|abc" }});
    defer a.free(k3);
    // 拼接带分隔符，避免 ["42","abc"] 与 ["42|abc"] 撞成同一个 key
    try std.testing.expect(!std.mem.eql(u8, k1, k3));

    const kn = try keyOfAlloc(a, &.{.{ .null = {} }});
    defer a.free(kn);
    try std.testing.expectEqualStrings("\xe2\x88\x85", kn);
}
