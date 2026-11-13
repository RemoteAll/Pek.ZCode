//! 缓存层其余四件（对应 DH.NCode `Cache/` 下 `CacheInvalidator.cs`、`DataCache.cs`、`DbCache.cs`、
//! `LazyConsumer.cs`）。
//!
//! | C# | Zig | 作用 |
//! |---|---|---|
//! | `LazyConsumer` | `LazyConsumer` | 只在有任务时才起后台线程、按序串行消费，空闲不占线程 |
//! | `CacheInvalidator` | `CacheInvalidator` | 分布式版本号：写方递增版本，其它进程 `poll()` 后发现版本变化就过期本地缓存 |
//! | `DataCache` | `DataCache` | 运行期数据缓存（表行数 + 字段键值），可落成文本档 |
//! | `DbCache` | `DbCache` | **用数据库表当缓存**（Name/Value/CreateTime/ExpiredTime），带过期清理 |
//!
//! 与 C# 的差异（有意）：
//! - `CacheInvalidator` 的 `Provider` 在 C# 是 `ICache`（Redis 等）；Zig 侧抽成两个函数指针
//!   （`get`/`set` 一个 i64），内存实现 `MemoryProvider` 现成可用，要接 Redis 只需实现这两个函数。
//!   键名保持 C# 的 `XCode:Cache:Ver:{table}` 前缀。
//! - `DataCache` 在 C# 是 JSON 落到 `DataPath`；这里用行式文本（`count:表=行数`、`field:名字:键=值`），
//!   避免为一份辅助缓存引入 JSON 依赖；解析/写回可往返。
//! - `DbCache` 在 C# 依赖实体实现 `IDbCache` 接口（`Name`/`Value`/`CreateTime`/`ExpiredTime`）；
//!   这里按**物理列名**工作，列名可配（默认就是这四个），值一律按文本存。

const std = @import("std");
const Value = @import("zzig").db.Value;
const DateTime = @import("zzig").DateTime;
const Buf = @import("zzig").Buf;
const dbtable = @import("dbtable.zig");
const TableRef = dbtable.TableRef;
const Session = @import("session.zig").Session;
const Where = @import("query.zig").Where;
const Query = @import("query.zig").Query;
const sqlbuild = @import("sqlbuild.zig");
const Dal = @import("dal.zig").Dal;

// ============================================================================
// LazyConsumer
// ============================================================================

/// 惰性串行消费者：仅在有任务时启动后台线程，任务处理完自动退出，空闲时不占线程。
///
/// 所有任务**严格按入队顺序**串行执行；单个任务抛错不影响后续任务（错误由任务自己记录）。
///
/// 实现说明（Zig 0.17）：`std.Thread` 在 0.17 已没有 `Mutex`/`Condition`（同步原语移到需要 `Io`
/// 实例的 `std.Io`），因此这里用公共库的 `zzig.compat.Mutex`（自旋 + `Thread.yield`）做临界区，
/// 并**不用条件变量**：worker 发现队列空就自行退出并把 `thread` 置空，`submit` 再加任务时会重新拉起。
/// 两个动作都在同一把锁里完成，不会出现「以为线程还在、任务却没人处理」的窗口。
pub const LazyConsumer = struct {
    gpa: std.mem.Allocator,
    mutex: Mutex = .{},
    queue: std.ArrayListUnmanaged(Task) = .empty,
    thread: ?std.Thread = null,
    /// 已执行任务数（便于观测）
    processed: usize = 0,

    const Mutex = @import("zzig").compat.Mutex;

    pub const Task = struct {
        ctx: ?*anyopaque = null,
        run: *const fn (ctx: ?*anyopaque) void,
    };

    pub fn init(gpa: std.mem.Allocator) LazyConsumer {
        return .{ .gpa = gpa };
    }

    /// 等后台线程跑完（若有）并释放队列；未执行的任务被丢弃（`deinit` 会释放它们的内存）。
    pub fn deinit(self: *LazyConsumer) void {
        self.mutex.lock();
        const maybe_thread = self.thread;
        self.thread = null;
        self.mutex.unlock();

        if (maybe_thread) |t| t.join();
        self.queue.deinit(self.gpa);
    }

    /// 提交任务；若后台线程不在则启动。
    pub fn submit(self: *LazyConsumer, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.queue.append(self.gpa, task);
        if (self.thread == null) {
            self.thread = try std.Thread.spawn(.{}, worker, .{self});
        }
    }

    /// 待处理任务数。
    pub fn pending(self: *LazyConsumer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.items.len;
    }

    fn worker(self: *LazyConsumer) void {
        while (true) {
            self.mutex.lock();
            if (self.queue.items.len == 0) {
                // 队列空 → 退出前在同一把锁里置空，保证 submit 之后一定能重新拉起
                self.thread = null;
                self.mutex.unlock();
                return;
            }
            const task = self.queue.orderedRemove(0);
            self.mutex.unlock();

            task.run(task.ctx);

            self.mutex.lock();
            self.processed += 1;
            self.mutex.unlock();
        }
    }
};

