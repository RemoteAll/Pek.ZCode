//! 数据权限（对应 C# `Membership/Interfaces/IDataScope.cs`、`DataScopeContext.cs`、`DataScopeModule.cs`）。
//!
//! 三个概念：
//! - **标记**：`IUserScope`（只有用户列，如日志）/ `IDepartmentScope`（只有部门列，如部门表）/ `IDataScope`（两者）。
//!   Zig 没有接口，用 `ScopeKind` 显式传入；调用方按实体语义选，**不要靠字段名猜**。
//! - **上下文**：`DataScopeContext` —— 当前用户生效的范围（多角色取**数值最小**＝权限最大）。
//!   构建期用 `building` 哨兵防递归（C# `IsBuilding`）。
//! - **翻译**：`DataScopeHelper.getFilter` 把范围翻成 `Where` 条件（唯一入口）。
//!
//! 关键设计（照抄 C#，别改）：
//! - **纯用户表（如日志）不做"部门 → join 用户表"放大**，避免"本部门"范围把同事数据暴露出来；
//! - `accessible_department_ids == null` 表示**不限制**，**空数组**表示**无任何部门**（生成恒假条件），两者完全不同；
//! - 部门表的"仅本人"退化为"我所在部门"，不能用恒假，否则部门表变空表；
//! - `(部门范围) OR (UserId = 我)` —— 本人数据始终可见。

const std = @import("std");
const zzig = @import("zzig");
const query = @import("../query.zig");
const Value = zzig.db.Value;

const Where = query.Where;
const enums = @import("enums.zig");
const DataScopes = enums.DataScopes;

/// 实体属于哪一类数据权限标记（对应 C# 三个标记接口）。
pub const ScopeKind = enum {
    /// 只有用户列（`IUserScope`）：任何非"全部"范围都退化为"仅本人"
    user,
    /// 只有部门列（`IDepartmentScope`）
    department,
    /// 用户列 + 部门列（`IDataScope`）
    both,
};

/// 角色里与数据权限相关的部分（从 `Role` 实体抽取，避免 helper 依赖生成代码）。
pub const RoleInfo = struct {
    /// `Role.IsSystem`
    is_system: bool = false,
    /// `Role.DataScope`（-1 表示未设置）
    data_scope: i32 = -1,
    /// `Role.ViewSensitive`
    view_sensitive: bool = false,
    /// `Role.DataDepartmentIds`（逗号分隔，自定义范围用）
    data_department_ids: []const u8 = "",
};

/// 部门查询的注入点（C# 里直接查 `Department`；这里用函数指针，便于单测与解耦）。
pub const DeptLookup = struct {
    ctx: *anyopaque,
    /// 取 `dept_id` 的直属子部门 id（C# `Department.Childs`）
    childrenFn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, dept_id: i32, out: *std.ArrayList(i32)) anyerror!void,
    /// 取 `user_id` 作为 `ManagerId` 管理的**已启用**部门 id（C# `GetManagedDepartmentIds`）
    managedFn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, user_id: i32, out: *std.ArrayList(i32)) anyerror!void,

    fn children(self: DeptLookup, a: std.mem.Allocator, dept_id: i32, out: *std.ArrayList(i32)) !void {
        try self.childrenFn(self.ctx, a, dept_id, out);
    }

    fn managed(self: DeptLookup, a: std.mem.Allocator, user_id: i32, out: *std.ArrayList(i32)) !void {
        try self.managedFn(self.ctx, a, user_id, out);
    }
};

/// 生效的数据权限上下文（C# `DataScopeContext`）。
pub const DataScopeContext = struct {
    user_id: i32 = 0,
    department_id: i32 = 0,
    scope: DataScopes = .default,
    /// 可访问部门白名单：**null = 不限制**；**空 = 无任何部门**
    accessible_department_ids: ?[]i32 = null,
    view_sensitive: bool = false,
    menu_id: i32 = 0,

    /// 是否不受数据权限约束（C# `IsSystem => DataScope == 全部`）
    pub fn isSystem(self: DataScopeContext) bool {
        return self.scope == .all;
    }

    pub fn deinit(self: *DataScopeContext, a: std.mem.Allocator) void {
        if (self.accessible_department_ids) |ids| a.free(ids);
        self.accessible_department_ids = null;
    }
};

