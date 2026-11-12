//! 各实体的业务规则（对应 C# `Membership/*.Biz.cs` 里的**纯计算部分**）。
//!
//! 这里只放**不碰数据库**的规则，便于单测；需要查库的部分（找角色、查部门、写日志）
//! 由调用方按注入或先行查询完成，不在本文件里偷偷查库。
//!
//! 每条规则都注明 C# 出处，便于逐条对账。

const std = @import("std");
const zzig = @import("zzig");
const enums = @import("enums.zig");
const password = @import("password.zig");

const PermissionFlags = enums.PermissionFlags;
const DataScopes = enums.DataScopes;
const DepartmentTypes = enums.DepartmentTypes;
const RoleTypes = enums.RoleTypes;
const ParameterKinds = enums.ParameterKinds;

// ---------------------------------------------------------------------------
// 用户（`用户.Biz.cs`）
// ---------------------------------------------------------------------------

/// 角色 id 列表 → `",1,2,"` 形式（C# 存取都用前后带逗号的形态，查库时 `LIKE '%,2,%'`）。
pub fn normalizeRoleIdsAlloc(a: std.mem.Allocator, ids: []const i32) ![]u8 {
    var b = zzig.Buf.init(a);
    defer b.deinit();
    try b.addByte(',');
    for (ids, 0..) |id, i| {
        if (i > 0) try b.addByte(',');
        try b.fmt("{d}", .{id});
    }
    try b.addByte(',');
    return b.toOwnedSlice();
}

