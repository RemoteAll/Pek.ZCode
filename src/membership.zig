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
/// 操作日志（LogProvider / 实体钩子的备注拼接）。
pub const log = @import("membership/log.zig");
/// 各实体业务规则（用户/角色/菜单/租户关系/字典参数/部门的纯计算部分）。
pub const rules = @import("membership/rules.zig");
/// 登录提供者（LoginCore 八步 / 注册 / 改密，数据读写由 UserStore 注入）。
pub const provider = @import("membership/provider.zig");
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
pub const LogProvider = log.LogProvider;
pub const ManageProvider = provider.ManageProvider;
pub const LoginError = provider.LoginError;
/// `UserStore` 的真实 ORM 实现（`User` 表按 `Model.xml` 的连接走，不另拼连接名）
pub const OrmStore = provider.OrmStore;
/// 实体字符串深拷贝（会话结果缓冲出了作用域就失效）
pub const deepCopyAlloc = provider.deepCopyAlloc;

pub const LogActions = log.action;

test {
    _ = enums;
    _ = password;
    _ = datascope;
    _ = log;
    _ = rules;
    _ = provider;
    _ = entities;
}