/// 构建期哨兵：构建上下文时拦截器必须跳过过滤，否则会递归（C# `DataScopeContext.IsBuilding`）。
var building: bool = false;

pub fn isBuilding() bool {
    return building;
}

/// 部门白名单缓存（C# 用 `MemoryCache`，键 `DataScope:{userId}:{deptId}:{(int)scope}`）。
///
/// 键里带 `deptId` 的目的：用户调岗后**立即**换新部门列表，不用等过期。
pub const ScopeCache = struct {
    gpa: std.mem.Allocator,
    mutex: zzig.compat.Mutex = .{},
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct { ids: ?[]i32, at: i64 };

    pub fn init(a: std.mem.Allocator) ScopeCache {
        return .{ .gpa = a };
    }

    pub fn deinit(self: *ScopeCache) void {
        self.mutex.lock();
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.ids) |ids| self.gpa.free(ids);
        }
        self.map.deinit(self.gpa);
        self.mutex.unlock();
    }

    pub fn keyAlloc(a: std.mem.Allocator, user_id: i32, dept_id: i32, scope: DataScopes) ![]u8 {
        return std.fmt.allocPrint(a, "DataScope:{d}:{d}:{d}", .{ user_id, dept_id, @backingInt(scope) });
    }

    /// 取缓存（返回副本，调用方负责释放）。
    pub fn get(self: *ScopeCache, key: []const u8) ?[]i32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.map.get(key) orelse return null;
        const src = e.ids orelse return null; // null 语义（不限制）不缓存
        return self.gpa.dupe(i32, src) catch null;
    }

    /// 写缓存（`ids == null` 表示"不限制"，C# 不缓存这种情况）。
    pub fn put(self: *ScopeCache, key: []const u8, ids: ?[]const i32) void {
        const src = ids orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();

        const k = self.gpa.dupe(u8, key) catch return;
        const copy = self.gpa.dupe(i32, src) catch {
            self.gpa.free(k);
            return;
        };
        if (self.map.fetchRemove(key)) |old| {
            self.gpa.free(old.key);
            if (old.value.ids) |v| self.gpa.free(v);
        }
        self.map.put(self.gpa, k, .{ .ids = copy, .at = zzig.DateTime.nowUnix() }) catch {
            self.gpa.free(k);
            self.gpa.free(copy);
        };
    }

    /// 清缓存：`user_id > 0` 只清该用户，0 清全部（C# `ClearCache`）。
    pub fn clear(self: *ScopeCache, user_id: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (user_id == 0) {
            var it = self.map.iterator();
            while (it.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                if (e.value_ptr.ids) |ids| self.gpa.free(ids);
            }
            self.map.deinit(self.gpa);
            self.map = .empty;
            return;
        }

        const prefix = std.fmt.allocPrint(self.gpa, "DataScope:{d}:", .{user_id}) catch return;
        defer self.gpa.free(prefix);

        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.gpa);
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (std.mem.startsWith(u8, e.key_ptr.*, prefix)) doomed.append(self.gpa, e.key_ptr.*) catch {};
        }
        for (doomed.items) |k| {
            if (self.map.fetchRemove(k)) |old| {
                self.gpa.free(old.key);
                if (old.value.ids) |ids| self.gpa.free(ids);
            }
        }
    }
};

