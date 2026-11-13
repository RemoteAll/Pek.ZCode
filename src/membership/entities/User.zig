//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 用户。用户帐号信息，以身份验证为中心，拥有多种角色，可加入多个租户
const zcode = @import("../../root.zig");

pub const User = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"ID": i32 = 0,
    /// 名称。登录用户名
    @"Name": []const u8 = "",
    /// 密码
    @"Password": []const u8 = "",
    /// 昵称
    @"DisplayName": []const u8 = "",
    /// 性别。未知、男、女
    @"Sex": i32 = 0,
    /// 邮件。支持登录
    @"Mail": []const u8 = "",
    /// 邮箱验证。邮箱是否已通过验证
    @"MailVerified": bool = false,
    /// 手机。支持登录
    @"Mobile": []const u8 = "",
    /// 手机验证。手机是否已通过验证
    @"MobileVerified": bool = false,
    /// 代码。身份证、员工编码等，支持登录
    @"Code": []const u8 = "",
    /// 地区。省市区
    @"AreaId": i32 = 0,
    /// 头像
    @"Avatar": []const u8 = "",
    /// 角色。主要角色
    @"RoleID": i32 = 0,
    /// 角色组。次要角色集合
    @"RoleIds": []const u8 = "",
    /// 部门。组织机构
    @"DepartmentID": i32 = 0,
    /// 在线
    @"Online": bool = false,
    /// 启用
    @"Enable": bool = false,
    /// 年龄。周岁
    @"Age": i32 = 0,
    /// 生日。公历年月日
    @"Birthday": zcode.DateTime = .{},
    /// 登录次数
    @"Logins": i32 = 0,
    /// 最后登录
    @"LastLogin": zcode.DateTime = .{},
    /// 最后登录IP
    @"LastLoginIP": []const u8 = "",
    /// 注册时间
    @"RegisterTime": zcode.DateTime = .{},
    /// 注册IP
    @"RegisterIP": []const u8 = "",
    /// 在线时间。累计在线总时间，单位秒
    @"OnlineTime": i32 = 0,
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
        .name = "User",
        .table_name = "User",
        .fields = &.{
            .{ .name = "ID", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "Name", .data_type = .string, .description = "名称。登录用户名" },
            .{ .name = "Password", .data_type = .string, .length = 200, .description = "密码" },
            .{ .name = "DisplayName", .data_type = .string, .description = "昵称" },
            .{ .name = "Sex", .data_type = .int32, .description = "性别。未知、男、女" },
            .{ .name = "Mail", .data_type = .string, .description = "邮件。支持登录" },
            .{ .name = "MailVerified", .data_type = .boolean, .description = "邮箱验证。邮箱是否已通过验证" },
            .{ .name = "Mobile", .data_type = .string, .description = "手机。支持登录" },
            .{ .name = "MobileVerified", .data_type = .boolean, .description = "手机验证。手机是否已通过验证" },
            .{ .name = "Code", .data_type = .string, .description = "代码。身份证、员工编码等，支持登录" },
            .{ .name = "AreaId", .data_type = .int32, .description = "地区。省市区" },
            .{ .name = "Avatar", .data_type = .string, .length = 200, .description = "头像" },
            .{ .name = "RoleID", .data_type = .int32, .description = "角色。主要角色" },
            .{ .name = "RoleIds", .data_type = .string, .length = 200, .description = "角色组。次要角色集合" },
            .{ .name = "DepartmentID", .data_type = .int32, .description = "部门。组织机构" },
            .{ .name = "Online", .data_type = .boolean, .description = "在线" },
            .{ .name = "Enable", .data_type = .boolean, .description = "启用" },
            .{ .name = "Age", .data_type = .int32, .description = "年龄。周岁" },
            .{ .name = "Birthday", .data_type = .datetime, .description = "生日。公历年月日" },
            .{ .name = "Logins", .data_type = .int32, .description = "登录次数" },
            .{ .name = "LastLogin", .data_type = .datetime, .description = "最后登录" },
            .{ .name = "LastLoginIP", .data_type = .string, .description = "最后登录IP" },
            .{ .name = "RegisterTime", .data_type = .datetime, .description = "注册时间" },
            .{ .name = "RegisterIP", .data_type = .string, .description = "注册IP" },
            .{ .name = "OnlineTime", .data_type = .int32, .description = "在线时间。累计在线总时间，单位秒" },
            .{ .name = "Ex1", .data_type = .int32, .description = "扩展1" },
            .{ .name = "Ex2", .data_type = .int32, .description = "扩展2" },
            .{ .name = "Ex3", .data_type = .double, .description = "扩展3" },
            .{ .name = "Ex4", .data_type = .string, .description = "扩展4" },
            .{ .name = "Ex5", .data_type = .string, .description = "扩展5" },
            .{ .name = "Ex6", .data_type = .string, .description = "扩展6" },
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
        .{ .columns = &.{"Name"}, .unique = true },
        .{ .columns = &.{"Mail"}, .unique = false },
        .{ .columns = &.{"Mobile"}, .unique = false },
        .{ .columns = &.{"Code"}, .unique = false },
        .{ .columns = &.{"RoleID"}, .unique = false },
        .{ .columns = &.{"DepartmentID"}, .unique = false },
        .{ .columns = &.{"UpdateTime"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("User");
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
    pub fn getPassword(self: @This()) []const u8 { return self.@"Password"; }
    pub fn setPassword(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Password", v)) return;
        self.@"Password" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getDisplayName(self: @This()) []const u8 { return self.@"DisplayName"; }
    pub fn setDisplayName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"DisplayName", v)) return;
        self.@"DisplayName" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getSex(self: @This()) i32 { return self.@"Sex"; }
    pub fn setSex(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Sex", v)) return;
        self.@"Sex" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getMail(self: @This()) []const u8 { return self.@"Mail"; }
    pub fn setMail(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Mail", v)) return;
        self.@"Mail" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getMailVerified(self: @This()) bool { return self.@"MailVerified"; }
    pub fn setMailVerified(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"MailVerified", v)) return;
        self.@"MailVerified" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getMobile(self: @This()) []const u8 { return self.@"Mobile"; }
    pub fn setMobile(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Mobile", v)) return;
        self.@"Mobile" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getMobileVerified(self: @This()) bool { return self.@"MobileVerified"; }
    pub fn setMobileVerified(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"MobileVerified", v)) return;
        self.@"MobileVerified" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getCode(self: @This()) []const u8 { return self.@"Code"; }
    pub fn setCode(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Code", v)) return;
        self.@"Code" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getAreaId(self: @This()) i32 { return self.@"AreaId"; }
    pub fn setAreaId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"AreaId", v)) return;
        self.@"AreaId" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getAvatar(self: @This()) []const u8 { return self.@"Avatar"; }
    pub fn setAvatar(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Avatar", v)) return;
        self.@"Avatar" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getRoleID(self: @This()) i32 { return self.@"RoleID"; }
    pub fn setRoleID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"RoleID", v)) return;
        self.@"RoleID" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getRoleIds(self: @This()) []const u8 { return self.@"RoleIds"; }
    pub fn setRoleIds(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"RoleIds", v)) return;
        self.@"RoleIds" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getDepartmentID(self: @This()) i32 { return self.@"DepartmentID"; }
    pub fn setDepartmentID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"DepartmentID", v)) return;
        self.@"DepartmentID" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getOnline(self: @This()) bool { return self.@"Online"; }
    pub fn setOnline(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Online", v)) return;
        self.@"Online" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getEnable(self: @This()) bool { return self.@"Enable"; }
    pub fn setEnable(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Enable", v)) return;
        self.@"Enable" = v;
        zcode.entity.markDirty(&self.dirty, 16);
    }
    pub fn getAge(self: @This()) i32 { return self.@"Age"; }
    pub fn setAge(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Age", v)) return;
        self.@"Age" = v;
        zcode.entity.markDirty(&self.dirty, 17);
    }
    pub fn getBirthday(self: @This()) zcode.DateTime { return self.@"Birthday"; }
    pub fn setBirthday(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"Birthday", v)) return;
        self.@"Birthday" = v;
        zcode.entity.markDirty(&self.dirty, 18);
    }
    pub fn getLogins(self: @This()) i32 { return self.@"Logins"; }
    pub fn setLogins(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Logins", v)) return;
        self.@"Logins" = v;
        zcode.entity.markDirty(&self.dirty, 19);
    }
    pub fn getLastLogin(self: @This()) zcode.DateTime { return self.@"LastLogin"; }
    pub fn setLastLogin(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"LastLogin", v)) return;
        self.@"LastLogin" = v;
        zcode.entity.markDirty(&self.dirty, 20);
    }
    pub fn getLastLoginIP(self: @This()) []const u8 { return self.@"LastLoginIP"; }
    pub fn setLastLoginIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"LastLoginIP", v)) return;
        self.@"LastLoginIP" = v;
        zcode.entity.markDirty(&self.dirty, 21);
    }
    pub fn getRegisterTime(self: @This()) zcode.DateTime { return self.@"RegisterTime"; }
    pub fn setRegisterTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"RegisterTime", v)) return;
        self.@"RegisterTime" = v;
        zcode.entity.markDirty(&self.dirty, 22);
    }
    pub fn getRegisterIP(self: @This()) []const u8 { return self.@"RegisterIP"; }
    pub fn setRegisterIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"RegisterIP", v)) return;
        self.@"RegisterIP" = v;
        zcode.entity.markDirty(&self.dirty, 23);
    }
    pub fn getOnlineTime(self: @This()) i32 { return self.@"OnlineTime"; }
    pub fn setOnlineTime(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"OnlineTime", v)) return;
        self.@"OnlineTime" = v;
        zcode.entity.markDirty(&self.dirty, 24);
    }
    pub fn getEx1(self: @This()) i32 { return self.@"Ex1"; }
    pub fn setEx1(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Ex1", v)) return;
        self.@"Ex1" = v;
        zcode.entity.markDirty(&self.dirty, 25);
    }
    pub fn getEx2(self: @This()) i32 { return self.@"Ex2"; }
    pub fn setEx2(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Ex2", v)) return;
        self.@"Ex2" = v;
        zcode.entity.markDirty(&self.dirty, 26);
    }
    pub fn getEx3(self: @This()) f64 { return self.@"Ex3"; }
    pub fn setEx3(self: *@This(), v: f64) void {
        if (zcode.entity.valueEql(self.@"Ex3", v)) return;
        self.@"Ex3" = v;
        zcode.entity.markDirty(&self.dirty, 27);
    }
    pub fn getEx4(self: @This()) []const u8 { return self.@"Ex4"; }
    pub fn setEx4(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex4", v)) return;
        self.@"Ex4" = v;
        zcode.entity.markDirty(&self.dirty, 28);
    }
    pub fn getEx5(self: @This()) []const u8 { return self.@"Ex5"; }
    pub fn setEx5(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex5", v)) return;
        self.@"Ex5" = v;
        zcode.entity.markDirty(&self.dirty, 29);
    }
    pub fn getEx6(self: @This()) []const u8 { return self.@"Ex6"; }
    pub fn setEx6(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex6", v)) return;
        self.@"Ex6" = v;
        zcode.entity.markDirty(&self.dirty, 30);
    }
    pub fn getUpdateUser(self: @This()) []const u8 { return self.@"UpdateUser"; }
    pub fn setUpdateUser(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateUser", v)) return;
        self.@"UpdateUser" = v;
        zcode.entity.markDirty(&self.dirty, 31);
    }
    pub fn getUpdateUserID(self: @This()) i32 { return self.@"UpdateUserID"; }
    pub fn setUpdateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"UpdateUserID", v)) return;
        self.@"UpdateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 32);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateIP", v)) return;
        self.@"UpdateIP" = v;
        zcode.entity.markDirty(&self.dirty, 33);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"UpdateTime", v)) return;
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 34);
    }
    pub fn getRemark(self: @This()) []const u8 { return self.@"Remark"; }
    pub fn setRemark(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Remark", v)) return;
        self.@"Remark" = v;
        zcode.entity.markDirty(&self.dirty, 35);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"ID") },
            1 => .{ .text = self.@"Name" },
            2 => .{ .text = self.@"Password" },
            3 => .{ .text = self.@"DisplayName" },
            4 => .{ .int = @intCast(self.@"Sex") },
            5 => .{ .text = self.@"Mail" },
            6 => .{ .boolean = self.@"MailVerified" },
            7 => .{ .text = self.@"Mobile" },
            8 => .{ .boolean = self.@"MobileVerified" },
            9 => .{ .text = self.@"Code" },
            10 => .{ .int = @intCast(self.@"AreaId") },
            11 => .{ .text = self.@"Avatar" },
            12 => .{ .int = @intCast(self.@"RoleID") },
            13 => .{ .text = self.@"RoleIds" },
            14 => .{ .int = @intCast(self.@"DepartmentID") },
            15 => .{ .boolean = self.@"Online" },
            16 => .{ .boolean = self.@"Enable" },
            17 => .{ .int = @intCast(self.@"Age") },
            18 => .{ .datetime = self.@"Birthday" },
            19 => .{ .int = @intCast(self.@"Logins") },
            20 => .{ .datetime = self.@"LastLogin" },
            21 => .{ .text = self.@"LastLoginIP" },
            22 => .{ .datetime = self.@"RegisterTime" },
            23 => .{ .text = self.@"RegisterIP" },
            24 => .{ .int = @intCast(self.@"OnlineTime") },
            25 => .{ .int = @intCast(self.@"Ex1") },
            26 => .{ .int = @intCast(self.@"Ex2") },
            27 => .{ .float = self.@"Ex3" },
            28 => .{ .text = self.@"Ex4" },
            29 => .{ .text = self.@"Ex5" },
            30 => .{ .text = self.@"Ex6" },
            31 => .{ .text = self.@"UpdateUser" },
            32 => .{ .int = @intCast(self.@"UpdateUserID") },
            33 => .{ .text = self.@"UpdateIP" },
            34 => .{ .datetime = self.@"UpdateTime" },
            35 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"ID" = v.asI32() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            2 => { switch (v) { .text => |t| self.@"Password" = t, .null => self.@"Password" = "", else => {} } },
            3 => { switch (v) { .text => |t| self.@"DisplayName" = t, .null => self.@"DisplayName" = "", else => {} } },
            4 => { self.@"Sex" = v.asI32() orelse 0; },
            5 => { switch (v) { .text => |t| self.@"Mail" = t, .null => self.@"Mail" = "", else => {} } },
            6 => { self.@"MailVerified" = v.asBool() orelse false; },
            7 => { switch (v) { .text => |t| self.@"Mobile" = t, .null => self.@"Mobile" = "", else => {} } },
            8 => { self.@"MobileVerified" = v.asBool() orelse false; },
            9 => { switch (v) { .text => |t| self.@"Code" = t, .null => self.@"Code" = "", else => {} } },
            10 => { self.@"AreaId" = v.asI32() orelse 0; },
            11 => { switch (v) { .text => |t| self.@"Avatar" = t, .null => self.@"Avatar" = "", else => {} } },
            12 => { self.@"RoleID" = v.asI32() orelse 0; },
            13 => { switch (v) { .text => |t| self.@"RoleIds" = t, .null => self.@"RoleIds" = "", else => {} } },
            14 => { self.@"DepartmentID" = v.asI32() orelse 0; },
            15 => { self.@"Online" = v.asBool() orelse false; },
            16 => { self.@"Enable" = v.asBool() orelse false; },
            17 => { self.@"Age" = v.asI32() orelse 0; },
            18 => { self.@"Birthday" = v.asDatetime() orelse .{}; },
            19 => { self.@"Logins" = v.asI32() orelse 0; },
            20 => { self.@"LastLogin" = v.asDatetime() orelse .{}; },
            21 => { switch (v) { .text => |t| self.@"LastLoginIP" = t, .null => self.@"LastLoginIP" = "", else => {} } },
            22 => { self.@"RegisterTime" = v.asDatetime() orelse .{}; },
            23 => { switch (v) { .text => |t| self.@"RegisterIP" = t, .null => self.@"RegisterIP" = "", else => {} } },
            24 => { self.@"OnlineTime" = v.asI32() orelse 0; },
            25 => { self.@"Ex1" = v.asI32() orelse 0; },
            26 => { self.@"Ex2" = v.asI32() orelse 0; },
            27 => { self.@"Ex3" = v.asF64() orelse 0; },
            28 => { switch (v) { .text => |t| self.@"Ex4" = t, .null => self.@"Ex4" = "", else => {} } },
            29 => { switch (v) { .text => |t| self.@"Ex5" = t, .null => self.@"Ex5" = "", else => {} } },
            30 => { switch (v) { .text => |t| self.@"Ex6" = t, .null => self.@"Ex6" = "", else => {} } },
            31 => { switch (v) { .text => |t| self.@"UpdateUser" = t, .null => self.@"UpdateUser" = "", else => {} } },
            32 => { self.@"UpdateUserID" = v.asI32() orelse 0; },
            33 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            34 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            35 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
