//! 字段缓存（对应 C# `Cache/FieldCache`）：把一张表的「键列 → 值列」整表映射缓存成字典。
//!
//! 典型用法：`Code → Id`、`Name → Id`、`Id → Name` 这类**小字典表**（角色、参数、地区、菜单），
//! 业务里频繁按名字查 Id，走缓存比每次查库省一个往返。
//!
//! 语义（与 `cache.Cache(T)` 一致）：
//! - 首次访问 / TTL 到期 → 整表重载（阻塞式，读到的一定是最新快照）；
//! - **写后自动失效**：通过 `Dal.registerCache` 挂到表写入通知上（insert/update/delete/批量写都会触发）；
//! - `ttl_seconds = 0` 表示只靠写失效 + 手动 `invalidate`。
//!
//! 与 C# 的差异（有意）：
//! - C# 的 `FieldCache` 是泛型 `FieldCache<TEntity, TKey>`，按实体字段强类型返回；
//!   Zig 侧没有运行时反射，这里按**物理列名**工作，值统一为 `db.Value`（调用方按需 `asI64` / `asText`）。
//! - 键用列值的**文本形式**（`toTextAlloc`）：这样 `Id`（数字）与 `Code`（字符串）都能当键，且不受类型影响。
//! - 值为空（NULL）时不入字典（`get` 返回 null 与「没有这一行」区分不开，需要区分请直接查表）。

const std = @import("std");
const dal_mod = @import("dal.zig");
const Dal = dal_mod.Dal;
const dbtable = @import("dbtable.zig");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Query = @import("query.zig").Query;
const Value = @import("zzig").db.Value;
const DateTime = @import("zzig").DateTime;

pub const FieldCache = struct {
    dal: *Dal,
    table: dbtable.TableRef,
    /// 键列（物理列名）
    key_column: []const u8,
    /// 值列（物理列名）
    value_column: []const u8,
    /// 过期秒数（0 = 不过期，只靠写失效）
    ttl_seconds: i64 = 60,

    map: std.StringHashMapUnmanaged(Value) = .empty,
    arena: std.heap.ArenaAllocator,
    loaded_at: i64 = 0,
    registered: bool = false,

    pub fn init(dal: *Dal, table: dbtable.TableRef, key_column: []const u8, value_column: []const u8) FieldCache {
        return .{
            .dal = dal,
            .table = table,
            .key_column = key_column,
            .value_column = value_column,
            .arena = std.heap.ArenaAllocator.init(dal.gpa),
        };
    }

    pub fn deinit(self: *FieldCache) void {
        if (self.registered) self.dal.unregisterCache(@ptrCast(self));
        self.map.deinit(self.dal.gpa);
        self.arena.deinit();
    }

    /// 使缓存失效（下次访问重新整表装载）。
    pub fn invalidate(self: *FieldCache) void {
        self.loaded_at = 0;
    }

    fn invalidateHook(ctx: *anyopaque) void {
        const self: *FieldCache = @ptrCast(@alignCast(ctx));
        self.invalidate();
    }

    fn ensureRegistered(self: *FieldCache) !void {
        if (self.registered) return;
        try self.dal.registerCache(.{
            .table_name = self.table.table_name,
            .ctx = @ptrCast(self),
            .invalidate = invalidateHook,
        });
        self.registered = true;
    }

    fn isExpired(self: *const FieldCache) bool {
        if (self.loaded_at == 0) return true;
        if (self.ttl_seconds <= 0) return false;
        return DateTime.nowUnix() - self.loaded_at >= self.ttl_seconds;
    }

    fn ensureLoaded(self: *FieldCache, s: *Session) !void {
        if (!self.isExpired()) return;
        try self.ensureRegistered();
        try self.reload(s);
    }

    /// 整表重载（只取两列）。
    pub fn reload(self: *FieldCache, s: *Session) !void {
        const gpa = self.dal.gpa;

        // 先清空：装载失败时状态回到「未加载」，下次访问会重试
        _ = self.arena.reset(.retain_capacity);
        self.map.clearRetainingCapacity();
        self.loaded_at = 0;

        var q = Query.init(gpa);
        defer q.deinit();
        _ = try q.column(self.key_column);
        _ = try q.column(self.value_column);

        const rows = try self.table.queryRows(s, &q);
        for (rows) |row| {
            const key_value = row.get(self.key_column) orelse continue;
            const value = row.get(self.value_column) orelse continue;
            if (value == .null) continue;

            // 键/值都深拷贝进本缓存的 arena（会话结果集随时会被 reset）
            const arena = self.arena.allocator();
            const key_text = try key_value.toTextAlloc(arena);
            const owned = switch (value) {
                .text => |t| Value{ .text = try arena.dupe(u8, t) },
                else => value,
            };
            try self.map.put(gpa, key_text, owned);
        }
        self.loaded_at = DateTime.nowUnix();
    }

    /// 按键取（未加载/过期会先整表装载）；没有该键返回 null。
    pub fn get(self: *FieldCache, s: *Session, key: []const u8) !?Value {
        try self.ensureLoaded(s);
        return self.map.get(key);
    }

    /// 按键取整数（`Code → Id` 这类场景）。
    pub fn getId(self: *FieldCache, s: *Session, key: []const u8) !?i64 {
        const v = (try self.get(s, key)) orelse return null;
        return v.asI64();
    }

    /// 按键取文本。
    pub fn getText(self: *FieldCache, s: *Session, key: []const u8) !?[]const u8 {
        const v = (try self.get(s, key)) orelse return null;
        return switch (v) {
            .text => |t| t,
            else => null,
        };
    }

    /// 条目数（未加载/过期会先整表装载）。
    pub fn count(self: *FieldCache, s: *Session) !usize {
        try self.ensureLoaded(s);
        return self.map.count();
    }
};
