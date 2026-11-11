//! 整表实体缓存（对应 C# `Meta.Cache` / Rust `Pek.RCode/src/cache.rs` 的 Blocking 子集）。
//!
//! 语义：
//! - **首次访问 / TTL 到期 → 同步整表重载**（Blocking 一致性，不用后台刷新，读到的永远是最新快照）；
//! - `get` 按主键 O(1) 命中（单主键 `i64`；复合主键显式 `error.Unsupported`）；
//! - **写后自动失效**：`TableRef` 的 insert/update/delete/批量写都会通知 `Dal` 使该表缓存失效；
//! - `ttl_seconds = 0` 表示不过期（只靠写失效 / 手动 `invalidate`）。
//!
//! 内存约定：缓存持有实体与其字符串（arena）；`reload`/`invalidate` 后**旧的实体切片失效**，
//! 调用方不要跨失效点持有 `get`/`all` 返回的切片。

const std = @import("std");
const dal_mod = @import("dal.zig");
const Dal = dal_mod.Dal;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const entity = @import("entity.zig");
const Query = @import("query.zig").Query;
const DateTime = @import("zzig").DateTime;

pub fn Cache(comptime T: type) type {
    return struct {
        const Self = @This();

        dal: *Dal,
        gpa: std.mem.Allocator,
        /// 过期秒数（0 = 不过期）
        ttl_seconds: i64 = 60,
        /// 上次装载时间（Unix 秒；0 = 未装载）
        loaded_at: i64 = 0,
        items: []const T = &.{},
        index: std.AutoHashMapUnmanaged(i64, usize) = .empty,
        arena: std.heap.ArenaAllocator,
        registered: bool = false,

        pub fn init(dal: *Dal, ttl_seconds: i64) Self {
            return .{
                .dal = dal,
                .gpa = dal.gpa,
                .ttl_seconds = ttl_seconds,
                .arena = std.heap.ArenaAllocator.init(dal.gpa),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.registered) self.dal.unregisterCache(@ptrCast(self));
            self.index.deinit(self.gpa);
            self.arena.deinit();
        }

        /// 首次使用时注册（此时结构体已位于最终地址，指针稳定）。
        fn ensureRegistered(self: *Self) !void {
            if (self.registered) return;
            try self.dal.registerCache(.{
                .table_name = T.meta.table_name,
                .ctx = @ptrCast(self),
                .invalidate = invalidateHook,
            });
            self.registered = true;
        }

        /// 使缓存失效（下次访问重新整表装载）。
        pub fn invalidate(self: *Self) void {
            self.loaded_at = 0;
        }

        fn invalidateHook(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.invalidate();
        }

        fn isExpired(self: *const Self) bool {
            if (self.loaded_at == 0) return true;
            if (self.ttl_seconds <= 0) return false;
            return DateTime.nowUnix() - self.loaded_at >= self.ttl_seconds;
        }

        fn ensureLoaded(self: *Self, s: *Session) !void {
            if (!self.isExpired()) return;
            try self.ensureRegistered();
            try self.reload(s);
        }

        /// 整表重载（会释放上一次装载的实体与其字符串）。
        pub fn reload(self: *Self, s: *Session) !void {
            var q = Query.init(self.gpa);
            defer q.deinit();

            // 先清空，装载失败时状态为「未加载」，下次访问会重试
            _ = self.arena.reset(.retain_capacity);
            self.index.clearRetainingCapacity();
            self.items = &.{};
            self.loaded_at = 0;

            const rows = try entity.queryRows(self.dal, T, s, &q);

            const pk_index = primaryKeyIndex(T.meta) orelse return error.Unsupported;
            for (rows, 0..) |row, i| {
                const pk = row.columnValue(pk_index).asI64() orelse continue;
                try self.index.put(self.gpa, pk, i);
            }
            self.items = rows;
            self.loaded_at = DateTime.nowUnix();
        }

        /// 按主键取（未加载/过期会先整表装载）。
        pub fn get(self: *Self, s: *Session, pk: i64) !?T {
            try self.ensureLoaded(s);
            const i = self.index.get(pk) orelse return null;
            return self.items[i];
        }

        /// 全部行（未加载/过期会先整表装载）。
        pub fn all(self: *Self, s: *Session) ![]const T {
            try self.ensureLoaded(s);
            return self.items;
        }

        pub fn count(self: *Self, s: *Session) !usize {
            try self.ensureLoaded(s);
            return self.items.len;
        }

        fn primaryKeyIndex(meta: entity.EntityMeta) ?usize {
            var found: ?usize = null;
            for (meta.fields, 0..) |f, i| {
                if (!f.primary_key) continue;
                if (found != null) return null; // 复合主键：本缓存不支持
                found = i;
            }
            return found;
        }
    };
}