/// 从 `",1,2,"` 解析角色 id（忽略空段与非法段）。
pub fn parseRoleIdsAlloc(a: std.mem.Allocator, text: []const u8) ![]i32 {
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

/// 年龄＝(今天 − 生日) 的整年数（C# `(Now - Birthday).TotalDays / 365`）。
///
/// 保留 C# 的 365 天口径（不是日历年），因为库里的 `Age` 是展示字段、不是权威生日。
pub fn ageOf(birthday: zzig.DateTime, now: zzig.DateTime) i32 {
    if (birthday.eql(.{})) return 0;
    const days = now.daysSinceUnixEpoch() - birthday.daysSinceUnixEpoch();
    if (days <= 0) return 0;
    return @intCast(@divTrunc(days, 365));
}

/// 新用户默认角色名：先「普通用户」、再「游客」（C# `用户.Valid` 的顺序）。
pub fn defaultRoleNames() [2][]const u8 {
    return .{ "普通用户", "游客" };
}

/// 注册时抢管理员（C# `用户.Register` 的 `DisableAdmin`）：
/// `Name == "admin"` 且 `Password == md5("admin")`（32 位 hex，忽略大小写）→ 禁用并给 4 号角色。
pub const DisableAdmin = struct {
    enable: bool,
    role_id: i32,
};

pub fn checkDisableAdmin(name: []const u8, stored_password: []const u8) ?DisableAdmin {
    if (!std.ascii.eqlIgnoreCase(name, "admin")) return null;

    var upper: [32]u8 = undefined;
    password.md5HexUpper(&upper, "admin");
    const hit = std.ascii.eqlIgnoreCase(stored_password, &upper) or
        std.mem.eql(u8, stored_password, "admin");
    if (!hit) return null;

    return .{ .enable = false, .role_id = 4 };
}

// ---------------------------------------------------------------------------
// 角色（`角色.Biz.cs`）
// ---------------------------------------------------------------------------

/// 角色类型推断（C# `角色.Valid` 里 `Type == 0` 时按名称/系统标记推断）。
pub fn inferRoleType(name: []const u8, is_system: bool) RoleTypes {
    if (is_system) return .system;
    if (std.mem.indexOf(u8, name, "管理员") != null) return .system;
    return .normal;
}

/// 按角色类型给默认数据范围（C# `角色.Valid`：新增且 `DataScope` 未脏且为 0 时填默认）。
pub fn defaultScopeFor(kind: RoleTypes) DataScopes {
    return switch (kind) {
        .system => .all,
        .normal => .department,
        .tenant => .self_only,
    };
}

/// 角色是否具备某个资源的某个权限（`Role.Permission` 文本 → 位判断）。
pub fn hasPermission(permission_text: []const u8, resource_id: i32, flag: PermissionFlags) bool {
    const flags = enums.permissionOf(permission_text, resource_id);
    return enums.has(flags, flag);
}

/// 多个角色对某资源是**或**关系（C# `HasRoles`：任一角色有权即有权）。
pub fn hasRoles(permission_texts: []const []const u8, resource_id: i32, flag: PermissionFlags) bool {
    for (permission_texts) |text| {
        if (hasPermission(text, resource_id, flag)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 菜单（`菜单.Biz.cs`）
// ---------------------------------------------------------------------------

/// C# 把该图标视作"没有图标"。
pub const empty_icon = "&#xe63f;";

/// 图标是否应视为空。
pub fn isIconEmpty(icon: []const u8) bool {
    return icon.len == 0 or std.mem.eql(u8, icon, empty_icon);
}

/// 子菜单排序：`Sort` **降序**，`Sort` 相同按 `ID` 升序（C# `FindAllByParentID`）。
pub fn sortChildren(comptime T: type, items: []T) void {
    std.mem.sort(T, items, {}, struct {
        fn lt(_: void, x: T, y: T) bool {
            if (x.@"Sort" != y.@"Sort") return x.@"Sort" > y.@"Sort";
            return x.@"ID" < y.@"ID";
        }
    }.lt);
}

// ---------------------------------------------------------------------------
// 租户关系（`租户关系.Biz.cs`）
// ---------------------------------------------------------------------------

/// 把 `RoleIds` 归一化成 `RoleId` + `",rest,"`（C# `Valid`）：
/// - `RoleIds` 为空 → 用 `RoleId` 组成 `",roleid,"`；
/// - 非空 → 解析后取**第一个**作为 `RoleId`，其余拼成 `",rest,"`。
pub const NormalizedRoles = struct {
    role_id: i32,
    role_ids: []u8,

    pub fn deinit(self: *NormalizedRoles, a: std.mem.Allocator) void {
        a.free(self.role_ids);
    }
};

pub fn normalizeTenantRoles(a: std.mem.Allocator, role_id: i32, role_ids_text: []const u8) !NormalizedRoles {
    var ids = try parseRoleIdsAlloc(a, role_ids_text);
    defer a.free(ids);

    if (ids.len == 0) {
        if (role_id <= 0) {
            return .{ .role_id = 0, .role_ids = try a.dupe(u8, "") };
        }
        const one = [_]i32{role_id};
        return .{ .role_id = role_id, .role_ids = try normalizeRoleIdsAlloc(a, &one) };
    }

    const first = ids[0];
    const rest_text = try normalizeRoleIdsAlloc(a, ids[1..]);
    return .{ .role_id = first, .role_ids = rest_text };
}

// ---------------------------------------------------------------------------
// 字典参数（`字典参数.Biz.cs`）
// ---------------------------------------------------------------------------

/// `Value` 列的最大长度（C# `SetValueInternal`：长度 < 200 写 `Value`，否则写 `LongValue`）。
pub const value_max_length = 200;

/// 决定值写入哪一列，返回 `true` 表示写 `Value`，`false` 表示写 `LongValue`。
pub fn useShortValue(text: []const u8) bool {
    return text.len < value_max_length;
}

/// 按类型把文本转成 `Parameter.Kind`（C# 对齐 `System.TypeCode`）。
pub fn kindOf(text: []const u8) ParameterKinds {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "true") or std.ascii.eqlIgnoreCase(t, "false")) return .boolean;
    if (std.fmt.parseInt(i32, t, 10)) |_| return .int else |_| {}
    if (std.fmt.parseFloat(f64, t)) |_| return .double else |_| {}
    return .string;
}

// ---------------------------------------------------------------------------
// 部门（`部门.Biz.cs`）
// ---------------------------------------------------------------------------

/// 部门类型推断（C# `部门.Valid` 里 `Type == 0` 时按名称关键词推断）。
///
/// 顺序与 C# 一致：先「公司」、再 `部`、再 `组`、再「项目」，都没命中按「部门」。
pub fn inferDepartmentType(name: []const u8) DepartmentTypes {
    if (std.mem.indexOf(u8, name, "公司") != null) return .company;
    if (std.mem.indexOf(u8, name, "部") != null) return .department;
    if (std.mem.indexOf(u8, name, "组") != null) return .group;
    if (std.mem.indexOf(u8, name, "项目") != null) return .dummy;
    return .department;
}

test "角色 id 往返：前后带逗号、去重、忽略脏段" {
    const a = std.testing.allocator;
    const text = try normalizeRoleIdsAlloc(a, &.{ 1, 2, 3 });
    defer a.free(text);
    try std.testing.expectEqualStrings(",1,2,3,", text);

    const ids = try parseRoleIdsAlloc(a, ",1,,2,x,2,");
    defer a.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(@as(i32, 1), ids[0]);
    try std.testing.expectEqual(@as(i32, 2), ids[1]);
}

test "年龄按 365 天口径" {
    const birthday = zzig.DateTime.fromUnixSeconds(0);
    const now = zzig.DateTime.fromUnixSeconds(365 * 86400 * 30);
    try std.testing.expectEqual(@as(i32, 30), ageOf(birthday, now));
    // 未填生日 → 0
    try std.testing.expectEqual(@as(i32, 0), ageOf(.{}, now));
}

test "注册抢管理员：admin + md5(admin) 或明文 admin 都命中" {
    var upper: [32]u8 = undefined;
    password.md5HexUpper(&upper, "admin");

    const hit = checkDisableAdmin("admin", &upper).?;
    try std.testing.expect(!hit.enable);
    try std.testing.expectEqual(@as(i32, 4), hit.role_id);

    try std.testing.expect(checkDisableAdmin("Admin", "admin") != null);
    try std.testing.expect(checkDisableAdmin("root", &upper) == null);
    try std.testing.expect(checkDisableAdmin("admin", "another-hash") == null);
}

test "角色类型推断与默认数据范围" {
    try std.testing.expectEqual(RoleTypes.system, inferRoleType("超级管理员", false));
    try std.testing.expectEqual(RoleTypes.system, inferRoleType("任意名", true));
    try std.testing.expectEqual(RoleTypes.normal, inferRoleType("普通用户", false));

    try std.testing.expectEqual(DataScopes.all, defaultScopeFor(.system));
    try std.testing.expectEqual(DataScopes.department, defaultScopeFor(.normal));
    try std.testing.expectEqual(DataScopes.self_only, defaultScopeFor(.tenant));
}

test "多角色权限是「或」关系" {
    const texts = [_][]const u8{ "3#1", "5#15" };
    try std.testing.expect(hasRoles(&texts, 5, .delete));
    try std.testing.expect(hasRoles(&texts, 3, .detail));
    try std.testing.expect(!hasRoles(&texts, 3, .update));
    try std.testing.expect(!hasRoles(&texts, 99, .detail));
}

test "菜单：空图标与子菜单排序（Sort 降序、ID 升序）" {
    try std.testing.expect(isIconEmpty(""));
    try std.testing.expect(isIconEmpty("&#xe63f;"));
    try std.testing.expect(!isIconEmpty("&#xe600;"));

    const Row = struct { @"ID": i32, @"Sort": i32 };
    var list = [_]Row{
        .{ .@"ID" = 3, .@"Sort" = 10 },
        .{ .@"ID" = 1, .@"Sort" = 20 },
        .{ .@"ID" = 2, .@"Sort" = 10 },
    };
    sortChildren(Row, &list);
    try std.testing.expectEqual(@as(i32, 1), list[0].@"ID"); // Sort 20
    try std.testing.expectEqual(@as(i32, 2), list[1].@"ID"); // Sort 10, ID 小
    try std.testing.expectEqual(@as(i32, 3), list[2].@"ID");
}

test "租户关系角色归一化" {
    const a = std.testing.allocator;

    var r1 = try normalizeTenantRoles(a, 7, "");
    defer r1.deinit(a);
    try std.testing.expectEqual(@as(i32, 7), r1.role_id);
    try std.testing.expectEqualStrings(",7,", r1.role_ids);

    var r2 = try normalizeTenantRoles(a, 7, ",5,6,9,");
    defer r2.deinit(a);
    try std.testing.expectEqual(@as(i32, 5), r2.role_id);
    try std.testing.expectEqualStrings(",6,9,", r2.role_ids);

    var r3 = try normalizeTenantRoles(a, 0, "");
    defer r3.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), r3.role_id);
    try std.testing.expectEqualStrings("", r3.role_ids);
}

test "字典参数字符串阈值与类型推断" {
    // 200 字节：199 仍走 Value，200 起改走 LongValue
    var buf: [200]u8 = undefined;
    @memset(&buf, 'x');
    try std.testing.expect(useShortValue(buf[0..199]));
    try std.testing.expect(!useShortValue(&buf));
    try std.testing.expectEqual(ParameterKinds.boolean, kindOf("TRUE"));
    try std.testing.expectEqual(ParameterKinds.int, kindOf("42"));
    try std.testing.expectEqual(ParameterKinds.double, kindOf("3.14"));
    try std.testing.expectEqual(ParameterKinds.string, kindOf("abc"));
}

test "部门类型按名称推断（公司 > 部 > 组 > 项目 > 默认部门）" {
    try std.testing.expectEqual(DepartmentTypes.company, inferDepartmentType("星尘科技有限公司"));
    try std.testing.expectEqual(DepartmentTypes.department, inferDepartmentType("技术部"));
    try std.testing.expectEqual(DepartmentTypes.group, inferDepartmentType("前端组"));
    try std.testing.expectEqual(DepartmentTypes.dummy, inferDepartmentType("某某项目"));
    try std.testing.expectEqual(DepartmentTypes.department, inferDepartmentType("财务"));
}