/// 构建上下文（C# `DataScopeContext.Create`，**严格按序**）：
///
/// 1. 有任一**系统角色** → `all` + `view_sensitive`，**立即返回**（不做菜单覆盖、不查部门）；
/// 2. 否则 `scope = min(roles.DataScope)`（数值最小 = 权限最大）；
/// 3. `view_sensitive = any(...)`；
/// 4. 菜单 `menu_scope >= 0` 时**覆盖**角色默认范围；
/// 5. 非"全部"才去查部门白名单（带缓存）。
pub fn create(
    a: std.mem.Allocator,
    user_id: i32,
    department_id: i32,
    roles: []const RoleInfo,
    menu_id: i32,
    menu_scope: i32,
    lookup: ?DeptLookup,
    cache: ?*ScopeCache,
) !DataScopeContext {
    var ctx = DataScopeContext{ .user_id = user_id, .department_id = department_id, .menu_id = menu_id };

    if (roles.len == 0) {
        // 无角色：仅本人，白名单保持 null（C# 同）
        ctx.scope = .self_only;
        return ctx;
    }

    const old = building;
    building = true;
    defer building = old;

    for (roles) |r| {
        if (r.is_system) {
            ctx.scope = .all;
            ctx.view_sensitive = true;
            return ctx; // 立即返回：不查部门、不做菜单覆盖
        }
    }

    var min: i32 = @backingInt(DataScopes.custom);
    var sensitive = false;
    for (roles) |r| {
        min = @min(min, r.data_scope);
        sensitive = sensitive or r.view_sensitive;
    }
    ctx.scope = enums.dataScopeFromInt(min);
    ctx.view_sensitive = sensitive;

    // 菜单级覆盖（C# `SetMenu`：`menu.DataScope >= 0` 才覆盖）
    if (menu_scope >= 0) ctx.scope = enums.dataScopeFromInt(menu_scope);

    ctx.accessible_department_ids = try getCachedDepartmentIds(a, user_id, department_id, roles, ctx.scope, lookup, cache);
    return ctx;
}

/// 带缓存的部门白名单（`scope == all` → null 且**不缓存**）。
pub fn getCachedDepartmentIds(
    a: std.mem.Allocator,
    user_id: i32,
    department_id: i32,
    roles: []const RoleInfo,
    scope: DataScopes,
    lookup: ?DeptLookup,
    cache: ?*ScopeCache,
) !?[]i32 {
    if (scope == .all) return null;

    var key_buf: [96]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "DataScope:{d}:{d}:{d}", .{ user_id, department_id, @backingInt(scope) }) catch return null;

    if (cache) |c| {
        if (c.get(key)) |ids| return ids;
    }

    const ids = try getAccessibleDepartmentIds(a, department_id, roles, scope, user_id, lookup);
    if (cache) |c| c.put(key, ids);
    return ids;
}

/// 把范围翻译成部门白名单（C# `DataScopeHelper.GetAccessibleDepartmentIds`）。
///
/// 返回语义：`null` = 不限制；空数组 = 无任何部门。
pub fn getAccessibleDepartmentIds(
    a: std.mem.Allocator,
    user_dept_id: i32,
    roles: []const RoleInfo,
    scope: DataScopes,
    user_id: i32,
    lookup: ?DeptLookup,
) !?[]i32 {
    // 无角色 → 空数组（无任何部门）
    if (roles.len == 0) return try a.alloc(i32, 0);

    // 任一系统角色 → 不限制
    for (roles) |r| if (r.is_system) return null;

    if (scope == .all) return null;

    var set = std.AutoHashMapUnmanaged(i32, void){};
    defer set.deinit(a);

    switch (scope) {
        .department_and_children => {
            if (user_dept_id > 0) {
                const ids = try getDepartmentAndChildren(a, user_dept_id, lookup);
                defer a.free(ids);
                for (ids) |id| try set.put(a, id, {});
            }
        },
        .department => {
            if (user_dept_id > 0) try set.put(a, user_dept_id, {});
        },
        .self_only => {}, // 空集合：调用方改用 UserId 过滤
        .custom => {
            for (roles) |r| {
                if (r.data_scope != @backingInt(DataScopes.custom)) continue;
                const ids = try parseDepartmentIds(a, r.data_department_ids);
                defer a.free(ids);
                for (ids) |id| try set.put(a, id, {});
            }
        },
        .all, .default => {},
    }

    // 我管理的部门（含下级）——「我」的范围始终包含这些
    if (user_id > 0 and scope != .self_only) {
        if (lookup) |lk| {
            var managed: std.ArrayList(i32) = .empty;
            defer managed.deinit(a);
            // C# 里这里异常会被 catch 并退化为"不扩展"，不打断主流程
            lk.managed(a, user_id, &managed) catch {};
            for (managed.items) |dept| {
                const ids = getDepartmentAndChildren(a, dept, lookup) catch continue;
                defer a.free(ids);
                for (ids) |id| try set.put(a, id, {});
            }
        }
    }

    var out = try a.alloc(i32, set.count());
    var i: usize = 0;
    var it = set.keyIterator();
    while (it.next()) |k| : (i += 1) out[i] = k.*;
    return out;
}

