//! Membership 枚举（对应 C# `Membership/*.cs` 里的各个 `Enums`）。
//!
//! **数值逐字对齐 C#**：这些值会落库、也会跨语言（C# / Rust `Pek.RPermissions`）互读，
//! 改一个数就会把历史数据读错，所以每个枚举都注明来源文件。

const std = @import("std");

/// 权限标志位（对应 C# `Membership/Enums/PermissionFlags.cs`，`[Flags] UInt32`）。
///
/// `All` 是**全位** `0xFFFFFFFF`（序列化到 `Role.Permission` 文本里是 `4294967295`）。
pub const PermissionFlags = enum(u32) {
    none = 0,
    /// 查看（详情）
    detail = 1,
    /// 新增
    insert = 2,
    /// 修改
    update = 4,
    /// 删除
    delete = 8,
    all = 0xFFFFFFFF,
};

/// 判断是否**同时**具备 `flag`（C# `(pf & flag) == flag`）。
pub fn has(flags: u32, flag: PermissionFlags) bool {
    const f: u32 = @backingInt(flag);
    return (flags & f) == f;
}

/// 置位（C# `pf |= flag`）。
pub fn set(flags: *u32, flag: PermissionFlags) void {
    flags.* |= @backingInt(flag);
}

/// 清位（C# `pf &= ~flag`）。
pub fn reset(flags: *u32, flag: PermissionFlags) void {
    flags.* &= ~@backingInt(flag);
}

/// 角色类型（C# `Membership/Entities/Role.cs` 的 `RoleTypes`）。
pub const RoleTypes = enum(i32) {
    /// 系统角色：拥有它可以看全部数据
    system = 1,
    /// 普通角色
    normal = 2,
    /// 租户角色
    tenant = 3,
};

/// 性别（C# `Membership/Entities/User.cs` 的 `SexKinds`）。
pub const SexKinds = enum(i32) {
    unknown = 0,
    male = 1,
    female = 2,
};

/// 租户类型（C# `Membership/Entities/Tenant.cs` 的 `TenantTypes`）。
pub const TenantTypes = enum(i32) {
    free = 1,
    personal = 2,
    enterprise = 3,
    ultimate = 4,
};

/// 部门类型（C# `Membership/Entities/Department.cs` 的 `DepartmentTypes`）。
pub const DepartmentTypes = enum(i32) {
    company = 1,
    department = 2,
    group = 3,
    dummy = 4,
};

/// 菜单类型（C# `Membership/Entities/Menu.cs` 的 `MenuTypes`）。
pub const MenuTypes = enum(i32) {
    /// 目录
    directory = 1,
    /// 菜单
    menu = 2,
    /// 功能（按钮）
    function = 3,
};

/// 字典参数类型（对齐 `System.TypeCode`，C# `Membership/Entities/Parameter.cs` 的 `ParameterKinds`）。
pub const ParameterKinds = enum(i32) {
    normal = 0,
    boolean = 3,
    int = 9,
    double = 14,
    datetime = 16,
    string = 18,
    list = 21,
    hash = 22,
};

/// 数据权限范围（C# `Membership/Interfaces/IDataScope.cs` 的 `DataScopes`）。
///
/// **数值越小权限越大**：`all = 0` 最大，`custom = 4` 最小；
/// 多角色取 **最小值** 即取最大权限（`DataScopeContext.Create` / `DataScopeHelper`）。
/// `default = -1` 表示「未设置」，不是有效范围。
pub const DataScopes = enum(i32) {
    /// 默认（未设置）
    default = -1,
    /// 全部数据
    all = 0,
    /// 本部门及下级
    department_and_children = 1,
    /// 本部门
    department = 2,
    /// 仅本人
    self_only = 3,
    /// 自定义部门
    custom = 4,
};

/// 把落库的整数转成 `DataScopes`；未知值回落 `default`（C# 直接强转，这里显式收敛）。
pub fn dataScopeFromInt(v: i32) DataScopes {
    return switch (v) {
        -1 => .default,
        0 => .all,
        1 => .department_and_children,
        2 => .department,
        3 => .self_only,
        4 => .custom,
        else => .default,
    };
}

/// 权限文本解析结果的一项：`{资源id}#{权限值}`。
pub const PermissionEntry = struct {
    id: i32,
    value: u32,
};

