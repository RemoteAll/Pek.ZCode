//! 两级缓存（对齐 DH.NCode `Cache/` 目录）：
//!
//! | C# | 本模块 | 适用 |
//! |---|---|---|
//! | `EntityCache<T>`（`Meta.Cache`，整表） | `Cache(T)` | 小表全量常驻，扛高频条件查询 |
//! | `SingleEntityCache<TKey,T>`（`Meta.SingleCache`） | `SingleCache(T)` | 大表按主键取，只缓存访问过的行 |
//! | `FieldCache<T>` | `fieldcache.zig` | 分组 Top N 统计 |
//! | `DataCache` / `CacheInvalidator` / `LazyConsumer` / `DbCache` | `dbcache.zig` | 行数缓存、分布式版本号 |
//!
//! 口径（性能与资源是硬约束：面向百万~亿级设备、多系统共用表、分库分表）：
//!
//! - **绝不无条件整表装载**：`MaxCacheCount` 为 0（含时序列强制置 0）时**不缓存**；`>0` 时装载带
//!   `LIMIT max_rows+1`，一次往返即可判定超限 —— 内存上限恒为 `max_rows` 行，**与表有多大无关**。
//!   超限后进入静默期（`over_limit_seconds`），期内直接查库，不重复探测。
//! - **读路径不枷锁**：快照不可变，用原子指针发布；命中 = 1 次原子 load + 哈希查找。
//! - **单飞装载**：同一时刻只有一个线程装载，其余线程**返回旧快照**（stale-while-revalidate），
//!   避免过期瞬间所有线程串行阻塞；不占后台线程、不占额外连接（零常驻资源）。
//! - **写后失效分两档**：整表缓存只能整体失效；单对象缓存按**主键精确失效**（写一行只丢那一行）。
//! - **作用域 = 连接名 + 物理表名**：分库同名表、分表不同物理表互不干扰。
//! - **手动清缓存**：`invalidate()`（下次读刷新，多线程时可返回旧值）/ `invalidateForced()`（阻塞到新值）。
//!
//! 内存约定：快照持有实体与其字符串（arena），**字符串已深拷贝**，不随会话结果集释放；
//! 快照替换后上一代延迟一代释放（`retired`），但调用方仍不应跨失效点长期持有返回的切片。

const std = @import("std");
const dal_mod = @import("dal.zig");
const Dal = dal_mod.Dal;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const entity = @import("entity.zig");
const Query = @import("query.zig").Query;
const DateTime = @import("zzig").DateTime;
const Mutex = @import("zzig").compat.Mutex;

/// 把实体里借用的字符串/二进制复制到持久 arena（其余值类型直接拷贝）。
fn cloneEntity(comptime T: type, arena: std.mem.Allocator, e: T) !T {
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

/// 缓存统计（原子累加，零锁）。
pub const CacheStats = struct {
    total: usize = 0,
    success: usize = 0,
    loads: usize = 0,
    over_limit: usize = 0,
    evicted: usize = 0,

    /// 命中率（0~1）。
    pub fn hitRate(self: CacheStats) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.success)) / @as(f64, @floatFromInt(self.total));
    }

    /// 一行摘要，便于面板/日志直接输出。
    pub fn formatBuf(self: CacheStats, out: []u8) ![]const u8 {
        return std.fmt.bufPrint(out, "命中 {d}/{d}（{d:.1}%），装载 {d} 次，超限 {d} 次，淘汰 {d} 条", .{
            self.success,
            self.total,
            self.hitRate() * 100.0,
            self.loads,
            self.over_limit,
            self.evicted,
        });
    }
};

