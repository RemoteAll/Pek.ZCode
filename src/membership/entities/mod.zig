//! 由 zcodegen 生成：实体索引，请勿手改。

pub const User = @import("User.zig").User;
pub const Department = @import("Department.zig").Department;
pub const Role = @import("Role.zig").Role;
pub const Menu = @import("Menu.zig").Menu;
pub const Parameter = @import("Parameter.zig").Parameter;
pub const Area = @import("Area.zig").Area;
pub const Log = @import("Log.zig").Log;
pub const Tenant = @import("Tenant.zig").Tenant;
pub const TenantUser = @import("TenantUser.zig").TenantUser;

/// 全部实体（用 `inline for (all) |T|` 编译期逐个处理）
pub const all = .{User, Department, Role, Menu, Parameter, Area, Log, Tenant, TenantUser};