/// 部门自身 + 全部下级（C# `GetDepartmentAndChildren`）。
///
/// 部门不存在时**仍返回自身**（C# 同），只有 `<= 0` 才返回空。
pub fn getDepartmentAndChildren(a: std.mem.Allocator, department_id: i32, lookup: ?DeptLookup) ![]i32 {
    if (department_id <= 0) return try a.alloc(i32, 0);

    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(a);
    try list.append(a, department_id);
    const lk = lookup orelse return list.toOwnedSlice(a);
    try collectChildren(a, lk, department_id, &list);
    return list.toOwnedSlice(a);
}

fn collectChildren(a: std.mem.Allocator, lk: DeptLookup, parent: i32, list: *std.ArrayList(i32)) !void {
    var kids: std.ArrayList(i32) = .empty;
    defer kids.deinit(a);
    try lk.children(a, parent, &kids);
    for (kids.items) |k| {
        // 已包含则不递归（同时天然防成环）
        if (std.mem.indexOfScalar(i32, list.items, k) != null) continue;
        try list.append(a, k);
        try collectChildren(a, lk, k, list);
    }
}

/// 解析逗号分隔的部门 id（C# `ParseDepartmentIds`）：空/空白 → 空数组。
pub fn parseDepartmentIds(a: std.mem.Allocator, text: []const u8) ![]i32 {
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(a);
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r\n");
        if (item.len == 0) continue;
        const id = std.fmt.parseInt(i32, item, 10) catch continue;
        if (std.mem.indexOfScalar(i32, list.items, id) == null) try list.append(a, id);
    }
    return list.toOwnedSlice(a);
}

/// 部门白名单 → 条件（C# `BuildDepartmentFilter`）：
/// `null` 白名单 → 不限；空 → **恒假** `dept = -1`；单个 → `dept = ?`；多个 → `dept In (...)`。
pub fn buildDepartmentFilter(gpa: std.mem.Allocator, dept_field: []const u8, ids: ?[]const i32) !?Where {
    const list = ids orelse return null;

    var w = Where.init(gpa);
    errdefer w.deinit();

    if (list.len == 0) {
        _ = try w.eq(dept_field, .{ .int = -1 });
        return w;
    }
    if (list.len == 1) {
        _ = try w.eq(dept_field, .{ .int = list[0] });
        return w;
    }
    var vals = try gpa.alloc(Value, list.len);
    defer gpa.free(vals);
    for (list, 0..) |id, i| vals[i] = .{ .int = id };
    _ = try w.in(dept_field, vals);
    return w;
}

