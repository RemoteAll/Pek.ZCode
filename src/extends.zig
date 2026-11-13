//! 实体扩展属性缓存（对应 C# `EntityExtend` / `entity.Extends`）。
//!
//! C# 的用法是「按外键惰性加载 + 短期缓存」：
//! ```csharp
//! public Role? Role => Extends.Get(nameof(Role), _ => Role.FindByID(RoleID));
//! ```
//! 默认 10 秒过期（`Setting.ExtendExpire`），同一实体反复读扩展属性只查一次库。
//!
//! 本仓**不把缓存挂进实体结构体**：实体是值类型，到处拷贝会把堆和所有权搞乱。
//! 改成独立对象 `Extends(V)`——需要扩展属性的实体自己持有一个，随实体一起传。
//!
//! 与 `navigation.zig` 的分工：
//! - 批量场景（N 个实体要同一关联）→ 用 `navigation`（一次 IN 查询，消除 N+1）；
//! - 单个实体反复取同一个关联（如界面反复渲染）→ 用本模块的 TTL 缓存。

const std = @import("std");
const clock = @import("clock.zig");

pub fn Extends(comptime V: type) type {
    return struct {
        const Self = @This();

        /// 加载器：`out` 由实现填充；返回 `false` 表示「确实没有」，会缓存这个「没有」。
        pub const Loader = *const fn (ctx: ?*anyopaque, key: []const u8, out: *V) anyerror!bool;

        gpa: std.mem.Allocator,
        /// 过期毫秒（<= 0 表示永不过期）
        expire_ms: i64 = 10_000,
        /// 释放缓存值（含深拷贝字符串时必须给，否则过期/clear 会泄漏）
        free_fn: ?*const fn (gpa: std.mem.Allocator, value: *V) void = null,

        map: std.StringHashMapUnmanaged(Entry) = .empty,
        hits: usize = 0,
        misses: usize = 0,

        const Entry = struct {
            value: ?V,
            expire_at: i64,
        };

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        /// 用「秒」设过期（对齐 C# `Setting.ExtendExpire` 的单位）。
        pub fn initSeconds(gpa: std.mem.Allocator, seconds: i32) Self {
            return .{ .gpa = gpa, .expire_ms = @as(i64, seconds) * 1000 };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.map.deinit(self.gpa);
        }

        fn dropValue(self: *Self, v: ?V) void {
            if (v) |value| {
                if (self.free_fn) |f| {
                    var tmp = value;
                    f(self.gpa, &tmp);
                }
            }
        }

        /// 清空所有缓存（写操作后调它，等价于 C# 的缓存失效）。
        pub fn clear(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |kv| {
                self.dropValue(kv.value_ptr.value);
                self.gpa.free(kv.key_ptr.*);
            }
            self.map.clearRetainingCapacity();
        }

        /// 让某个键失效。
        pub fn invalidate(self: *Self, key: []const u8) void {
            if (self.map.fetchRemove(key)) |kv| {
                self.dropValue(kv.value.value);
                self.gpa.free(kv.key);
            }
        }

        /// 取扩展值（对应 C# `Extends.Get(key, loader)`）：
        /// 命中未过期直接返回；否则调 `loader` 加载并缓存（含「没有」这个结果）。
        ///
        /// 返回的是**副本**：`V` 里的字符串与缓存共享，调用方不要改内容；
        /// 需要长期持有请自行深拷贝。
        pub fn get(
            self: *Self,
            key: []const u8,
            ctx: ?*anyopaque,
            loader: Loader,
        ) !?V {
            const now = clock.nowMs();
            if (self.map.getPtr(key)) |e| {
                if (self.expire_ms <= 0 or now < e.expire_at) {
                    self.hits += 1;
                    return e.value;
                }
                // 过期：先释放旧值，再重新加载
                self.dropValue(e.value);
                e.* = .{ .value = null, .expire_at = now + self.expire_ms };
            }

            self.misses += 1;
            var out: V = undefined;
            const found = loader(ctx, key, &out) catch |err| {
                // 加载失败不缓存，交给调用方决定重试
                return err;
            };

            const entry = Entry{
                .value = if (found) out else null,
                .expire_at = if (self.expire_ms <= 0) 0 else now + self.expire_ms,
            };

            if (self.map.getPtr(key)) |e| {
                e.* = entry;
            } else {
                const k = try self.gpa.dupe(u8, key);
                errdefer self.gpa.free(k);
                try self.map.put(self.gpa, k, entry);
            }
            return if (found) out else null;
        }

        /// 命中率统计（观察缓存是否真的生效）。
        pub fn stats(self: *const Self) struct { hits: usize, misses: usize, size: usize } {
            return .{ .hits = self.hits, .misses = self.misses, .size = self.map.count() };
        }
    };
}

// ── 用例 ────────────────────────────────────────────────────

const testing = std.testing;

const Role = struct { ID: i32 = 0, Name: []const u8 = "" };

const RoleLoader = struct {
    calls: usize = 0,

    fn load(ctx: ?*anyopaque, key: []const u8, out: *Role) anyerror!bool {
        const self: *RoleLoader = @ptrCast(@alignCast(ctx orelse return false));
        self.calls += 1;
        const id = std.fmt.parseInt(i32, key, 10) catch return false;
        if (id == 404) return false;
        out.* = .{ .ID = id, .Name = "role" };
        return true;
    }
};

test "Extends：命中不重复加载；没有也缓存；过期后重载" {
    var ext = Extends(Role).initSeconds(testing.allocator, 10);
    defer ext.deinit();

    var loader = RoleLoader{};

    const r1 = try ext.get("1", @ptrCast(&loader), RoleLoader.load);
    try testing.expect(r1 != null);
    try testing.expectEqual(@as(i32, 1), r1.?.ID);
    try testing.expectEqual(@as(usize, 1), loader.calls);

    // 第二次命中缓存
    const r2 = try ext.get("1", @ptrCast(&loader), RoleLoader.load);
    try testing.expectEqual(@as(i32, 1), r2.?.ID);
    try testing.expectEqual(@as(usize, 1), loader.calls);

    // 「没有」也缓存：只加载一次
    const none1 = try ext.get("404", @ptrCast(&loader), RoleLoader.load);
    try testing.expect(none1 == null);
    const none2 = try ext.get("404", @ptrCast(&loader), RoleLoader.load);
    try testing.expect(none2 == null);
    try testing.expectEqual(@as(usize, 2), loader.calls);

    const st = ext.stats();
    try testing.expectEqual(@as(usize, 2), st.hits);
    try testing.expectEqual(@as(usize, 2), st.misses);
    try testing.expectEqual(@as(usize, 2), st.size);

    // 失效后重新加载
    ext.invalidate("1");
    _ = try ext.get("1", @ptrCast(&loader), RoleLoader.load);
    try testing.expectEqual(@as(usize, 3), loader.calls);
}

test "Extends：expire_ms = 0 表示永不过期" {
    var ext = Extends(Role).init(testing.allocator);
    defer ext.deinit();
    ext.expire_ms = 0;

    var loader = RoleLoader{};
    _ = try ext.get("2", @ptrCast(&loader), RoleLoader.load);
    _ = try ext.get("2", @ptrCast(&loader), RoleLoader.load);
    try testing.expectEqual(@as(usize, 1), loader.calls);
}
