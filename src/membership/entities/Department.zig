//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 部门。组织机构，多级树状结构，支持多租户
const zcode = @import("../../root.zig");

pub const Department = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"ID": i32 = 0,
    /// 租户
    @"TenantId": i32 = 0,
    /// 代码
    @"Code": []const u8 = "",
    /// 名称
    @"Name": []const u8 = "",
    /// 全名
    @"FullName": []const u8 = "",
    /// 父级
    @"ParentID": i32 = 0,
    /// 层级。树状结构的层级
    @"Level": i32 = 0,
    /// 排序。同级内排序
    @"Sort": i32 = 0,
    /// 启用
    @"Enable": bool = false,
    /// 可见
    @"Visible": bool = false,
    /// 管理者
    @"ManagerId": i32 = 0,
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
        .name = "Department",
        .table_name = "Department",
        .fields = &.{
            .{ .name = "ID", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "TenantId", .data_type = .int32, .description = "租户" },
            .{ .name = "Code", .data_type = .string, .description = "代码" },
            .{ .name = "Name", .data_type = .string, .description = "名称" },
            .{ .name = "FullName", .data_type = .string, .length = 200, .description = "全名" },
            .{ .name = "ParentID", .data_type = .int32, .description = "父级" },
            .{ .name = "Level", .data_type = .int32, .description = "层级。树状结构的层级" },
            .{ .name = "Sort", .data_type = .int32, .description = "排序。同级内排序" },
            .{ .name = "Enable", .data_type = .boolean, .description = "启用" },
            .{ .name = "Visible", .data_type = .boolean, .description = "可见" },
            .{ .name = "ManagerId", .data_type = .int32, .description = "管理者" },
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
        .{ .columns = &.{"TenantId", "ParentID", "Name"}, .unique = false },
        .{ .columns = &.{"Name"}, .unique = false },
        .{ .columns = &.{"ParentID", "Name"}, .unique = false },
        .{ .columns = &.{"Code"}, .unique = false },
        .{ .columns = &.{"UpdateTime"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("Department");
    }
    pub fn getID(self: @This()) i32 { return self.@"ID"; }
    pub fn setID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ID", v)) return;
        self.@"ID" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getTenantId(self: @This()) i32 { return self.@"TenantId"; }
    pub fn setTenantId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"TenantId", v)) return;
        self.@"TenantId" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getCode(self: @This()) []const u8 { return self.@"Code"; }
    pub fn setCode(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Code", v)) return;
        self.@"Code" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getName(self: @This()) []const u8 { return self.@"Name"; }
    pub fn setName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Name", v)) return;
        self.@"Name" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getFullName(self: @This()) []const u8 { return self.@"FullName"; }
    pub fn setFullName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"FullName", v)) return;
        self.@"FullName" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getParentID(self: @This()) i32 { return self.@"ParentID"; }
    pub fn setParentID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ParentID", v)) return;
        self.@"ParentID" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getLevel(self: @This()) i32 { return self.@"Level"; }
    pub fn setLevel(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Level", v)) return;
        self.@"Level" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getSort(self: @This()) i32 { return self.@"Sort"; }
    pub fn setSort(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Sort", v)) return;
        self.@"Sort" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getEnable(self: @This()) bool { return self.@"Enable"; }
    pub fn setEnable(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Enable", v)) return;
        self.@"Enable" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getVisible(self: @This()) bool { return self.@"Visible"; }
    pub fn setVisible(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Visible", v)) return;
        self.@"Visible" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getManagerId(self: @This()) i32 { return self.@"ManagerId"; }
    pub fn setManagerId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ManagerId", v)) return;
        self.@"ManagerId" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getEx1(self: @This()) i32 { return self.@"Ex1"; }
    pub fn setEx1(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Ex1", v)) return;
        self.@"Ex1" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getEx2(self: @This()) i32 { return self.@"Ex2"; }
    pub fn setEx2(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Ex2", v)) return;
        self.@"Ex2" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getEx3(self: @This()) f64 { return self.@"Ex3"; }
    pub fn setEx3(self: *@This(), v: f64) void {
        if (zcode.entity.valueEql(self.@"Ex3", v)) return;
        self.@"Ex3" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getEx4(self: @This()) []const u8 { return self.@"Ex4"; }
    pub fn setEx4(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex4", v)) return;
        self.@"Ex4" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getEx5(self: @This()) []const u8 { return self.@"Ex5"; }
    pub fn setEx5(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex5", v)) return;
        self.@"Ex5" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getEx6(self: @This()) []const u8 { return self.@"Ex6"; }
    pub fn setEx6(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex6", v)) return;
        self.@"Ex6" = v;
        zcode.entity.markDirty(&self.dirty, 16);
    }
    pub fn getCreateUser(self: @This()) []const u8 { return self.@"CreateUser"; }
    pub fn setCreateUser(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateUser", v)) return;
        self.@"CreateUser" = v;
        zcode.entity.markDirty(&self.dirty, 17);
    }
    pub fn getCreateUserID(self: @This()) i32 { return self.@"CreateUserID"; }
    pub fn setCreateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"CreateUserID", v)) return;
        self.@"CreateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 18);
    }
    pub fn getCreateIP(self: @This()) []const u8 { return self.@"CreateIP"; }
    pub fn setCreateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateIP", v)) return;
        self.@"CreateIP" = v;
        zcode.entity.markDirty(&self.dirty, 19);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"CreateTime", v)) return;
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 20);
    }
    pub fn getUpdateUser(self: @This()) []const u8 { return self.@"UpdateUser"; }
    pub fn setUpdateUser(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateUser", v)) return;
        self.@"UpdateUser" = v;
        zcode.entity.markDirty(&self.dirty, 21);
    }
    pub fn getUpdateUserID(self: @This()) i32 { return self.@"UpdateUserID"; }
    pub fn setUpdateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"UpdateUserID", v)) return;
        self.@"UpdateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 22);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateIP", v)) return;
        self.@"UpdateIP" = v;
        zcode.entity.markDirty(&self.dirty, 23);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"UpdateTime", v)) return;
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 24);
    }
    pub fn getRemark(self: @This()) []const u8 { return self.@"Remark"; }
    pub fn setRemark(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Remark", v)) return;
        self.@"Remark" = v;
        zcode.entity.markDirty(&self.dirty, 25);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"ID") },
            1 => .{ .int = @intCast(self.@"TenantId") },
            2 => .{ .text = self.@"Code" },
            3 => .{ .text = self.@"Name" },
            4 => .{ .text = self.@"FullName" },
            5 => .{ .int = @intCast(self.@"ParentID") },
            6 => .{ .int = @intCast(self.@"Level") },
            7 => .{ .int = @intCast(self.@"Sort") },
            8 => .{ .boolean = self.@"Enable" },
            9 => .{ .boolean = self.@"Visible" },
            10 => .{ .int = @intCast(self.@"ManagerId") },
            11 => .{ .int = @intCast(self.@"Ex1") },
            12 => .{ .int = @intCast(self.@"Ex2") },
            13 => .{ .float = self.@"Ex3" },
            14 => .{ .text = self.@"Ex4" },
            15 => .{ .text = self.@"Ex5" },
            16 => .{ .text = self.@"Ex6" },
            17 => .{ .text = self.@"CreateUser" },
            18 => .{ .int = @intCast(self.@"CreateUserID") },
            19 => .{ .text = self.@"CreateIP" },
            20 => .{ .datetime = self.@"CreateTime" },
            21 => .{ .text = self.@"UpdateUser" },
            22 => .{ .int = @intCast(self.@"UpdateUserID") },
            23 => .{ .text = self.@"UpdateIP" },
            24 => .{ .datetime = self.@"UpdateTime" },
            25 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"ID" = v.asI32() orelse 0; },
            1 => { self.@"TenantId" = v.asI32() orelse 0; },
            2 => { switch (v) { .text => |t| self.@"Code" = t, .null => self.@"Code" = "", else => {} } },
            3 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            4 => { switch (v) { .text => |t| self.@"FullName" = t, .null => self.@"FullName" = "", else => {} } },
            5 => { self.@"ParentID" = v.asI32() orelse 0; },
            6 => { self.@"Level" = v.asI32() orelse 0; },
            7 => { self.@"Sort" = v.asI32() orelse 0; },
            8 => { self.@"Enable" = v.asBool() orelse false; },
            9 => { self.@"Visible" = v.asBool() orelse false; },
            10 => { self.@"ManagerId" = v.asI32() orelse 0; },
            11 => { self.@"Ex1" = v.asI32() orelse 0; },
            12 => { self.@"Ex2" = v.asI32() orelse 0; },
            13 => { self.@"Ex3" = v.asF64() orelse 0; },
            14 => { switch (v) { .text => |t| self.@"Ex4" = t, .null => self.@"Ex4" = "", else => {} } },
            15 => { switch (v) { .text => |t| self.@"Ex5" = t, .null => self.@"Ex5" = "", else => {} } },
            16 => { switch (v) { .text => |t| self.@"Ex6" = t, .null => self.@"Ex6" = "", else => {} } },
            17 => { switch (v) { .text => |t| self.@"CreateUser" = t, .null => self.@"CreateUser" = "", else => {} } },
            18 => { self.@"CreateUserID" = v.asI32() orelse 0; },
            19 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            20 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            21 => { switch (v) { .text => |t| self.@"UpdateUser" = t, .null => self.@"UpdateUser" = "", else => {} } },
            22 => { self.@"UpdateUserID" = v.asI32() orelse 0; },
            23 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            24 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            25 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