/// 纯部门表的条件（C# `BuildDepartmentScopeFilter`）：**仅本人退化为"我所在部门"**，不能恒假。
pub fn buildDepartmentScopeFilter(
    gpa: std.mem.Allocator,
    ctx: DataScopeContext,
    dept_field: []const u8,
) !?Where {
    if (ctx.scope == .self_only) {
        var w = Where.init(gpa);
        errdefer w.deinit();
        _ = try w.eq(dept_field, .{ .int = ctx.department_id });
        return w;
    }
    return buildDepartmentFilter(gpa, dept_field, ctx.accessible_department_ids);
}

/// 完整表的条件（C# `BuildFilter`）：部门范围 **或** 本人数据。
pub fn buildFilter(
    gpa: std.mem.Allocator,
    ctx: DataScopeContext,
    user_field: ?[]const u8,
    dept_field: ?[]const u8,
) !?Where {
    switch (ctx.scope) {
        .all, .default => return null,
        else => {},
    }

    // 仅本人：优先用户列；没有用户列退化为部门列；都没有 → 不限
    if (ctx.scope == .self_only) {
        if (user_field) |uf| {
            var w = Where.init(gpa);
            errdefer w.deinit();
            _ = try w.eq(uf, .{ .int = ctx.user_id });
            return w;
        }
        if (dept_field) |df| {
            var w = Where.init(gpa);
            errdefer w.deinit();
            _ = try w.eq(df, .{ .int = ctx.department_id });
            return w;
        }
        return null;
    }

    const dept_filter = try buildDepartmentFilter(gpa, dept_field orelse return null, ctx.accessible_department_ids);
    if (dept_filter == null) return null;

    // `(部门范围) OR (UserId = 我)` —— 本人数据始终可见
    if (user_field) |uf| {
        var w = dept_filter.?;
        defer w.deinit();

        // 取部门条件的绑定值：先渲成文本，再拼进 OR 片段
        var collected: std.ArrayList(Value) = .empty;
        defer collected.deinit(gpa);
        const text = try w.renderAlloc(gpa, .sqlite, &collected);
        defer gpa.free(text);

        var merged: std.ArrayList(Value) = .empty;
        defer merged.deinit(gpa);
        try merged.appendSlice(gpa, collected.items);
        try merged.append(gpa, .{ .int = ctx.user_id });

        var out = Where.init(gpa);
        errdefer out.deinit();
        const frag = try std.fmt.allocPrint(gpa, "({s}) Or ({s} = ?)", .{ text, uf });
        defer gpa.free(frag);
        _ = try out.raw(frag, merged.items);
        return out;
    }

    return dept_filter;
}

/// 唯一入口（C# `GetFilter`）：按标记类型选翻译方式。
///
/// **纯用户表不做部门 join 放大**（避免"本部门"暴露同事数据）。
pub fn getFilter(
    gpa: std.mem.Allocator,
    kind: ScopeKind,
    ctx: DataScopeContext,
    user_field: ?[]const u8,
    dept_field: ?[]const u8,
) !?Where {
    if (ctx.isSystem()) return null;

    return switch (kind) {
        .both => buildFilter(gpa, ctx, user_field, dept_field),
        .user => blk: {
            const uf = user_field orelse break :blk null;
            var w = Where.init(gpa);
            errdefer w.deinit();
            _ = try w.eq(uf, .{ .int = ctx.user_id });
            break :blk w;
        },
        .department => buildDepartmentScopeFilter(gpa, ctx, dept_field orelse return null),
    };
}

/// 写操作前的内存校验（C# `CanAccess` 三个重载合并）。
pub fn canAccess(kind: ScopeKind, ctx: ?DataScopeContext, user_id: i32, department_id: i32) bool {
    const c = ctx orelse return true;
    if (c.isSystem() or c.scope == .all) return true;

    switch (kind) {
        .user => return user_id == c.user_id,
        .department => {
            if (c.scope == .self_only) return department_id == c.department_id;
            const ids = c.accessible_department_ids orelse return true;
            return std.mem.indexOfScalar(i32, ids, department_id) != null;
        },
        .both => {
            if (c.scope == .self_only) return user_id == c.user_id;
            // 本人数据始终可访问
            if (user_id == c.user_id) return true;
            const ids = c.accessible_department_ids orelse return true;
            return std.mem.indexOfScalar(i32, ids, department_id) != null;
        },
    }
}

