//! Membership 子系统（对应 C# `DH.NCode/Membership/`）——用户 / 角色 / 部门 / 菜单 / 租户 / 日志 / 参数字典 / 地区，
//! 外加数据权限、口令散列、登录提供者。
//!
//! 与 ORM 主链路的关系：本子系统**只提供业务语义**（实体 + 规则 + 权限翻译），
//! 读写仍走 `zcode.entity` / `zcode.dbtable` / `zcode.Dal`，不另造一套数据访问。
//!
//! 表结构以 `membership/Member.xml` 为唯一真相源（C# 同源文件）；
//! `src/membership/entities/*.zig` 由 `zig build codegen` 生成，**不要手改**。

const std = @import("std");

/// 枚举（`PermissionFlags` / `DataScopes` / `RoleTypes` …），数值逐字对齐 C#。
pub const enums = @import("membership/enums.zig");
/// 口令散列（C# `SaltPasswordProvider` 的 `md5+sha1` 档，字节级互通）。
pub const password = @import("membership/password.zig");
/// 数据权限（标记 / 上下文 / 条件翻译 / 字段掩码）。
pub const datascope = @import("membership/datascope.zig");
/// 九张表的实体（由 `Member.xml` 生成）。
pub const entities = @import("membership/entities/mod.zig");

pub const PermissionFlags = enums.PermissionFlags;
pub const DataScopes = enums.DataScopes;
pub const RoleTypes = enums.RoleTypes;
pub const SexKinds = enums.SexKinds;
pub const TenantTypes = enums.TenantTypes;
pub const DepartmentTypes = enums.DepartmentTypes;
pub const MenuTypes = enums.MenuTypes;
pub const ParameterKinds = enums.ParameterKinds;
pub const DataScopeContext = datascope.DataScopeContext;
pub const ScopeKind = datascope.ScopeKind;

test {
    _ = enums;
    _ = password;
    _ = datascope;
    _ = entities;
}