/// 解析 `Role.Permission` 文本：`"{id}#{value},{id}#{value}..."`（C# `Role.HasRoles` 口径）。
///
/// 口径与 C# 一致：
/// - 逗号分隔、每项 `id#value`；
/// - 按 **id 升序** 输出（C# `SavePermission` 排序后拼接）；
/// - 解析失败（缺 `#`、数字不合法）的项**跳过**，不整体失败。
pub fn parsePermissionAlloc(a: std.mem.Allocator, text: []const u8) ![]PermissionEntry {
    var list: std.ArrayList(PermissionEntry) = .empty;
    errdefer list.deinit(a);

    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r\n");
        if (item.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, item, '#') orelse continue;
        const id = std.fmt.parseInt(i32, item[0..sep], 10) catch continue;
        const val = std.fmt.parseInt(u32, item[sep + 1 ..], 10) catch continue;
        try list.append(a, .{ .id = id, .value = val });
    }
    std.mem.sort(PermissionEntry, list.items, {}, struct {
        fn lt(_: void, x: PermissionEntry, y: PermissionEntry) bool {
            return x.id < y.id;
        }
    }.lt);
    return list.toOwnedSlice(a);
}

/// 序列化 `Role.Permission` 文本（C# `SavePermission`）：按 id 升序，**不跳过 None**。
pub fn formatPermissionAlloc(a: std.mem.Allocator, entries: []const PermissionEntry) ![]u8 {
    const sorted = try a.dupe(PermissionEntry, entries);
    defer a.free(sorted);
    std.mem.sort(PermissionEntry, sorted, {}, struct {
        fn lt(_: void, x: PermissionEntry, y: PermissionEntry) bool {
            return x.id < y.id;
        }
    }.lt);

    var b = @import("zzig").Buf.init(a);
    defer b.deinit();
    for (sorted, 0..) |e, i| {
        if (i > 0) try b.addByte(',');
        try b.fmt("{d}#{d}", .{ e.id, e.value });
    }
    return b.toOwnedSlice();
}

/// 在权限文本里查某个资源 id 的权限值；找不到返回 0（C# `TryGetValue` 语义）。
pub fn permissionOf(text: []const u8, id: i32) u32 {
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r\n");
        if (item.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, item, '#') orelse continue;
        const got = std.fmt.parseInt(i32, item[0..sep], 10) catch continue;
        if (got != id) continue;
        return std.fmt.parseInt(u32, item[sep + 1 ..], 10) catch 0;
    }
    return 0;
}

test "PermissionFlags 位运算与全位 All" {
    var f: u32 = @backingInt(PermissionFlags.none);
    try std.testing.expect(!has(f, .detail));

    set(&f, .detail);
    set(&f, .insert);
    try std.testing.expect(has(f, .detail));
    try std.testing.expect(has(f, .insert));
    try std.testing.expect(!has(f, .delete));

    reset(&f, .detail);
    try std.testing.expect(!has(f, .detail));

    // All 是全位：任何单项都具备
    const all: u32 = @backingInt(PermissionFlags.all);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), all);
    try std.testing.expect(has(all, .detail));
    try std.testing.expect(has(all, .delete));
}

test "DataScopes 数值与「越小权限越大」" {
    try std.testing.expectEqual(@as(i32, -1), @backingInt(DataScopes.default));
    try std.testing.expectEqual(@as(i32, 0), @backingInt(DataScopes.all));
    try std.testing.expectEqual(@as(i32, 4), @backingInt(DataScopes.custom));

    // 多角色取最小值 = 取最大权限
    const scopes = [_]DataScopes{ .department, .self_only, .all };
    var min: i32 = 100;
    for (scopes) |s| min = @min(min, @backingInt(s));
    try std.testing.expectEqual(@as(i32, 0), min);
    try std.testing.expectEqual(DataScopes.all, dataScopeFromInt(min));
}

test "权限文本：解析忽略脏项、序列化按 id 升序且不跳过 None" {
    const a = std.testing.allocator;

    const parsed = try parsePermissionAlloc(a, "12#5, 3#4294967295,,bad,7#x,9#0");
    defer a.free(parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqual(@as(i32, 3), parsed[0].id);
    try std.testing.expectEqual(@as(i32, 9), parsed[1].id);
    try std.testing.expectEqual(@as(i32, 12), parsed[2].id);
    try std.testing.expectEqual(@as(u32, 0), parsed[1].value); // None 不跳过

    const text = try formatPermissionAlloc(a, &.{
        .{ .id = 9, .value = 0 },
        .{ .id = 3, .value = 4294967295 },
    });
    defer a.free(text);
    try std.testing.expectEqualStrings("3#4294967295,9#0", text);

    try std.testing.expectEqual(@as(u32, 5), permissionOf("3#5,9#0", 3));
    try std.testing.expectEqual(@as(u32, 0), permissionOf("3#5,9#0", 77));
}