// ---------------------------------------------------------------------------
// 字段级权限（C# `IFieldScope` / `FieldScopeHelper`）：目前只有 `User` 实现，敏感字段 = `Password`
// ---------------------------------------------------------------------------

/// 不可见时替换成的掩码（C# `maskValue = "***"`）。
pub const default_mask = "***";

/// 把实体里的敏感字符串字段写成掩码（就地改，只处理 `[]const u8` 字段）。
///
/// `can_view == true` 时原样返回。Zig 没有接口，调用方按实体语义传入敏感字段名列表。
pub fn maskSensitiveFields(entity: anytype, sensitive: []const []const u8, can_view: bool, mask_value: []const u8) void {
    if (can_view) return;
    const T = @TypeOf(entity.*);
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (ftype != []const u8) continue;
        var hit = false;
        for (sensitive) |s| {
            if (std.ascii.eqlIgnoreCase(s, fname)) hit = true;
        }
        if (hit) @field(entity.*, fname) = mask_value;
    }
}

/// 单对象便捷入口：`User` 的敏感字段是 `Password`。
pub fn maskUser(entity: anytype, can_view: bool) void {
    maskSensitiveFields(entity, &.{"Password"}, can_view, default_mask);
}

test "DataScopes：系统角色立即返回全部且不看菜单覆盖" {
    const a = std.testing.allocator;
    var ctx = try create(a, 7, 3, &.{
        .{ .is_system = true, .data_scope = @backingInt(DataScopes.custom) },
        .{ .data_scope = @backingInt(DataScopes.department) },
    }, 42, @backingInt(DataScopes.self_only), null, null);
    defer ctx.deinit(a);

    try std.testing.expect(ctx.isSystem());
    try std.testing.expect(ctx.view_sensitive);
    try std.testing.expect(ctx.accessible_department_ids == null);
    try std.testing.expectEqual(@as(i32, 42), ctx.menu_id); // 菜单号仍记录
}

test "DataScopes：多角色取最小值＝最大权限；菜单可覆盖" {
    const a = std.testing.allocator;
    var ctx = try create(a, 7, 3, &.{
        .{ .data_scope = @backingInt(DataScopes.department) },
        .{ .data_scope = @backingInt(DataScopes.department_and_children) },
    }, 0, -1, null, null);
    defer ctx.deinit(a);
    try std.testing.expectEqual(DataScopes.department_and_children, ctx.scope);
    // 没有 lookup：只有自身部门
    try std.testing.expectEqual(@as(usize, 1), ctx.accessible_department_ids.?.len);
    try std.testing.expectEqual(@as(i32, 3), ctx.accessible_department_ids.?[0]);

    var ctx2 = try create(a, 7, 3, &.{.{ .data_scope = @backingInt(DataScopes.department) }}, 9, @backingInt(DataScopes.self_only), null, null);
    defer ctx2.deinit(a);
    try std.testing.expectEqual(DataScopes.self_only, ctx2.scope);
    try std.testing.expectEqual(@as(usize, 0), ctx2.accessible_department_ids.?.len);
}

