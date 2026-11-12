//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 菜单。功能权限，大多数时候也是可见页面
const zcode = @import("../../root.zig");

pub const Menu = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"ID": i32 = 0,
    /// 名称
    @"Name": []const u8 = "",
    /// 显示名
    @"DisplayName": []const u8 = "",
    /// 类型。1目录/2菜单/3功能
    @"Type": i32 = 0,
    /// 全名
    @"FullName": []const u8 = "",
    /// 父编号
    @"ParentID": i32 = 0,
    /// 链接
    @"Url": []const u8 = "",
    /// 排序
    @"Sort": i32 = 0,
    /// 图标
    @"Icon": []const u8 = "",
    /// 可见
    @"Visible": bool = false,
    /// 必要。必要的菜单，必须至少有角色拥有这些权限，如果没有则自动授权给系统角色
    @"Necessary": bool = false,
    /// 新窗口。新窗口打开链接
    @"NewWindow": bool = false,
    /// 数据范围。该菜单的数据权限，-1使用角色默认/0全部/1本部门及下级/2本部门/3仅本人/4自定义
    @"DataScope": i32 = 0,
    /// 数据部门。数据范围为自定义时，选择的部门编号列表
    @"DataDepartmentIds": []const u8 = "",
    /// 权限子项。逗号分隔，每个权限子项编号与名称用井号分隔
    @"Permission": []const u8 = "",
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
        .name = "Menu",
        .table_name = "Menu",
        .fields = &.{
            .{ .name = "ID", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "Name", .data_type = .string, .description = "名称" },
            .{ .name = "DisplayName", .data_type = .string, .description = "显示名" },
            .{ .name = "Type", .data_type = .int32, .description = "类型。1目录/2菜单/3功能" },
            .{ .name = "FullName", .data_type = .string, .length = 200, .description = "全名" },
            .{ .name = "ParentID", .data_type = .int32, .description = "父编号" },
            .{ .name = "Url", .data_type = .string, .length = 200, .description = "链接" },
            .{ .name = "Sort", .data_type = .int32, .description = "排序" },
            .{ .name = "Icon", .data_type = .string, .description = "图标" },
            .{ .name = "Visible", .data_type = .boolean, .description = "可见" },
            .{ .name = "Necessary", .data_type = .boolean, .description = "必要。必要的菜单，必须至少有角色拥有这些权限，如果没有则自动授权给系统角色" },
            .{ .name = "NewWindow", .data_type = .boolean, .description = "新窗口。新窗口打开链接" },
            .{ .name = "DataScope", .data_type = .int32, .description = "数据范围。该菜单的数据权限，-1使用角色默认/0全部/1本部门及下级/2本部门/3仅本人/4自定义" },
            .{ .name = "DataDepartmentIds", .data_type = .string, .length = 500, .description = "数据部门。数据范围为自定义时，选择的部门编号列表" },
            .{ .name = "Permission", .data_type = .string, .length = 2000, .description = "权限子项。逗号分隔，每个权限子项编号与名称用井号分隔" },
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
        .{ .columns = &.{"ParentID", "Name"}, .unique = true },
        .{ .columns = &.{"Name"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("Menu");
    }
    pub fn getID(self: @This()) i32 { return self.@"ID"; }
    pub fn setID(self: *@This(), v: i32) void {
        self.@"ID" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getName(self: @This()) []const u8 { return self.@"Name"; }
    pub fn setName(self: *@This(), v: []const u8) void {
        self.@"Name" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getDisplayName(self: @This()) []const u8 { return self.@"DisplayName"; }
    pub fn setDisplayName(self: *@This(), v: []const u8) void {
        self.@"DisplayName" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getType(self: @This()) i32 { return self.@"Type"; }
    pub fn setType(self: *@This(), v: i32) void {
        self.@"Type" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getFullName(self: @This()) []const u8 { return self.@"FullName"; }
    pub fn setFullName(self: *@This(), v: []const u8) void {
        self.@"FullName" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getParentID(self: @This()) i32 { return self.@"ParentID"; }
    pub fn setParentID(self: *@This(), v: i32) void {
        self.@"ParentID" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getUrl(self: @This()) []const u8 { return self.@"Url"; }
    pub fn setUrl(self: *@This(), v: []const u8) void {
        self.@"Url" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getSort(self: @This()) i32 { return self.@"Sort"; }
    pub fn setSort(self: *@This(), v: i32) void {
        self.@"Sort" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getIcon(self: @This()) []const u8 { return self.@"Icon"; }
    pub fn setIcon(self: *@This(), v: []const u8) void {
        self.@"Icon" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getVisible(self: @This()) bool { return self.@"Visible"; }
    pub fn setVisible(self: *@This(), v: bool) void {
        self.@"Visible" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getNecessary(self: @This()) bool { return self.@"Necessary"; }
    pub fn setNecessary(self: *@This(), v: bool) void {
        self.@"Necessary" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getNewWindow(self: @This()) bool { return self.@"NewWindow"; }
    pub fn setNewWindow(self: *@This(), v: bool) void {
        self.@"NewWindow" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getDataScope(self: @This()) i32 { return self.@"DataScope"; }
    pub fn setDataScope(self: *@This(), v: i32) void {
        self.@"DataScope" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getDataDepartmentIds(self: @This()) []const u8 { return self.@"DataDepartmentIds"; }
    pub fn setDataDepartmentIds(self: *@This(), v: []const u8) void {
        self.@"DataDepartmentIds" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getPermission(self: @This()) []const u8 { return self.@"Permission"; }
    pub fn setPermission(self: *@This(), v: []const u8) void {
        self.@"Permission" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getEx1(self: @This()) i32 { return self.@"Ex1"; }
    pub fn setEx1(self: *@This(), v: i32) void {
        self.@"Ex1" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getEx2(self: @This()) i32 { return self.@"Ex2"; }
    pub fn setEx2(self: *@This(), v: i32) void {
        self.@"Ex2" = v;
        zcode.entity.markDirty(&self.dirty, 16);
    }
    pub fn getEx3(self: @This()) f64 { return self.@"Ex3"; }
    pub fn setEx3(self: *@This(), v: f64) void {
        self.@"Ex3" = v;
        zcode.entity.markDirty(&self.dirty, 17);
    }
    pub fn getEx4(self: @This()) []const u8 { return self.@"Ex4"; }
    pub fn setEx4(self: *@This(), v: []const u8) void {
        self.@"Ex4" = v;
        zcode.entity.markDirty(&self.dirty, 18);
    }
    pub fn getEx5(self: @This()) []const u8 { return self.@"Ex5"; }
    pub fn setEx5(self: *@This(), v: []const u8) void {
        self.@"Ex5" = v;
        zcode.entity.markDirty(&self.dirty, 19);
    }
    pub fn getEx6(self: @This()) []const u8 { return self.@"Ex6"; }
    pub fn setEx6(self: *@This(), v: []const u8) void {
        self.@"Ex6" = v;
        zcode.entity.markDirty(&self.dirty, 20);
    }
    pub fn getCreateUser(self: @This()) []const u8 { return self.@"CreateUser"; }
    pub fn setCreateUser(self: *@This(), v: []const u8) void {
        self.@"CreateUser" = v;
        zcode.entity.markDirty(&self.dirty, 21);
    }
    pub fn getCreateUserID(self: @This()) i32 { return self.@"CreateUserID"; }
    pub fn setCreateUserID(self: *@This(), v: i32) void {
        self.@"CreateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 22);
    }
    pub fn getCreateIP(self: @This()) []const u8 { return self.@"CreateIP"; }
    pub fn setCreateIP(self: *@This(), v: []const u8) void {
        self.@"CreateIP" = v;
        zcode.entity.markDirty(&self.dirty, 23);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 24);
    }
    pub fn getUpdateUser(self: @This()) []const u8 { return self.@"UpdateUser"; }
    pub fn setUpdateUser(self: *@This(), v: []const u8) void {
        self.@"UpdateUser" = v;
        zcode.entity.markDirty(&self.dirty, 25);
    }
    pub fn getUpdateUserID(self: @This()) i32 { return self.@"UpdateUserID"; }
    pub fn setUpdateUserID(self: *@This(), v: i32) void {
        self.@"UpdateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 26);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        self.@"UpdateIP" = v;
        zcode.entity.markDirty(&self.dirty, 27);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 28);
    }
    pub fn getRemark(self: @This()) []const u8 { return self.@"Remark"; }
    pub fn setRemark(self: *@This(), v: []const u8) void {
        self.@"Remark" = v;
        zcode.entity.markDirty(&self.dirty, 29);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"ID") },
            1 => .{ .text = self.@"Name" },
            2 => .{ .text = self.@"DisplayName" },
            3 => .{ .int = @intCast(self.@"Type") },
            4 => .{ .text = self.@"FullName" },
            5 => .{ .int = @intCast(self.@"ParentID") },
            6 => .{ .text = self.@"Url" },
            7 => .{ .int = @intCast(self.@"Sort") },
            8 => .{ .text = self.@"Icon" },
            9 => .{ .boolean = self.@"Visible" },
            10 => .{ .boolean = self.@"Necessary" },
            11 => .{ .boolean = self.@"NewWindow" },
            12 => .{ .int = @intCast(self.@"DataScope") },
            13 => .{ .text = self.@"DataDepartmentIds" },
            14 => .{ .text = self.@"Permission" },
            15 => .{ .int = @intCast(self.@"Ex1") },
            16 => .{ .int = @intCast(self.@"Ex2") },
            17 => .{ .float = self.@"Ex3" },
            18 => .{ .text = self.@"Ex4" },
            19 => .{ .text = self.@"Ex5" },
            20 => .{ .text = self.@"Ex6" },
            21 => .{ .text = self.@"CreateUser" },
            22 => .{ .int = @intCast(self.@"CreateUserID") },
            23 => .{ .text = self.@"CreateIP" },
            24 => .{ .datetime = self.@"CreateTime" },
            25 => .{ .text = self.@"UpdateUser" },
            26 => .{ .int = @intCast(self.@"UpdateUserID") },
            27 => .{ .text = self.@"UpdateIP" },
            28 => .{ .datetime = self.@"UpdateTime" },
            29 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"ID" = v.asI32() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            2 => { switch (v) { .text => |t| self.@"DisplayName" = t, .null => self.@"DisplayName" = "", else => {} } },
            3 => { self.@"Type" = v.asI32() orelse 0; },
            4 => { switch (v) { .text => |t| self.@"FullName" = t, .null => self.@"FullName" = "", else => {} } },
            5 => { self.@"ParentID" = v.asI32() orelse 0; },
            6 => { switch (v) { .text => |t| self.@"Url" = t, .null => self.@"Url" = "", else => {} } },
            7 => { self.@"Sort" = v.asI32() orelse 0; },
            8 => { switch (v) { .text => |t| self.@"Icon" = t, .null => self.@"Icon" = "", else => {} } },
            9 => { self.@"Visible" = v.asBool() orelse false; },
            10 => { self.@"Necessary" = v.asBool() orelse false; },
            11 => { self.@"NewWindow" = v.asBool() orelse false; },
            12 => { self.@"DataScope" = v.asI32() orelse 0; },
            13 => { switch (v) { .text => |t| self.@"DataDepartmentIds" = t, .null => self.@"DataDepartmentIds" = "", else => {} } },
            14 => { switch (v) { .text => |t| self.@"Permission" = t, .null => self.@"Permission" = "", else => {} } },
            15 => { self.@"Ex1" = v.asI32() orelse 0; },
            16 => { self.@"Ex2" = v.asI32() orelse 0; },
            17 => { self.@"Ex3" = v.asF64() orelse 0; },
            18 => { switch (v) { .text => |t| self.@"Ex4" = t, .null => self.@"Ex4" = "", else => {} } },
            19 => { switch (v) { .text => |t| self.@"Ex5" = t, .null => self.@"Ex5" = "", else => {} } },
            20 => { switch (v) { .text => |t| self.@"Ex6" = t, .null => self.@"Ex6" = "", else => {} } },
            21 => { switch (v) { .text => |t| self.@"CreateUser" = t, .null => self.@"CreateUser" = "", else => {} } },
            22 => { self.@"CreateUserID" = v.asI32() orelse 0; },
            23 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            24 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            25 => { switch (v) { .text => |t| self.@"UpdateUser" = t, .null => self.@"UpdateUser" = "", else => {} } },
            26 => { self.@"UpdateUserID" = v.asI32() orelse 0; },
            27 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            28 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            29 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