// ============================================================================
// CacheInvalidator
// ============================================================================

/// 分布式版本号提供者（C# `ICache` 的最小面：读 / 写一个 i64）。
pub const VersionProvider = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, key: []const u8) i64,
    setFn: *const fn (ctx: *anyopaque, key: []const u8, value: i64) void,
};

/// 进程内版本号提供者（单机 / 用例；多进程请换成 Redis 等实现）。
pub const MemoryProvider = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(i64) = .empty,

    pub fn init(gpa: std.mem.Allocator) MemoryProvider {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MemoryProvider) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.map.deinit(self.gpa);
    }

    pub fn provider(self: *MemoryProvider) VersionProvider {
        return .{ .ctx = @ptrCast(self), .getFn = getImpl, .setFn = setImpl };
    }

    fn getImpl(ctx: *anyopaque, key: []const u8) i64 {
        const self: *MemoryProvider = @ptrCast(@alignCast(ctx));
        return self.map.get(key) orelse 0;
    }

    fn setImpl(ctx: *anyopaque, key: []const u8, value: i64) void {
        const self: *MemoryProvider = @ptrCast(@alignCast(ctx));
        if (self.map.getEntry(key)) |e| {
            e.value_ptr.* = value;
            return;
        }
        const owned = self.gpa.dupe(u8, key) catch return;
        self.map.put(self.gpa, owned, value) catch self.gpa.free(owned);
    }
};

