//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 角色。业务场景中的岗位，功能权限的集合。不管是用户还是租户，都以角色来管理权限
const zcode = @import("../../root.zig");

pub const Role = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"ID": i32 = 0,
    /// 名称
    @"Name": []const u8 = "",
    /// 启用
    @"Enable": bool = false,
    /// 系统。用于业务系统开发使用，不受数据权限约束，禁止修改名称或删除
    @"IsSystem": bool = false,
    /// 租户。角色所属组合，0表示全局角色
    @"TenantId": i32 = 0,
    /// 权限。对不同资源的权限，逗号分隔，每个资源的权限子项竖线分隔
    @"Permission": []const u8 = "",
    /// 排序
    @"Sort": i32 = 0,
    /// 扩展1
    @"Ex1": i32 = 0,
    /// 扩展2
    @"Ex2": i32 = 0,
    /// 扩展3
    @"Ex3": f64 = 0,
    /// 扩展4
    @"Ex4": []const u8 = "",
    /// 扩展5
    @"Ex5": []const u8 = "",
    /// 扩展6
    @"Ex6": []const u8 = "",
    /// 创建者
    @"CreateUser": []const u8 = "",
    /// 创建用户
    @"CreateUserID": i32 = 0,
    /// 创建地址
    @"CreateIP": []const u8 = "",
    /// 创建时间
    @"CreateTime": zcode.DateTime = .{},
    /// 更新者
    @"UpdateUser": []const u8 = "",
    /// 更新用户
    @"UpdateUserID": i32 = 0,
    /// 更新地址
    @"UpdateIP": []const u8 = "",
    /// 更新时间
    @"UpdateTime": zcode.DateTime = .{},
    /// 备注
    @"Remark": []const u8 = "",

    pub const meta = zcode.entity.EntityMeta{
        .name = "Role",
        .table_name = "Role",
        .fields = &.{
            .{ .name = "ID", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "Name", .data_type = .string, .description = "名称" },
            .{ .name = "Enable", .data_type = .boolean, .description = "启用" },
            .{ .name = "IsSystem", .data_type = .boolean, .description = "系统。用于业务系统开发使用，不受数据权限约束，禁止修改名称或删除" },
            .{ .name = "TenantId", .data_type = .int32, .description = "租户。角色所属组合，0表示全局角色" },
            .{ .name = "Permission", .data_type = .string, .description = "权限。对不同资源的权限，逗号分隔，每个资源的权限子项竖线分隔" },
            .{ .name = "Sort", .data_type = .int32, .description = "排序" },
            .{ .name = "Ex1", .data_type = .int32, .description = "扩展1" },
            .{ .name = "Ex2", .data_type = .int32, .description = "扩展2" },
            .{ .name = "Ex3", .data_type = .double, .description = "扩展3" },
            .{ .name = "Ex4", .data_type = .string, .description = "扩展4" },
            .{ .name = "Ex5", .data_type = .string, .description = "扩展5" },
            .{ .name = "Ex6", .data_type = .string, .description = "扩展6" },
            .{ .name = "CreateUser", .data_type = .string, .description = "创建者" },
            .{ .name = "CreateUserID", .data_type = .int32, .description = "创建用户" },
            .{ .name = "CreateIP", .data_type = .string, .description = "创建地址" },
            .{ .name = "CreateTime", .data_type = .datetime, .description = "创建时间" },
            .{ .name = "UpdateUser", .data_type = .string, .description = "更新者" },
            .{ .name = "UpdateUserID", .data_type = .int32, .description = "更新用户" },
            .{ .name = "UpdateIP", .data_type = .string, .description = "更新地址" },
            .{ .name = "UpdateTime", .data_type = .datetime, .description = "更新时间" },
            .{ .name = "Remark", .data_type = .string, .length = 500, .description = "备注" },
        },
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};
    /// 自增列下标（ID）
    pub const identity_index: usize = 0;

    /// 索引（对应 `Model.xml` 的 `Index`）
    pub const indexes = [_]zcode.codegen.IndexInfo{
        .{ .columns = &.{"Name"}, .unique = false },
        .{ .columns = &.{"TenantId", "Name"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("Role");
    }
    pub fn getID(self: @This()) i32 { return self.@"ID"; }
    pub fn setID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ID", v)) return;
        self.@"ID" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getName(self: @This()) []const u8 { return self.@"Name"; }
    pub fn setName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Name", v)) return;
        self.@"Name" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getEnable(self: @This()) bool { return self.@"Enable"; }
    pub fn setEnable(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Enable", v)) return;
        self.@"Enable" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getIsSystem(self: @This()) bool { return self.@"IsSystem"; }
    pub fn setIsSystem(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"IsSystem", v)) return;
        self.@"IsSystem" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getTenantId(self: @This()) i32 { return self.@"TenantId"; }
    pub fn setTenantId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"TenantId", v)) return;
        self.@"TenantId" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getPermission(self: @This()) []const u8 { return self.@"Permission"; }
    pub fn setPermission(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Permission", v)) return;
        self.@"Permission" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getSort(self: @This()) i32 { return self.@"Sort"; }
    pub fn setSort(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Sort", v)) return;
        self.@"Sort" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getEx1(self: @This()) i32 { return self.@"Ex1"; }
    pub fn setEx1(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Ex1", v)) return;
        self.@"Ex1" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getEx2(self: @This()) i32 { return self.@"Ex2"; }
    pub fn setEx2(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Ex2", v)) return;
        self.@"Ex2" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getEx3(self: @This()) f64 { return self.@"Ex3"; }
    pub fn setEx3(self: *@This(), v: f64) void {
        if (zcode.entity.valueEql(self.@"Ex3", v)) return;
        self.@"Ex3" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getEx4(self: @This()) []const u8 { return self.@"Ex4"; }
    pub fn setEx4(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex4", v)) return;
        self.@"Ex4" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getEx5(self: @This()) []const u8 { return self.@"Ex5"; }
    pub fn setEx5(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex5", v)) return;
        self.@"Ex5" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getEx6(self: @This()) []const u8 { return self.@"Ex6"; }
    pub fn setEx6(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex6", v)) return;
        self.@"Ex6" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getCreateUser(self: @This()) []const u8 { return self.@"CreateUser"; }
    pub fn setCreateUser(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateUser", v)) return;
        self.@"CreateUser" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getCreateUserID(self: @This()) i32 { return self.@"CreateUserID"; }
    pub fn setCreateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"CreateUserID", v)) return;
        self.@"CreateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getCreateIP(self: @This()) []const u8 { return self.@"CreateIP"; }
    pub fn setCreateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateIP", v)) return;
        self.@"CreateIP" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"CreateTime", v)) return;
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 16);
    }
    pub fn getUpdateUser(self: @This()) []const u8 { return self.@"UpdateUser"; }
    pub fn setUpdateUser(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateUser", v)) return;
        self.@"UpdateUser" = v;
        zcode.entity.markDirty(&self.dirty, 17);
    }
    pub fn getUpdateUserID(self: @This()) i32 { return self.@"UpdateUserID"; }
    pub fn setUpdateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"UpdateUserID", v)) return;
        self.@"UpdateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 18);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateIP", v)) return;
        self.@"UpdateIP" = v;
        zcode.entity.markDirty(&self.dirty, 19);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"UpdateTime", v)) return;
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 20);
    }
    pub fn getRemark(self: @This()) []const u8 { return self.@"Remark"; }
    pub fn setRemark(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Remark", v)) return;
        self.@"Remark" = v;
        zcode.entity.markDirty(&self.dirty, 21);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"ID") },
            1 => .{ .text = self.@"Name" },
            2 => .{ .boolean = self.@"Enable" },
            3 => .{ .boolean = self.@"IsSystem" },
            4 => .{ .int = @intCast(self.@"TenantId") },
            5 => .{ .text = self.@"Permission" },
            6 => .{ .int = @intCast(self.@"Sort") },
            7 => .{ .int = @intCast(self.@"Ex1") },
            8 => .{ .int = @intCast(self.@"Ex2") },
            9 => .{ .float = self.@"Ex3" },
            10 => .{ .text = self.@"Ex4" },
            11 => .{ .text = self.@"Ex5" },
            12 => .{ .text = self.@"Ex6" },
            13 => .{ .text = self.@"CreateUser" },
            14 => .{ .int = @intCast(self.@"CreateUserID") },
            15 => .{ .text = self.@"CreateIP" },
            16 => .{ .datetime = self.@"CreateTime" },
            17 => .{ .text = self.@"UpdateUser" },
            18 => .{ .int = @intCast(self.@"UpdateUserID") },
            19 => .{ .text = self.@"UpdateIP" },
            20 => .{ .datetime = self.@"UpdateTime" },
            21 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"ID" = v.asI32() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            2 => { self.@"Enable" = v.asBool() orelse false; },
            3 => { self.@"IsSystem" = v.asBool() orelse false; },
            4 => { self.@"TenantId" = v.asI32() orelse 0; },
            5 => { switch (v) { .text => |t| self.@"Permission" = t, .null => self.@"Permission" = "", else => {} } },
            6 => { self.@"Sort" = v.asI32() orelse 0; },
            7 => { self.@"Ex1" = v.asI32() orelse 0; },
            8 => { self.@"Ex2" = v.asI32() orelse 0; },
            9 => { self.@"Ex3" = v.asF64() orelse 0; },
            10 => { switch (v) { .text => |t| self.@"Ex4" = t, .null => self.@"Ex4" = "", else => {} } },
            11 => { switch (v) { .text => |t| self.@"Ex5" = t, .null => self.@"Ex5" = "", else => {} } },
            12 => { switch (v) { .text => |t| self.@"Ex6" = t, .null => self.@"Ex6" = "", else => {} } },
            13 => { switch (v) { .text => |t| self.@"CreateUser" = t, .null => self.@"CreateUser" = "", else => {} } },
            14 => { self.@"CreateUserID" = v.asI32() orelse 0; },
            15 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            16 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            17 => { switch (v) { .text => |t| self.@"UpdateUser" = t, .null => self.@"UpdateUser" = "", else => {} } },
            18 => { self.@"UpdateUserID" = v.asI32() orelse 0; },
            19 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            20 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            21 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