test "部门白名单：null 不限 / 空集恒假 / 单个 = / 多个 In" {
    const a = std.testing.allocator;

    try std.testing.expect(try buildDepartmentFilter(a, "DepartmentId", null) == null);

    var w0 = (try buildDepartmentFilter(a, "DepartmentId", &.{})).?;
    defer w0.deinit();
    var p0: std.ArrayList(Value) = .empty;
    defer p0.deinit(a);
    const s0 = try w0.renderAlloc(a, .sqlite, &p0);
    defer a.free(s0);
    try std.testing.expectEqualStrings("(\"DepartmentId\" = ?)", s0);
    try std.testing.expectEqual(@as(i32, -1), p0.items[0].int);

    var w1 = (try buildDepartmentFilter(a, "DepartmentId", &.{5})).?;
    defer w1.deinit();
    var p1: std.ArrayList(Value) = .empty;
    defer p1.deinit(a);
    const s1 = try w1.renderAlloc(a, .sqlite, &p1);
    defer a.free(s1);
    try std.testing.expectEqualStrings("(\"DepartmentId\" = ?)", s1);

    var w2 = (try buildDepartmentFilter(a, "DepartmentId", &.{ 5, 6 })).?;
    defer w2.deinit();
    var p2: std.ArrayList(Value) = .empty;
    defer p2.deinit(a);
    const s2 = try w2.renderAlloc(a, .sqlite, &p2);
    defer a.free(s2);
    try std.testing.expectEqualStrings("(\"DepartmentId\" IN (?, ?))", s2);
}

test "纯用户表：非全部范围一律按本人（不做部门放大）" {
    const a = std.testing.allocator;
    const ctx = DataScopeContext{ .user_id = 11, .department_id = 3, .scope = .department };
    var w = (try getFilter(a, .user, ctx, "CreateUserID", "DepartmentId")).?;
    defer w.deinit();
    var p: std.ArrayList(Value) = .empty;
    defer p.deinit(a);
    const sql = try w.renderAlloc(a, .sqlite, &p);
    defer a.free(sql);
    try std.testing.expectEqualStrings("(\"CreateUserID\" = ?)", sql);
    try std.testing.expectEqual(@as(i32, 11), p.items[0].int);
}

test "纯部门表：仅本人退化为我所在部门（不能恒假）" {
    const a = std.testing.allocator;
    const ctx = DataScopeContext{ .user_id = 11, .department_id = 3, .scope = .self_only };
    var w = (try getFilter(a, .department, ctx, null, "ID")).?;
    defer w.deinit();
    var p: std.ArrayList(Value) = .empty;
    defer p.deinit(a);
    const sql = try w.renderAlloc(a, .sqlite, &p);
    defer a.free(sql);
    try std.testing.expectEqualStrings("(\"ID\" = ?)", sql);
    try std.testing.expectEqual(@as(i32, 3), p.items[0].int);
}

test "CanAccess：本人数据始终可见；白名单为空则否" {
    const ctx = DataScopeContext{
        .user_id = 11,
        .department_id = 3,
        .scope = .department,
        .accessible_department_ids = @constCast(&[_]i32{ 9, 10 }),
    };
    try std.testing.expect(canAccess(.both, ctx, 11, 999)); // 本人
    try std.testing.expect(canAccess(.both, ctx, 99, 9)); // 白名单部门
    try std.testing.expect(!canAccess(.both, ctx, 99, 3)); // 不在白名单

    const empty = DataScopeContext{ .user_id = 11, .department_id = 3, .scope = .department, .accessible_department_ids = @constCast(&[_]i32{}) };
    try std.testing.expect(!canAccess(.both, empty, 99, 3));

    // 无上下文/系统 → 一律放行
    try std.testing.expect(canAccess(.both, null, 1, 2));
    try std.testing.expect(canAccess(.user, DataScopeContext{ .scope = .all }, 1, 2));
}

test "掩码：只替换敏感字符串字段" {
    const Row = struct {
        ID: i32 = 1,
        Name: []const u8 = "admin",
        Password: []const u8 = "$md5+sha1$abc$def",
    };
    var r = Row{};
    maskUser(&r, false);
    try std.testing.expectEqualStrings(default_mask, r.Password);
    try std.testing.expectEqualStrings("admin", r.Name);
    try std.testing.expectEqual(@as(i32, 1), r.ID);

    var r2 = Row{};
    maskUser(&r2, true);
    try std.testing.expectEqualStrings("$md5+sha1$abc$def", r2.Password);
}