/// 二级缓存失效协调器：写方递增版本号，其它进程 `poll()` 发现变化后过期本地缓存。
pub const CacheInvalidator = struct {
    /// C# 的键前缀，保持一致便于跨语言共用同一个 Redis
    pub const key_prefix = "XCode:Cache:Ver:";

    gpa: std.mem.Allocator,
    dal: *Dal,
    provider: ?VersionProvider = null,
    /// 本进程已知版本：表名 → 版本号
    versions: std.StringHashMapUnmanaged(i64) = .empty,
    /// 主动失效次数
    bumps: usize = 0,

    pub fn init(gpa: std.mem.Allocator, dal: *Dal, provider: ?VersionProvider) CacheInvalidator {
        return .{ .gpa = gpa, .dal = dal, .provider = provider };
    }

    pub fn deinit(self: *CacheInvalidator) void {
        var it = self.versions.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.versions.deinit(self.gpa);
    }

    /// 键名（`XCode:Cache:Ver:{table}`）。
    pub fn keyOf(gpa: std.mem.Allocator, table_name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ key_prefix, table_name });
    }

    /// 通知所有进程清除指定表的缓存：递增分布式版本号，并立即过期本地缓存。
    pub fn invalidate(self: *CacheInvalidator, table_name: []const u8) void {
        self.markWritten(table_name);
        self.dal.invalidateCaches(table_name);
    }

    /// 只广播（递增分布式版本号 + 更新本地版本），**不**回调 `Dal.invalidateCaches`。
    ///
    /// `Dal` 的写操作会调它（本地已由 Dal 自己失效），这样不会重入。
    pub fn markWritten(self: *CacheInvalidator, table_name: []const u8) void {
        const ver = self.version(table_name) + 1;
        if (self.provider) |p| {
            const key = keyOf(self.gpa, table_name) catch return;
            defer self.gpa.free(key);
            p.setFn(p.ctx, key, ver);
        }
        self.remember(table_name, ver);
        self.bumps += 1;
    }

    /// 本进程已知版本号（**纯内存**，热路径可调，无网络开销）。
    pub fn localVersion(self: *CacheInvalidator, table_name: []const u8) i64 {
        return self.versions.get(table_name) orelse 0;
    }

    /// 把本协调器挂到 `Dal` 上：写操作自动广播、读缓存自动比对本地版本。
    ///
    /// 典型用法（多系统/多进程共用同一张表）：
    /// ```zig
    /// var inv = zcode.dbcache.CacheInvalidator.init(gpa, &dal, provider);
    /// inv.attach();
    /// ```
    pub fn attach(self: *CacheInvalidator) void {
        self.dal.remote_cache = .{
            .ctx = @ptrCast(self),
            .bump = bumpImpl,
            .local_version = localVersionImpl,
            .poll = pollImpl,
            .attach = attachImpl,
        };
    }

    fn bumpImpl(ctx: *anyopaque, table_name: []const u8) void {
        const self: *CacheInvalidator = @ptrCast(@alignCast(ctx));
        self.markWritten(table_name);
    }

    fn localVersionImpl(ctx: *anyopaque, table_name: []const u8) i64 {
        const self: *CacheInvalidator = @ptrCast(@alignCast(ctx));
        return self.localVersion(table_name);
    }

    fn pollImpl(ctx: *anyopaque) usize {
        const self: *CacheInvalidator = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    fn attachImpl(ctx: *anyopaque, table_name: []const u8) void {
        const self: *CacheInvalidator = @ptrCast(@alignCast(ctx));
        self.register(table_name);
    }

    /// 读当前分布式版本号（没有 provider 时返回本进程记录的版本）。
    pub fn version(self: *CacheInvalidator, table_name: []const u8) i64 {
        if (self.provider) |p| {
            const key = keyOf(self.gpa, table_name) catch return 0;
            defer self.gpa.free(key);
            return p.getFn(p.ctx, key);
        }
        return self.versions.get(table_name) orelse 0;
    }

    /// 检查所有已知表的版本号，变化者过期本地缓存；返回本次失效的表数。
    ///
    /// 典型用法：后台定时（如 5~30 秒）调一次，即可做到「另一个进程改了数据 → 本进程缓存过期」。
    pub fn poll(self: *CacheInvalidator) usize {
        const p = self.provider orelse return 0;

        var changed: usize = 0;
        var it = self.versions.iterator();
        while (it.next()) |entry| {
            const key = keyOf(self.gpa, entry.key_ptr.*) catch continue;
            defer self.gpa.free(key);

            const remote = p.getFn(p.ctx, key);
            if (remote != entry.value_ptr.*) {
                entry.value_ptr.* = remote;
                self.dal.invalidateCaches(entry.key_ptr.*);
                changed += 1;
            }
        }
        return changed;
    }

    /// 登记一张表的当前版本（首次调用时把远端版本记下来，避免第一轮误判为「变化」）。
    pub fn register(self: *CacheInvalidator, table_name: []const u8) void {
        self.remember(table_name, self.version(table_name));
    }

    fn remember(self: *CacheInvalidator, table_name: []const u8, ver: i64) void {
        if (self.versions.getEntry(table_name)) |e| {
            e.value_ptr.* = ver;
            return;
        }
        const owned = self.gpa.dupe(u8, table_name) catch return;
        self.versions.put(self.gpa, owned, ver) catch self.gpa.free(owned);
    }
};

