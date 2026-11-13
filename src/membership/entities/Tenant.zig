//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 租户。多租户SAAS平台，用于隔离业务数据
const zcode = @import("../../root.zig");

pub const Tenant = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"Id": i32 = 0,
    /// 编码。唯一编码
    @"Code": []const u8 = "",
    /// 名称。显示名称
    @"Name": []const u8 = "",
    /// 启用
    @"Enable": bool = false,
    /// 管理者
    @"ManagerId": i32 = 0,
    /// 角色组。租户可选的角色集合，不同级别的租户所拥有的角色不一样，高级功能也会不同
    @"RoleIds": []const u8 = "",
    /// 图标。附件路径
    @"Logo": []const u8 = "",
    /// 数据库。分库用的数据库名
    @"DatabaseName": []const u8 = "",
    /// 数据表。分表用的数据表前缀
    @"TableName": []const u8 = "",
    /// 过期时间。达到该时间后，自动禁用租户，空表示永不过期
    @"Expired": zcode.DateTime = .{},
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
        .name = "Tenant",
        .table_name = "Tenant",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "Code", .data_type = .string, .description = "编码。唯一编码" },
            .{ .name = "Name", .data_type = .string, .description = "名称。显示名称" },
            .{ .name = "Enable", .data_type = .boolean, .description = "启用" },
            .{ .name = "ManagerId", .data_type = .int32, .description = "管理者" },
            .{ .name = "RoleIds", .data_type = .string, .length = 200, .description = "角色组。租户可选的角色集合，不同级别的租户所拥有的角色不一样，高级功能也会不同" },
            .{ .name = "Logo", .data_type = .string, .description = "图标。附件路径" },
            .{ .name = "DatabaseName", .data_type = .string, .description = "数据库。分库用的数据库名" },
            .{ .name = "TableName", .data_type = .string, .description = "数据表。分表用的数据表前缀" },
            .{ .name = "Expired", .data_type = .datetime, .description = "过期时间。达到该时间后，自动禁用租户，空表示永不过期" },
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
        .{ .columns = &.{"Code"}, .unique = true },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("Tenant");
    }
    pub fn getId(self: @This()) i32 { return self.@"Id"; }
    pub fn setId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Id", v)) return;
        self.@"Id" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getCode(self: @This()) []const u8 { return self.@"Code"; }
    pub fn setCode(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Code", v)) return;
        self.@"Code" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getName(self: @This()) []const u8 { return self.@"Name"; }
    pub fn setName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Name", v)) return;
        self.@"Name" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getEnable(self: @This()) bool { return self.@"Enable"; }
    pub fn setEnable(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Enable", v)) return;
        self.@"Enable" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getManagerId(self: @This()) i32 { return self.@"ManagerId"; }
    pub fn setManagerId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ManagerId", v)) return;
        self.@"ManagerId" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getRoleIds(self: @This()) []const u8 { return self.@"RoleIds"; }
    pub fn setRoleIds(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"RoleIds", v)) return;
        self.@"RoleIds" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getLogo(self: @This()) []const u8 { return self.@"Logo"; }
    pub fn setLogo(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Logo", v)) return;
        self.@"Logo" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getDatabaseName(self: @This()) []const u8 { return self.@"DatabaseName"; }
    pub fn setDatabaseName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"DatabaseName", v)) return;
        self.@"DatabaseName" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getTableName(self: @This()) []const u8 { return self.@"TableName"; }
    pub fn setTableName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"TableName", v)) return;
        self.@"TableName" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getExpired(self: @This()) zcode.DateTime { return self.@"Expired"; }
    pub fn setExpired(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"Expired", v)) return;
        self.@"Expired" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getCreateUserId(self: @This()) i32 { return self.@"CreateUserId"; }
    pub fn setCreateUserId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"CreateUserId", v)) return;
        self.@"CreateUserId" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"CreateTime", v)) return;
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getCreateIP(self: @This()) []const u8 { return self.@"CreateIP"; }
    pub fn setCreateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateIP", v)) return;
        self.@"CreateIP" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getUpdateUserId(self: @This()) i32 { return self.@"UpdateUserId"; }
    pub fn setUpdateUserId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"UpdateUserId", v)) return;
        self.@"UpdateUserId" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"UpdateTime", v)) return;
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateIP", v)) return;
        self.@"UpdateIP" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getRemark(self: @This()) []const u8 { return self.@"Remark"; }
    pub fn setRemark(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Remark", v)) return;
        self.@"Remark" = v;
        zcode.entity.markDirty(&self.dirty, 16);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"Id") },
            1 => .{ .text = self.@"Code" },
            2 => .{ .text = self.@"Name" },
            3 => .{ .boolean = self.@"Enable" },
            4 => .{ .int = @intCast(self.@"ManagerId") },
            5 => .{ .text = self.@"RoleIds" },
            6 => .{ .text = self.@"Logo" },
            7 => .{ .text = self.@"DatabaseName" },
            8 => .{ .text = self.@"TableName" },
            9 => .{ .datetime = self.@"Expired" },
            10 => .{ .int = @intCast(self.@"CreateUserId") },
            11 => .{ .datetime = self.@"CreateTime" },
            12 => .{ .text = self.@"CreateIP" },
            13 => .{ .int = @intCast(self.@"UpdateUserId") },
            14 => .{ .datetime = self.@"UpdateTime" },
            15 => .{ .text = self.@"UpdateIP" },
            16 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"Id" = v.asI32() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Code" = t, .null => self.@"Code" = "", else => {} } },
            2 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            3 => { self.@"Enable" = v.asBool() orelse false; },
            4 => { self.@"ManagerId" = v.asI32() orelse 0; },
            5 => { switch (v) { .text => |t| self.@"RoleIds" = t, .null => self.@"RoleIds" = "", else => {} } },
            6 => { switch (v) { .text => |t| self.@"Logo" = t, .null => self.@"Logo" = "", else => {} } },
            7 => { switch (v) { .text => |t| self.@"DatabaseName" = t, .null => self.@"DatabaseName" = "", else => {} } },
            8 => { switch (v) { .text => |t| self.@"TableName" = t, .null => self.@"TableName" = "", else => {} } },
            9 => { self.@"Expired" = v.asDatetime() orelse .{}; },
            10 => { self.@"CreateUserId" = v.asI32() orelse 0; },
            11 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            12 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            13 => { self.@"UpdateUserId" = v.asI32() orelse 0; },
            14 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            15 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            16 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
