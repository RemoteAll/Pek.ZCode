//! 由 zcodegen 生成：实体索引，请勿手改。
//!
//! 约定：`{Name}.zig` 是生成的数据契约（会覆盖）；`{Name}.biz.zig` 是业务扩展（不覆盖）。

pub const User = @import("User.zig").User;
pub const Department = @import("Department.zig").Department;
pub const Role = @import("Role.zig").Role;
pub const Menu = @import("Menu.zig").Menu;
pub const Parameter = @import("Parameter.zig").Parameter;
pub const Area = @import("Area.zig").Area;
pub const Log = @import("Log.zig").Log;
pub const Tenant = @import("Tenant.zig").Tenant;
pub const TenantUser = @import("TenantUser.zig").TenantUser;

/// 业务扩展模块（`{Name}.biz.zig`，手写代码放这里）
pub const UserBiz = @import("User.biz.zig");
pub const DepartmentBiz = @import("Department.biz.zig");
pub const RoleBiz = @import("Role.biz.zig");
pub const MenuBiz = @import("Menu.biz.zig");
pub const ParameterBiz = @import("Parameter.biz.zig");
pub const AreaBiz = @import("Area.biz.zig");
pub const LogBiz = @import("Log.biz.zig");
pub const TenantBiz = @import("Tenant.biz.zig");
pub const TenantUserBiz = @import("TenantUser.biz.zig");

/// 全部实体（用 `inline for (all) |T|` 编译期逐个处理）
pub const all = .{User, Department, Role, Menu, Parameter, Area, Log, Tenant, TenantUser};