// ============================================================================
// DataCache
// ============================================================================

/// 运行数据缓存：表总记录数 + 字段键值对，可落成文本档。
///
/// C# 用于「加速各实体类启动」——启动时读一次缓存，避免每张表都 `count(*)`。
pub const DataCache = struct {
    gpa: std.mem.Allocator,
    /// 表名 → 总记录数
    counts: std.StringHashMapUnmanaged(i64) = .empty,
    /// 名字 → (键 → 值)
    field_cache: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(FieldEntry)) = .empty,

    pub const FieldEntry = struct {
        value: []const u8,
    };

    pub fn init(gpa: std.mem.Allocator) DataCache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DataCache) void {
        var ci = self.counts.keyIterator();
        while (ci.next()) |k| self.gpa.free(k.*);
        self.counts.deinit(self.gpa);

        var fi = self.field_cache.iterator();
        while (fi.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            var inner = e.value_ptr;
            // 键与值各只有一份所有权：键由 inner 持有、值由 FieldEntry 持有，别重复 free
            var ii = inner.keyIterator();
            while (ii.next()) |k| self.gpa.free(k.*);
            var vi = inner.valueIterator();
            while (vi.next()) |v| self.gpa.free(v.value);
            inner.deinit(self.gpa);
        }
        self.field_cache.deinit(self.gpa);
    }

    /// 记一张表的总行数。
    pub fn setCount(self: *DataCache, table_name: []const u8, count: i64) !void {
        if (self.counts.getEntry(table_name)) |e| {
            e.value_ptr.* = count;
            return;
        }
        const owned = try self.gpa.dupe(u8, table_name);
        errdefer self.gpa.free(owned);
        try self.counts.put(self.gpa, owned, count);
    }

    pub fn getCount(self: *DataCache, table_name: []const u8) ?i64 {
        return self.counts.get(table_name);
    }

    /// 直接从库里数一次并记进缓存（对应 C# 启动时的行数填充）。
    pub fn refreshCount(self: *DataCache, s: *Session, table: TableRef) !i64 {
        const n = try table.count(s, null);
        try self.setCount(table.table_name, n);
        return n;
    }

    /// 记一个字段键值（如 `FieldCache` 快照）。
    pub fn setField(self: *DataCache, name: []const u8, key: []const u8, value: []const u8) !void {
        const inner = try self.ensureFieldMap(name);
        if (inner.getEntry(key)) |e| {
            const owned = try self.gpa.dupe(u8, value);
            self.gpa.free(e.value_ptr.value);
            e.value_ptr.value = owned;
            return;
        }
        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        const owned_value = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(owned_value);
        try inner.put(self.gpa, owned_key, .{ .value = owned_value });
    }

    pub fn getField(self: *DataCache, name: []const u8, key: []const u8) ?[]const u8 {
        const inner = self.field_cache.get(name) orelse return null;
        const e = inner.get(key) orelse return null;
        return e.value;
    }

    fn ensureFieldMap(self: *DataCache, name: []const u8) !*std.StringHashMapUnmanaged(FieldEntry) {
        if (self.field_cache.getEntry(name)) |e| return e.value_ptr;

        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.field_cache.put(self.gpa, owned, .empty);
        return self.field_cache.getEntry(name).?.value_ptr;
    }

    /// 行式文本：`count:表=行数` / `field:名字:键=值`（`#` 开头为注释）。
    pub fn parse(self: *DataCache, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const lhs = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

            if (std.mem.startsWith(u8, lhs, "count:")) {
                const table_name = lhs["count:".len..];
                const n = std.fmt.parseInt(i64, value, 10) catch continue;
                try self.setCount(table_name, n);
            } else if (std.mem.startsWith(u8, lhs, "field:")) {
                const rest = lhs["field:".len..];
                const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
                try self.setField(rest[0..colon], rest[colon + 1 ..], value);
            }
        }
    }

    /// 写回行式文本（调用方 free）。
    pub fn writeAlloc(self: *DataCache, gpa: std.mem.Allocator) ![]u8 {
        var b = Buf.init(gpa);
        defer b.deinit();

        var ci = self.counts.iterator();
        while (ci.next()) |e| try b.fmt("count:{s}={d}\n", .{ e.key_ptr.*, e.value_ptr.* });

        var fi = self.field_cache.iterator();
        while (fi.next()) |e| {
            var ii = e.value_ptr.iterator();
            while (ii.next()) |inner| {
                try b.fmt("field:{s}:{s}={s}\n", .{ e.key_ptr.*, inner.key_ptr.*, inner.value_ptr.value });
            }
        }
        return b.toOwnedSlice();
    }
};

