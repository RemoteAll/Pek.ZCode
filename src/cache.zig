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
        /// 模型 `MaxCacheCount`：`>0` 时整表装载超过它就**不缓存**
        max_rows: usize = 0,
        /// 已判定「禁用/太大」：后续 `get`/`all`/`count` 直接查库，不再尝试整表装载
        disabled: bool = false,
        /// 上次装载时间（Unix 秒；0 = 未装载）
        loaded_at: i64 = 0,
        items: []const T = &.{},
        index: std.AutoHashMapUnmanaged(i64, usize) = .empty,
        arena: std.heap.ArenaAllocator,
        registered: bool = false,

        pub fn init(dal: *Dal, ttl_seconds: i64) Self {
            // 内存保护：`MaxCacheCount <= 0`（含时序列强制置 0）直接禁用整表缓存——
            // 大表整表装载到内存的代价远大于收益，C# `Meta.Cache` 也是这么做的。
            const max_rows: usize = blk: {
                const t = dal.model.table(T.meta.table_name) orelse break :blk 0;
                break :blk if (t.max_cache_count > 0) @intCast(t.max_cache_count) else 0;
            };

            var self = Self{
                .dal = dal,
                .gpa = dal.gpa,
                .ttl_seconds = ttl_seconds,
                .max_rows = max_rows,
                .arena = std.heap.ArenaAllocator.init(dal.gpa),
            };
            if (max_rows == 0) self.disabled = true;
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.registered) self.dal.unregisterCache(@ptrCast(self));
            self.index.deinit(self.gpa);
            self.arena.deinit();
        }

        /// 首次使用时注册（此时结构体已位于最终地址，指针稳定）。
        fn ensureRegistered(self: *Self) !void {
            if (self.registered) return;
            // 注册用**物理表名**：`TableRef` 的写通知一律按物理名发出，
            // 用实体名注册会导致「实体名 ≠ 物理名」的表写完之后缓存永不失效（实测踩过）。
            const phys = if (self.dal.model.table(T.meta.table_name)) |t| t.effectiveTableName() else T.meta.table_name;
            try self.dal.registerCache(.{
                .table_name = phys,
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
            if (self.disabled) return;
            if (!self.isExpired()) return;
            try self.ensureRegistered();
            try self.reload(s);
        }

        /// 整表重载（会释放上一次装载的实体与其字符串）。
        pub fn reload(self: *Self, s: *Session) !void {
            if (self.disabled) return;

            var q = Query.init(self.gpa);
            defer q.deinit();

            // 先清空，装载失败时状态为「未加载」，下次访问会重试
            _ = self.arena.reset(.retain_capacity);
            self.index.clearRetainingCapacity();
            self.items = &.{};
            self.loaded_at = 0;

            const rows = try entity.queryRows(self.dal, T, s, &q);

            // 超过模型上限：放弃整表缓存（内存保护），之后直接查库
            if (self.max_rows == 0 or rows.len > self.max_rows) {
                self.disabled = true;
                _ = self.arena.reset(.retain_capacity);
                self.index.clearRetainingCapacity();
                self.items = &.{};
                return;
            }

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
            if (!self.disabled) try self.ensureLoaded(s);
            // `reload` 可能因为行数超限而刚把缓存禁用，这里必须再判一次
            if (self.disabled) return entity.findByPk(self.dal, T, s, &.{.{ .int = pk }});
            const i = self.index.get(pk) orelse return null;
            return self.items[i];
        }

        /// 全部行（未加载/过期会先整表装载）。
        pub fn all(self: *Self, s: *Session) ![]const T {
            if (!self.disabled) try self.ensureLoaded(s);
            if (self.disabled) {
                var q = Query.init(self.gpa);
                defer q.deinit();
                return entity.queryRows(self.dal, T, s, &q);
            }
            return self.items;
        }

        pub fn count(self: *Self, s: *Session) !usize {
            if (!self.disabled) try self.ensureLoaded(s);
            if (self.disabled) {
                const n = try entity.count(self.dal, T, s, null);
                return @intCast(n);
            }
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

/// 单对象缓存（对应 C# `Meta.SingleCache` / Rust `SingleCache`）：
/// 按主键缓存单行，TTL 到期或该表被写入时失效，下次读取回库。
///
/// 与整表缓存的分工：整表缓存适合**小表全量**（≤1000 行）；单对象缓存适合**大表按主键取**，
/// 只缓存访问过的行。内存都是每个条目一个 arena，`invalidate` 后旧值切片失效。
pub fn SingleCache(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            value: T,
            loaded_at: i64,
            arena: std.heap.ArenaAllocator,
        };

        dal: *Dal,
        gpa: std.mem.Allocator,
        ttl_seconds: i64 = 60,
        entries: std.AutoHashMapUnmanaged(i64, Entry) = .empty,
        registered: bool = false,

        pub fn init(dal: *Dal, ttl_seconds: i64) Self {
            return .{ .dal = dal, .gpa = dal.gpa, .ttl_seconds = ttl_seconds };
        }

        pub fn deinit(self: *Self) void {
            if (self.registered) self.dal.unregisterCache(@ptrCast(self));
            var it = self.entries.iterator();
            while (it.next()) |kv| kv.value_ptr.arena.deinit();
            self.entries.deinit(self.gpa);
        }

        /// 使单个主键失效。
        pub fn invalidate(self: *Self, pk: i64) void {
            if (self.entries.fetchRemove(pk)) |kv| {
                var entry = kv.value;
                entry.arena.deinit();
            }
        }

        /// 使全部条目失效。
        pub fn invalidateAll(self: *Self) void {
            var it = self.entries.iterator();
            while (it.next()) |kv| kv.value_ptr.arena.deinit();
            self.entries.clearRetainingCapacity();
        }

        fn invalidateHook(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.invalidateAll();
        }

        fn ensureRegistered(self: *Self) !void {
            if (self.registered) return;
            try self.dal.registerCache(.{
                .table_name = T.meta.table_name,
                .ctx = @ptrCast(self),
                .invalidate = invalidateHook,
            });
            self.registered = true;
        }

        fn isExpired(self: *const Self, entry: *const Entry) bool {
            if (entry.loaded_at == 0) return true;
            if (self.ttl_seconds <= 0) return false;
            return DateTime.nowUnix() - entry.loaded_at >= self.ttl_seconds;
        }

        /// 按主键取（未命中/过期回库并缓存；不存在返回 null）。
        pub fn get(self: *Self, s: *Session, pk: i64) !?T {
            try self.ensureRegistered();

            if (self.entries.getPtr(pk)) |entry| {
                if (!self.isExpired(entry)) return entry.value;
                self.invalidate(pk);
            }

            const row = (try entity.findByPk(self.dal, T, s, &.{.{ .int = pk }})) orelse return null;

            // 深拷贝到条目自己的 arena，脱离会话结果集生命周期
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer arena.deinit();
            const owned = try cloneInto(arena.allocator(), row);

            try self.entries.put(self.gpa, pk, .{
                .value = owned,
                .loaded_at = DateTime.nowUnix(),
                .arena = arena,
            });
            return self.entries.get(pk).?.value;
        }

        /// 已缓存条目数（含已过期未清理的）。
        pub fn cachedCount(self: *const Self) usize {
            return self.entries.count();
        }

        /// 把实体里借用的字符串/二进制复制到持久 arena（其余值类型直接拷贝）。
        fn cloneInto(arena: std.mem.Allocator, e: T) !T {
            var out = e;
            out.dirty = 0;
            for (T.meta.fields, 0..) |_, i| {
                switch (e.columnValue(i)) {
                    .text => |t| {
                        const owned = try arena.dupe(u8, t);
                        try out.setColumnValue(i, .{ .text = owned });
                    },
                    .blob => |b| {
                        const owned = try arena.dupe(u8, b);
                        try out.setColumnValue(i, .{ .blob = owned });
                    },
                    else => {},
                }
            }
            return out;
        }
    };
}
