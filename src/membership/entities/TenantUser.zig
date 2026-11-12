//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 租户关系。用户选择租户进入系统后，以租户关系角色组替代自有角色组来进行鉴权
const zcode = @import("../../root.zig");

pub const TenantUser = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"Id": i32 = 0,
    /// 租户
    @"TenantId": i32 = 0,
    /// 用户
    @"UserId": i32 = 0,
    /// 启用
    @"Enable": bool = false,
    /// 部门。用户在该租户所属的部门
    @"DepartmentId": i32 = 0,
    /// 角色。用户在该租户所对应的主要角色，替换用户自身的角色组
    @"RoleId": i32 = 0,
    /// 角色组。次要角色集合
    @"RoleIds": []const u8 = "",
    /// 创建者
    @"CreateUserId": i32 = 0,
    /// 创建时间
    @"CreateTime": zcode.DateTime = .{},
    /// 创建地址
    @"CreateIP": []const u8 = "",
    /// 更新者
    @"UpdateUserId": i32 = 0,
    /// 更新时间
    @"UpdateTime": zcode.DateTime = .{},
    /// 更新地址
    @"UpdateIP": []const u8 = "",
    /// 描述
    @"Remark": []const u8 = "",

    pub const meta = zcode.entity.EntityMeta{
        .name = "TenantUser",
        .table_name = "TenantUser",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "TenantId", .data_type = .int32, .description = "租户" },
            .{ .name = "UserId", .data_type = .int32, .description = "用户" },
            .{ .name = "Enable", .data_type = .boolean, .description = "启用" },
            .{ .name = "DepartmentId", .data_type = .int32, .description = "部门。用户在该租户所属的部门" },
            .{ .name = "RoleId", .data_type = .int32, .description = "角色。用户在该租户所对应的主要角色，替换用户自身的角色组" },
            .{ .name = "RoleIds", .data_type = .string, .length = 200, .description = "角色组。次要角色集合" },
            .{ .name = "CreateUserId", .data_type = .int32, .description = "创建者" },
            .{ .name = "CreateTime", .data_type = .datetime, .description = "创建时间" },
            .{ .name = "CreateIP", .data_type = .string, .description = "创建地址" },
            .{ .name = "UpdateUserId", .data_type = .int32, .description = "更新者" },
            .{ .name = "UpdateTime", .data_type = .datetime, .description = "更新时间" },
            .{ .name = "UpdateIP", .data_type = .string, .description = "更新地址" },
            .{ .name = "Remark", .data_type = .string, .length = 500, .description = "描述" },
        },
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};
    /// 自增列下标（Id）
    pub const identity_index: usize = 0;

    /// 索引（对应 `Model.xml` 的 `Index`）
    pub const indexes = [_]zcode.codegen.IndexInfo{
        .{ .columns = &.{"TenantId", "UserId"}, .unique = true },
        .{ .columns = &.{"UserId"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("TenantUser");
    }
    pub fn getId(self: @This()) i32 { return self.@"Id"; }
    pub fn setId(self: *@This(), v: i32) void {
        self.@"Id" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getTenantId(self: @This()) i32 { return self.@"TenantId"; }
    pub fn setTenantId(self: *@This(), v: i32) void {
        self.@"TenantId" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getUserId(self: @This()) i32 { return self.@"UserId"; }
    pub fn setUserId(self: *@This(), v: i32) void {
        self.@"UserId" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getEnable(self: @This()) bool { return self.@"Enable"; }
    pub fn setEnable(self: *@This(), v: bool) void {
        self.@"Enable" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getDepartmentId(self: @This()) i32 { return self.@"DepartmentId"; }
    pub fn setDepartmentId(self: *@This(), v: i32) void {
        self.@"DepartmentId" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getRoleId(self: @This()) i32 { return self.@"RoleId"; }
    pub fn setRoleId(self: *@This(), v: i32) void {
        self.@"RoleId" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getRoleIds(self: @This()) []const u8 { return self.@"RoleIds"; }
    pub fn setRoleIds(self: *@This(), v: []const u8) void {
        self.@"RoleIds" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getCreateUserId(self: @This()) i32 { return self.@"CreateUserId"; }
    pub fn setCreateUserId(self: *@This(), v: i32) void {
        self.@"CreateUserId" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getCreateIP(self: @This()) []const u8 { return self.@"CreateIP"; }
    pub fn setCreateIP(self: *@This(), v: []const u8) void {
        self.@"CreateIP" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getUpdateUserId(self: @This()) i32 { return self.@"UpdateUserId"; }
    pub fn setUpdateUserId(self: *@This(), v: i32) void {
        self.@"UpdateUserId" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        self.@"UpdateIP" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getRemark(self: @This()) []const u8 { return self.@"Remark"; }
    pub fn setRemark(self: *@This(), v: []const u8) void {
        self.@"Remark" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"Id") },
            1 => .{ .int = @intCast(self.@"TenantId") },
            2 => .{ .int = @intCast(self.@"UserId") },
            3 => .{ .boolean = self.@"Enable" },
            4 => .{ .int = @intCast(self.@"DepartmentId") },
            5 => .{ .int = @intCast(self.@"RoleId") },
            6 => .{ .text = self.@"RoleIds" },
            7 => .{ .int = @intCast(self.@"CreateUserId") },
            8 => .{ .datetime = self.@"CreateTime" },
            9 => .{ .text = self.@"CreateIP" },
            10 => .{ .int = @intCast(self.@"UpdateUserId") },
            11 => .{ .datetime = self.@"UpdateTime" },
            12 => .{ .text = self.@"UpdateIP" },
            13 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"Id" = v.asI32() orelse 0; },
            1 => { self.@"TenantId" = v.asI32() orelse 0; },
            2 => { self.@"UserId" = v.asI32() orelse 0; },
            3 => { self.@"Enable" = v.asBool() orelse false; },
            4 => { self.@"DepartmentId" = v.asI32() orelse 0; },
            5 => { self.@"RoleId" = v.asI32() orelse 0; },
            6 => { switch (v) { .text => |t| self.@"RoleIds" = t, .null => self.@"RoleIds" = "", else => {} } },
            7 => { self.@"CreateUserId" = v.asI32() orelse 0; },
            8 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            9 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            10 => { self.@"UpdateUserId" = v.asI32() orelse 0; },
            11 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            12 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            13 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