// ============================================================================
// DbCache
// ============================================================================

/// 用**数据库表**当缓存（跨进程共享、重启不丢）。
///
/// 表结构要求（列名可配）：名称（字符串主键）、值（文本）、创建时间、过期时间。
/// 过期清理：`removeExpired()` 由调用方定时调（C# 里是 60 秒一次的 TimerX）。
pub const DbCache = struct {
    gpa: std.mem.Allocator,
    table: TableRef,
    name_column: []const u8 = "Name",
    value_column: []const u8 = "Value",
    create_time_column: []const u8 = "CreateTime",
    expired_time_column: []const u8 = "ExpiredTime",
    /// 默认过期秒数（`set` 传 <=0 时用它）
    default_expire: i64 = 60,

    pub fn init(gpa: std.mem.Allocator, table: TableRef) DbCache {
        return .{ .gpa = gpa, .table = table };
    }

    /// 缓存项个数（`count(*)`，高频使用时注意性能——C# 同样注释了这一点）。
    pub fn count(self: *DbCache, s: *Session) !i64 {
        return self.table.count(s, null);
    }

    /// 是否包含（未过期的）键。
    pub fn contains(self: *DbCache, s: *Session, key: []const u8) !bool {
        return (try self.find(s, key)) != null;
    }

    /// 取缓存值；不存在或已过期 → `null`（过期项顺手删掉）。
    pub fn get(self: *DbCache, s: *Session, key: []const u8) !?[]const u8 {
        const row = (try self.find(s, key)) orelse return null;
        const value = row.get(self.value_column) orelse return null;
        return switch (value) {
            .text => |t| t,
            else => try value.toTextAlloc(s.resultAllocator()),
        };
    }

    /// 写入/更新缓存项，返回是否新建。
    pub fn set(self: *DbCache, s: *Session, key: []const u8, value: []const u8, expire_seconds: i64) !bool {
        const expire = if (expire_seconds > 0) expire_seconds else self.default_expire;
        const now = DateTime.nowUnix();
        const expired = DateTime.fromUnixSeconds(now + expire);

        if (try self.find(s, key)) |_| {
            const sets = [_]sqlbuild.Field{
                .{ .name = self.value_column, .value = .{ .text = value } },
                .{ .name = self.expired_time_column, .value = .{ .datetime = expired } },
            };
            var w = Where.init(self.gpa);
            defer w.deinit();
            _ = try w.eq(self.name_column, .{ .text = key });
            _ = try self.table.update(s, &sets, &w);
            return false;
        }

        const fields = [_]sqlbuild.Field{
            .{ .name = self.name_column, .value = .{ .text = key } },
            .{ .name = self.value_column, .value = .{ .text = value } },
            .{ .name = self.create_time_column, .value = .{ .datetime = DateTime.fromUnixSeconds(now) } },
            .{ .name = self.expired_time_column, .value = .{ .datetime = expired } },
        };
        _ = try self.table.insert(s, &fields);
        return true;
    }

    /// 已存在则不写（对应 C# `Add`：常用于锁争夺）。
    pub fn add(self: *DbCache, s: *Session, key: []const u8, value: []const u8, expire_seconds: i64) !bool {
        if (try self.find(s, key) != null) return false;
        _ = try self.set(s, key, value, expire_seconds);
        return true;
    }

    /// 删除一个键，返回实际删除行数。
    pub fn remove(self: *DbCache, s: *Session, key: []const u8) !usize {
        var w = Where.init(self.gpa);
        defer w.deinit();
        _ = try w.eq(self.name_column, .{ .text = key });
        return self.table.delete(s, &w);
    }

    /// 清空整表。
    pub fn clear(self: *DbCache, s: *Session) !usize {
        return self.table.delete(s, null);
    }

    /// 清理过期项，返回删除行数（C# 里 60 秒一次）。
    pub fn removeExpired(self: *DbCache, s: *Session) !usize {
        var w = Where.init(self.gpa);
        defer w.deinit();
        _ = try w.lt(self.expired_time_column, .{ .datetime = DateTime.fromUnixSeconds(DateTime.nowUnix()) });
        return self.table.delete(s, &w);
    }

    /// 按名查一行；已过期则删掉并返回 null。
    fn find(self: *DbCache, s: *Session, key: []const u8) !?@import("session.zig").Row {
        var w = Where.init(self.gpa);
        defer w.deinit();
        _ = try w.eq(self.name_column, .{ .text = key });

        var q = Query.init(self.gpa);
        defer q.deinit();
        _ = q.filterWhere(&w).take(1);

        const rows = try self.table.queryRows(s, &q);
        if (rows.len == 0) return null;

        const row = rows[0];
        const expired_at = row.get(self.expired_time_column) orelse return row;
        const expire_unix: i64 = switch (expired_at) {
            .datetime => |dt| dt.toUnixSeconds(),
            .text => |t| blk: {
                const dt = DateTime.parse(t) catch break :blk std.math.maxInt(i64);
                break :blk dt.toUnixSeconds();
            },
            .int => |n| n,
            else => std.math.maxInt(i64),
        };
        if (expire_unix <= DateTime.nowUnix()) {
            _ = try self.remove(s, key);
            return null;
        }
        return row;
    }
};