pub fn Cache(comptime T: type) type {
    return struct {
        const Self = @This();

        /// 一代**不可变**快照：读路径无锁访问，只能整体替换。
        pub const Snapshot = struct {
            arena: std.heap.ArenaAllocator,
            items: []T = &.{},
            index: std.AutoHashMapUnmanaged(i64, usize) = .empty,
            loaded_at: i64 = 0,
        };

        dal: *Dal,
        gpa: std.mem.Allocator,
        /// 缓存作用域：连接名（空 = 随表归属/主连接）。分库场景下同名表靠它区分。
        conn_name: []const u8 = "",
        /// 过期秒数（0 = 不过期）
        ttl_seconds: i64 = 60,
        /// 模型 `MaxCacheCount`：0 = **不缓存**；>0 = 最多缓存这么多行
        max_rows: usize = 0,
        /// 探测到超限后的静默期（秒）：期内直接查库，不重复探测
        over_limit_seconds: i64 = 60,
        over_limit_until: i64 = 0,

        /// 当前快照（原子发布，读路径不加锁）
        snap: std.atomic.Value(?*Snapshot) = std.atomic.Value(?*Snapshot).init(null),
        /// 上一代快照：延迟一代释放，避免读线程刚拿到指针就被 free
        retired: ?*Snapshot = null,
        /// 装载串行化（只在装载时加锁，命中路径不加）
        load_mutex: Mutex = .{},
        /// 单飞标志：抢到的线程负责装载，其余直接返回旧快照
        loading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// 已被写/手动失效（下次读必须刷新）
        stale: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// 强制失效：下次读必须**等到新快照**，不能返回旧值
        forced: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        total: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        success: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        load_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        over_limit_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        registered: bool = false,

        pub fn init(dal: *Dal, ttl_seconds: i64) Self {
            return initConn(dal, "", ttl_seconds);
        }

        /// 按连接名初始化（分库：同一张表在不同库里各有一份缓存）。
        pub fn initConn(dal: *Dal, conn_name: []const u8, ttl_seconds: i64) Self {
            // `MaxCacheCount <= 0`（含时序/时序分表列强制置 0）表示模型层明确「不缓存」
            const max_rows: usize = blk: {
                const t = dal.model.table(T.meta.table_name) orelse break :blk 0;
                break :blk if (t.max_cache_count > 0) @intCast(t.max_cache_count) else 0;
            };
            return .{
                .dal = dal,
                .gpa = dal.gpa,
                .conn_name = conn_name,
                .ttl_seconds = ttl_seconds,
                .max_rows = max_rows,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.registered) self.dal.unregisterCache(@ptrCast(self));
            if (self.snap.swap(null, .monotonic)) |snap| self.destroySnapshot(snap);
            if (self.retired) |r| self.destroySnapshot(r);
            self.retired = null;
        }

        /// 当前快照行数（0 = 没有快照）。
        pub fn cachedRows(self: *const Self) usize {
            const snap = self.snap.load(.acquire) orelse return 0;
            return snap.items.len;
        }

        fn destroySnapshot(self: *Self, snap: *Snapshot) void {
            snap.arena.deinit();
            self.gpa.destroy(snap);
        }

        /// 首次使用时注册（此时结构体已位于最终地址，指针稳定）。
        fn ensureRegistered(self: *Self) !void {
            if (self.registered) return;
            // 注册用**物理表名 + 连接名**：`TableRef` 的写通知按这两者发出，
            // 用实体名注册会导致「实体名 ≠ 物理名」的表写完之后缓存永不失效（实测踩过）；
            // 缺连接名会让分库同名表互相串缓存。
            const phys = if (self.dal.model.table(T.meta.table_name)) |t| t.effectiveTableName() else T.meta.table_name;
            const conn = if (self.conn_name.len > 0)
                self.conn_name
            else
                self.dal.tableConnName(T.meta.table_name) catch self.dal.connName();
            try self.dal.registerCache(.{
                .table_name = phys,
                .conn_name = conn,
                .ctx = @ptrCast(self),
                .invalidate = invalidateHook,
            });
            self.registered = true;
        }

        /// 手动清缓存（非强制）：下次读刷新；多线程下其余线程可能先拿到旧值。
        pub fn invalidate(self: *Self) void {
            self.stale.store(true, .release);
        }

        /// 手动清缓存（强制）：下次读**阻塞到新快照**，保证读到最新。
        pub fn invalidateForced(self: *Self) void {
            self.forced.store(true, .release);
            self.stale.store(true, .release);
        }

        fn invalidateHook(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.invalidate();
        }

        fn isStale(self: *const Self, snap: *const Snapshot) bool {
            if (self.stale.load(.acquire)) return true;
            if (self.ttl_seconds <= 0) return false;
            return DateTime.nowUnix() - snap.loaded_at >= self.ttl_seconds;
        }

        /// 当前是否真的在用缓存（已装且未超限）。
        pub fn usingCache(self: *const Self) bool {
            if (self.max_rows == 0) return false;
            if (self.over_limit_until > DateTime.nowUnix()) return false;
            return self.snap.load(.acquire) != null;
        }

        pub fn stats(self: *const Self) CacheStats {
            return .{
                .total = self.total.load(.monotonic),
                .success = self.success.load(.monotonic),
                .loads = self.load_count.load(.monotonic),
                .over_limit = self.over_limit_count.load(.monotonic),
            };
        }

        /// 取一代可用快照；`null` 表示不应走缓存（模型禁缓存 / 超限静默期 / 装载失败）。
        fn snapshotForRead(self: *Self, s: *Session) !?*Snapshot {
            if (self.max_rows == 0) return null;
            if (self.over_limit_until > DateTime.nowUnix()) return null;

            if (self.snap.load(.acquire)) |snap| {
                if (!self.isStale(snap)) return snap;
                // 强制失效：必须等到新快照
                if (self.forced.load(.acquire)) return self.reloadSerial(s);
                // 过期：抢到单飞权就刷新，抢不到先返回旧值（stale-while-revalidate）
                if (self.loading.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
                    defer self.loading.store(false, .release);
                    return self.reloadSerial(s) catch snap;
                }
                return snap;
            }
            // 首次访问：必须等装载完成
            return self.reloadSerial(s);
        }

        /// 串行装载（双检：等锁期间别人可能已经装好了）。
        fn reloadSerial(self: *Self, s: *Session) !?*Snapshot {
            self.load_mutex.lock();
            defer self.load_mutex.unlock();

            if (self.snap.load(.acquire)) |snap| {
                if (!self.isStale(snap)) return snap;
            }
            return self.reloadInner(s);
        }

        /// 整表重载（新快照构建完成后原子替换；旧快照延迟一代释放）。
        pub fn reload(self: *Self, s: *Session) !?*Snapshot {
            return self.reloadSerial(s);
        }

        fn reloadInner(self: *Self, s: *Session) !?*Snapshot {
            if (self.max_rows == 0) return null;
            try self.ensureRegistered();

            const snap = try self.gpa.create(Snapshot);
            snap.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa) };
            errdefer self.destroySnapshot(snap);
            const a = snap.arena.allocator();

            var q = Query.init(self.gpa);
            defer q.deinit();
            // 关键：不拉全表。最多拿 max_rows+1 行，一次往返就能定「能不能缓存」，
            // 内存上限与表大小无关（亿级表也不会把整表拉进采样）。
            q.limit = self.max_rows + 1;

            const rows = try entity.queryRows(self.dal, T, s, &q);

            if (rows.len > self.max_rows) {
                // 超限：一行都不留，进入静默期
                self.over_limit_until = DateTime.nowUnix() + self.over_limit_seconds;
                _ = self.over_limit_count.fetchAdd(1, .monotonic);
                self.destroySnapshot(snap);
                return null;
            }

            const pk_index = primaryKeyIndex(T.meta) orelse return error.Unsupported;
            const items = try a.alloc(T, rows.len);
            for (rows, 0..) |row, i| {
                // 深拷贝：会话结果集随时可能被下一次查询重置，不能直接引用
                items[i] = try cloneEntity(T, a, row);
                const pk = row.columnValue(pk_index).asI64() orelse continue;
                try snap.index.put(a, pk, i);
            }
            snap.items = items;
            snap.loaded_at = DateTime.nowUnix();

            self.stale.store(false, .release);
            self.forced.store(false, .release);
            _ = self.load_count.fetchAdd(1, .monotonic);

            // 发布新快照；旧快照延迟一代释放（读线程可能还拿着它的切片）
            const old = self.snap.swap(snap, .acq_rel);
            if (self.retired) |r| self.destroySnapshot(r);
            self.retired = old;
            return snap;
        }

        /// 按主键取（命中 O(1)；未命中返回 null，不缓存空值）。
        pub fn get(self: *Self, s: *Session, pk: i64) !?T {
            _ = self.total.fetchAdd(1, .monotonic);
            if (try self.snapshotForRead(s)) |snap| {
                if (snap.index.get(pk)) |i| {
                    _ = self.success.fetchAdd(1, .monotonic);
                    return snap.items[i];
                }
                return null;
            }
            return entity.findByPk(self.dal, T, s, &.{.{ .int = pk }});
        }

        /// 全部行（不走缓存时返回会话内存，不跨查询持有）。
        pub fn all(self: *Self, s: *Session) ![]const T {
            _ = self.total.fetchAdd(1, .monotonic);
            if (try self.snapshotForRead(s)) |snap| {
                _ = self.success.fetchAdd(1, .monotonic);
                return snap.items;
            }
            var q = Query.init(self.gpa);
            defer q.deinit();
            return entity.queryRows(self.dal, T, s, &q);
        }

        pub fn count(self: *Self, s: *Session) !usize {
            _ = self.total.fetchAdd(1, .monotonic);
            if (try self.snapshotForRead(s)) |snap| {
                _ = self.success.fetchAdd(1, .monotonic);
                return snap.items.len;
            }
            const n = try entity.count(self.dal, T, s, null);
            return @intCast(n);
        }

        /// 谓词查一行（小表常驻缓存时，高频条件查询不再打到库）。
        pub fn find(self: *Self, s: *Session, pred: *const fn (*const T) bool) !?T {
            const list = try self.all(s);
            for (list) |*e| {
                if (pred(e)) return e.*;
            }
            return null;
        }

        /// 谓词查多行：返回的切片数组由 `gpa` 拥有（实体内部字符串仍借用快照）。
        pub fn findAll(self: *Self, s: *Session, gpa: std.mem.Allocator, pred: *const fn (*const T) bool) ![]T {
            const list = try self.all(s);
            var out: std.ArrayList(T) = .empty;
            errdefer out.deinit(gpa);
            for (list) |*e| {
                if (pred(e)) try out.append(gpa, e.*);
            }
            return out.toOwnedSlice(gpa);
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
/// 与整表缓存的分工：整表缓存适合**小表全量**（≤`MaxCacheCount` 行，缺省 1000）；
/// 单对象缓存适合**大表按主键取**，只缓存访问过的行（缺省上限 10000 条，超出按最久未访问淘汰）。
/// 写入时按**主键精确失效**（写一行只丢那一行），不会把整张表清空。
pub fn SingleCache(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            value: T,
            loaded_at: i64,
            /// 最近访问序号（单调递增）：淘汰时取最小的
            visit_seq: u64 = 0,
            arena: std.heap.ArenaAllocator,
        };

        const KeySeq = struct { seq: u64, key: i64 };

        dal: *Dal,
        gpa: std.mem.Allocator,
        /// 缓存作用域：连接名（空 = 随表归属）
        conn_name: []const u8 = "",
        ttl_seconds: i64 = 60,
        /// 条目上限（C# `MaxEntity`）：防止大表把内存吃满；0 = 不限
        max_entries: usize = 10_000,
        entries: std.AutoHashMapUnmanaged(i64, Entry) = .empty,
        mutex: Mutex = .{},
        seq: u64 = 0,
        registered: bool = false,

        total: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        success: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        evicted: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        /// 淘汰时用的临时数组（复用，不在热路径重复分配）
        scratch: std.ArrayListUnmanaged(KeySeq) = .empty,

        pub fn init(dal: *Dal, ttl_seconds: i64) Self {
            return initConn(dal, "", ttl_seconds);
        }

        /// 按连接名初始化（分库：同名表在不同库各一份缓存）。
        pub fn initConn(dal: *Dal, conn_name: []const u8, ttl_seconds: i64) Self {
            return .{ .dal = dal, .gpa = dal.gpa, .conn_name = conn_name, .ttl_seconds = ttl_seconds };
        }

        pub fn deinit(self: *Self) void {
            if (self.registered) self.dal.unregisterCache(@ptrCast(self));
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.entries.iterator();
            while (it.next()) |kv| kv.value_ptr.arena.deinit();
            self.entries.deinit(self.gpa);
            self.scratch.deinit(self.gpa);
        }

        pub fn stats(self: *const Self) CacheStats {
            return .{
                .total = self.total.load(.monotonic),
                .success = self.success.load(.monotonic),
                .evicted = self.evicted.load(.monotonic),
            };
        }

        /// 使单个主键失效（**精确**：只丢这一行）。
        pub fn invalidate(self: *Self, pk: i64) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.removeLocked(pk);
        }

        /// 使全部条目失效（批量写 / 无法定位主键时用）。
        pub fn invalidateAll(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.entries.iterator();
            while (it.next()) |kv| kv.value_ptr.arena.deinit();
            self.entries.clearRetainingCapacity();
        }

        fn removeLocked(self: *Self, pk: i64) void {
            if (self.entries.fetchRemove(pk)) |kv| {
                var entry = kv.value;
                entry.arena.deinit();
            }
        }

        fn invalidateKeyHook(ctx: *anyopaque, key: i64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.invalidate(key);
        }

        fn invalidateHook(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.invalidateAll();
        }

        fn ensureRegistered(self: *Self) !void {
            if (self.registered) return;
            const phys = if (self.dal.model.table(T.meta.table_name)) |t| t.effectiveTableName() else T.meta.table_name;
            const conn = if (self.conn_name.len > 0)
                self.conn_name
            else
                self.dal.tableConnName(T.meta.table_name) catch self.dal.connName();
            try self.dal.registerCache(.{
                .table_name = phys,
                .conn_name = conn,
                .ctx = @ptrCast(self),
                .invalidate = invalidateHook,
                .invalidate_key = invalidateKeyHook,
            });
            self.registered = true;
        }

        fn isExpired(self: *const Self, entry: *const Entry) bool {
            if (entry.loaded_at == 0) return true;
            if (self.ttl_seconds <= 0) return false;
            return DateTime.nowUnix() - entry.loaded_at >= self.ttl_seconds;
        }

        /// 按主键取（未命中/过期回库并缓存；不存在返回 null，**不缓存空值**）。
        pub fn get(self: *Self, s: *Session, pk: i64) !?T {
            try self.ensureRegistered();
            _ = self.total.fetchAdd(1, .monotonic);

            {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.entries.getPtr(pk)) |entry| {
                    if (!self.isExpired(entry)) {
                        self.seq += 1;
                        entry.visit_seq = self.seq;
                        _ = self.success.fetchAdd(1, .monotonic);
                        return entry.value;
                    }
                    self.removeLocked(pk);
                }
            }

            const row = (try entity.findByPk(self.dal, T, s, &.{.{ .int = pk }})) orelse return null;

            // 深拷贝到条目自己的 arena，脱离会话结果集生命周期
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer arena.deinit();
            const owned = try cloneEntity(T, arena.allocator(), row);

            self.mutex.lock();
            defer self.mutex.unlock();
            try self.putLocked(pk, owned, arena);
            return owned;
        }

        fn putLocked(self: *Self, pk: i64, value: T, arena: std.heap.ArenaAllocator) !void {
            const gop = try self.entries.getOrPut(self.gpa, pk);
            if (gop.found_existing) gop.value_ptr.arena.deinit();
            self.seq += 1;
            gop.value_ptr.* = .{
                .value = value,
                .loaded_at = DateTime.nowUnix(),
                .visit_seq = self.seq,
                .arena = arena,
            };
            if (self.max_entries > 0 and self.entries.count() > self.max_entries) self.evictLocked();
        }

        /// 超出上限时批量淘汰到 90%（一次扫描 + 排序，不是每插入一条就全扫）。
        fn evictLocked(self: *Self) void {
            const keep = self.max_entries - self.max_entries / 10;
            if (self.entries.count() <= keep) return;

            self.scratch.clearRetainingCapacity();
            var it = self.entries.iterator();
            while (it.next()) |kv| {
                self.scratch.append(self.gpa, .{ .seq = kv.value_ptr.visit_seq, .key = kv.key_ptr.* }) catch return;
            }
            std.mem.sort(KeySeq, self.scratch.items, {}, struct {
                fn lt(_: void, a: KeySeq, b: KeySeq) bool {
                    return a.seq < b.seq;
                }
            }.lt);

            const remove_count = self.entries.count() - keep;
            var i: usize = 0;
            while (i < remove_count and i < self.scratch.items.len) : (i += 1) {
                self.removeLocked(self.scratch.items[i].key);
            }
            _ = self.evicted.fetchAdd(remove_count, .monotonic);
        }

        /// 已缓存条目数（含已过期未清理的）。
        pub fn cachedCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.entries.count();
        }
    };
}