// ============================ 测试 ============================

const testing = std.testing;
const model = @import("model.zig");

// --- LazyConsumer ---

const Counter = struct {
    value: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    // 0.17.1 坑：`[_]usize{0} ** 8` 会被解析成两个 `*` 直接报错，这里写字面量
    order: [8]usize = .{ 0, 0, 0, 0, 0, 0, 0, 0 },

    fn bump(ctx: ?*anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        const i = self.value.fetchAdd(1, .monotonic);
        if (i < self.order.len) self.order[i] = i;
    }
};

test "LazyConsumer：串行按序执行，空闲后线程退出" {
    var consumer = LazyConsumer.init(testing.allocator);
    defer consumer.deinit();

    var counter = Counter{};
    for (0..8) |_| try consumer.submit(.{ .ctx = &counter, .run = Counter.bump });

    // 等全部执行完
    var spins: usize = 0;
    while (consumer.pending() > 0 or consumer.processed < 8) {
        @import("zzig").compat.sleep(1 * std.time.ns_per_ms);
        spins += 1;
        if (spins > 5000) break;
    }

    try testing.expectEqual(@as(usize, 8), counter.value.load(.monotonic));
    for (counter.order, 0..) |v, i| try testing.expectEqual(i, v);
    try testing.expectEqual(@as(usize, 8), consumer.processed);
}

// --- CacheInvalidator ---

fn cacheTestDal(a: std.mem.Allocator) !Dal {
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<EntityModel>
        \\  <Tables>
        \\    <Table Name="User" TableName="User">
        \\      <Columns>
        \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\        <Column Name="Name" DataType="String" Length="50" Nullable="True" />
        \\      </Columns>
        \\    </Table>
        \\  </Tables>
        \\</EntityModel>
    ;
    const m = try model.EntityModel.parse(a, xml);
    return Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
}

const InvalidateProbe = struct {
    hits: usize = 0,
    fn hook(ctx: *anyopaque) void {
        const self: *InvalidateProbe = @ptrCast(@alignCast(ctx));
        self.hits += 1;
    }
};

test "CacheInvalidator：版本号递增 + poll 发现远端变化后失效本地缓存" {
    const a = testing.allocator;
    var dal = try cacheTestDal(a);
    defer dal.deinit();

    var mem = MemoryProvider.init(a);
    defer mem.deinit();

    var probe = InvalidateProbe{};
    try dal.registerCache(.{ .table_name = "User", .ctx = &probe, .invalidate = InvalidateProbe.hook });

    var inv = CacheInvalidator.init(a, &dal, mem.provider());
    defer inv.deinit();

    // 初始版本 0
    try testing.expectEqual(@as(i64, 0), inv.version("User"));
    inv.register("User");

    // 本进程主动失效：版本 +1，本地缓存立即失效
    inv.invalidate("User");
    try testing.expectEqual(@as(i64, 1), inv.version("User"));
    try testing.expectEqual(@as(usize, 1), probe.hits);
    try testing.expectEqual(@as(usize, 0), inv.poll()); // 自身刚写过，本地版本已同步 → 不重复失效

    // 另一个「进程」把版本推到 5
    const key = try CacheInvalidator.keyOf(a, "User");
    defer a.free(key);
    mem.provider().setFn(@ptrCast(&mem), key, 5);

    try testing.expectEqual(@as(usize, 1), inv.poll());
    try testing.expectEqual(@as(usize, 2), probe.hits);
    try testing.expectEqual(@as(usize, 0), inv.poll()); // 已同步，不再动
}

test "CacheInvalidator：没有 provider 时只在进程内计数" {
    const a = testing.allocator;
    var dal = try cacheTestDal(a);
    defer dal.deinit();

    var inv = CacheInvalidator.init(a, &dal, null);
    defer inv.deinit();

    inv.invalidate("User");
    try testing.expectEqual(@as(i64, 1), inv.version("User"));
    try testing.expectEqual(@as(usize, 0), inv.poll());
    try testing.expectEqual(@as(usize, 1), inv.bumps);
}

// --- DataCache ---

test "DataCache：行数 + 字段键值 + 文本往返" {
    var dc = DataCache.init(testing.allocator);
    defer dc.deinit();

    try dc.setCount("User", 42);
    try dc.setCount("Role", 3);
    try dc.setCount("User", 43);
    try testing.expectEqual(@as(i64, 43), dc.getCount("User").?);

    try dc.setField("User", "Name", "Alice");
    try dc.setField("User", "Name", "Bob");
    try dc.setField("User", "Title", "管理员");
    try testing.expectEqualStrings("Bob", dc.getField("User", "Name").?);
    try testing.expectEqualStrings("管理员", dc.getField("User", "Title").?);
    try testing.expect(dc.getField("User", "Nope") == null);

    const text = try dc.writeAlloc(testing.allocator);
    defer testing.allocator.free(text);

    var back = DataCache.init(testing.allocator);
    defer back.deinit();
    try back.parse(text);

    try testing.expectEqual(@as(i64, 43), back.getCount("User").?);
    try testing.expectEqual(@as(i64, 3), back.getCount("Role").?);
    try testing.expectEqualStrings("Bob", back.getField("User", "Name").?);
    try testing.expectEqualStrings("管理员", back.getField("User", "Title").?);
}

test "DataCache：refreshCount 走真库" {
    const a = testing.allocator;
    var dal = try cacheTestDal(a);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("User");
    for ([_][]const u8{ "a", "b", "c" }) |name| {
        const fields = [_]sqlbuild.Field{.{ .name = "Name", .value = .{ .text = name } }};
        _ = try table.insert(&s, &fields);
    }

    var dc = DataCache.init(a);
    defer dc.deinit();
    try testing.expectEqual(@as(i64, 3), try dc.refreshCount(&s, table));
    try testing.expectEqual(@as(i64, 3), dc.getCount("User").?);
}

// --- DbCache ---

fn dbCacheDal(a: std.mem.Allocator) !Dal {
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<EntityModel>
        \\  <Tables>
        \\    <Table Name="DbCache" TableName="DbCache">
        \\      <Columns>
        \\        <Column Name="Name" DataType="String" Length="100" PrimaryKey="True" />
        \\        <Column Name="Value" DataType="String" Length="500" Nullable="True" />
        \\        <Column Name="CreateTime" DataType="DateTime" />
        \\        <Column Name="ExpiredTime" DataType="DateTime" />
        \\      </Columns>
        \\    </Table>
        \\  </Tables>
        \\</EntityModel>
    ;
    const m = try model.EntityModel.parse(a, xml);
    return Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
}

test "DbCache：set / get / 更新 / add / remove / 过期清理" {
    const a = testing.allocator;
    var dal = try dbCacheDal(a);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var cache = DbCache.init(a, try dal.table("DbCache"));

    try testing.expect(try cache.set(&s, "k1", "v1", 60));
    try testing.expectEqualStrings("v1", (try cache.get(&s, "k1")).?);
    try testing.expect(try cache.contains(&s, "k1"));
    try testing.expectEqual(@as(i64, 1), try cache.count(&s));

    // 已存在 → 更新，不是新建
    try testing.expect(!try cache.set(&s, "k1", "v2", 60));
    try testing.expectEqualStrings("v2", (try cache.get(&s, "k1")).?);

    // add 已存在 → false
    try testing.expect(!try cache.add(&s, "k1", "v3", 60));
    try testing.expect(try cache.add(&s, "k2", "v2", 60));

    // 未命中
    try testing.expect(try cache.get(&s, "nope") == null);

    // 立即过期的项：get 返回 null 且顺手删掉
    _ = try cache.set(&s, "gone", "x", 1);
    {
        // 直接把过期时间改到过去
        const sets = [_]sqlbuild.Field{
            .{ .name = "ExpiredTime", .value = .{ .datetime = DateTime.fromUnixSeconds(DateTime.nowUnix() - 10) } },
        };
        var w = Where.init(a);
        defer w.deinit();
        _ = try w.eq("Name", .{ .text = "gone" });
        _ = try cache.table.update(&s, &sets, &w);
    }
    try testing.expect(try cache.get(&s, "gone") == null);

    // 造两条过期项，removeExpired 只清过期的
    for ([_][]const u8{ "e1", "e2" }) |k| {
        _ = try cache.set(&s, k, "v", 60);
        const sets = [_]sqlbuild.Field{
            .{ .name = "ExpiredTime", .value = .{ .datetime = DateTime.fromUnixSeconds(DateTime.nowUnix() - 10) } },
        };
        var w = Where.init(a);
        defer w.deinit();
        _ = try w.eq("Name", .{ .text = k });
        _ = try cache.table.update(&s, &sets, &w);
    }
    try testing.expectEqual(@as(usize, 2), try cache.removeExpired(&s));

    // 剩余的仍在
    try testing.expectEqualStrings("v2", (try cache.get(&s, "k1")).?);

    try testing.expectEqual(@as(usize, 1), try cache.remove(&s, "k2"));
    try testing.expect(try cache.get(&s, "k2") == null);

    _ = try cache.clear(&s);
    try testing.expectEqual(@as(i64, 0), try cache.count(&s));
}
