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
    /// 类型。1免费/2个人/3企业/4旗舰
    @"Type": i32 = 0,
    /// 启用
    @"Enable": bool = false,
    /// 等级。租户级别或套餐版本，数字越大功能越多
    @"Level": i32 = 0,
    /// 管理者
    @"ManagerId": i32 = 0,
    /// 角色组。租户可选的角色集合，不同级别的租户所拥有的角色不一样，高级功能也会不同
    @"RoleIds": []const u8 = "",
    /// 图标。附件路径
    @"Logo": []const u8 = "",
    /// 域名。绑定的独立域名
    @"Domain": []const u8 = "",
    /// 用户数上限。该租户最大允许用户数，0表示不限制
    @"MaxUsers": i32 = 0,
    /// 存储上限。该租户最大允许存储字节数，0表示不限制
    @"MaxStorage": i64 = 0,
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
            .{ .name = "Type", .data_type = .int32, .description = "类型。1免费/2个人/3企业/4旗舰" },
            .{ .name = "Enable", .data_type = .boolean, .description = "启用" },
            .{ .name = "Level", .data_type = .int32, .description = "等级。租户级别或套餐版本，数字越大功能越多" },
            .{ .name = "ManagerId", .data_type = .int32, .description = "管理者" },
            .{ .name = "RoleIds", .data_type = .string, .length = 200, .description = "角色组。租户可选的角色集合，不同级别的租户所拥有的角色不一样，高级功能也会不同" },
            .{ .name = "Logo", .data_type = .string, .description = "图标。附件路径" },
            .{ .name = "Domain", .data_type = .string, .length = 200, .description = "域名。绑定的独立域名" },
            .{ .name = "MaxUsers", .data_type = .int32, .description = "用户数上限。该租户最大允许用户数，0表示不限制" },
            .{ .name = "MaxStorage", .data_type = .int64, .description = "存储上限。该租户最大允许存储字节数，0表示不限制" },
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

    /// 列名常量（写 SQL / `Where` / `Field` 时引用这里）
    pub const Field = struct {
        pub const @"Id" = "Id";
        pub const @"Code" = "Code";
        pub const @"Name" = "Name";
        pub const @"Type" = "Type";
        pub const @"Enable" = "Enable";
        pub const @"Level" = "Level";
        pub const @"ManagerId" = "ManagerId";
        pub const @"RoleIds" = "RoleIds";
        pub const @"Logo" = "Logo";
        pub const @"Domain" = "Domain";
        pub const @"MaxUsers" = "MaxUsers";
        pub const @"MaxStorage" = "MaxStorage";
        pub const @"DatabaseName" = "DatabaseName";
        pub const @"TableName" = "TableName";
        pub const @"Expired" = "Expired";
        pub const @"CreateUserId" = "CreateUserId";
        pub const @"CreateTime" = "CreateTime";
        pub const @"CreateIP" = "CreateIP";
        pub const @"UpdateUserId" = "UpdateUserId";
        pub const @"UpdateTime" = "UpdateTime";
        pub const @"UpdateIP" = "UpdateIP";
        pub const @"Remark" = "Remark";
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

    /// 模型 `MaxCacheCount`（0 = 不参与整表缓存）
    pub const max_cache_count: i32 = 1000;

    /// 插入一行（自增 ID 回写到自身）。
    pub fn insert(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !i64 {
        return zcode.entity.insert(dal, self, s);
    }

    /// 只更新脏列（无脏列不发 SQL）。
    pub fn update(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !usize {
        return zcode.entity.update(dal, self, s);
    }

    /// 按主键删除。
    pub fn delete(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !usize {
        return zcode.entity.delete(dal, self, s);
    }

    /// 保存：主键空则插入，否则更新（对齐 XCode `Save`）。
    pub fn save(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !i64 {
        return zcode.entity.save(dal, self, s);
    }

    /// 按主键值取一行（支持复合主键：按 `meta.fields` 中主键顺序传值）。
    pub fn findByKey(dal: *zcode.Dal, s: *zcode.Session, pk_values: []const zcode.Value) !?@This() {
        return zcode.entity.findByPk(dal, @This(), s, pk_values);
    }

    /// 按主键取一行（单主键便利版）。
    pub fn findByPk(dal: *zcode.Dal, s: *zcode.Session, pk: i64) !?@This() {
        return zcode.entity.findByPk(dal, @This(), s, &.{.{ .int = pk }});
    }

    /// 条件查询（分页/排序/列选择同 `Query`）。
    pub fn query(dal: *zcode.Dal, s: *zcode.Session, q: *const zcode.Query) ![]@This() {
        return zcode.entity.queryRows(dal, @This(), s, q);
    }

    /// 计数。
    pub fn count(dal: *zcode.Dal, s: *zcode.Session, filter: ?*const zcode.Where) !i64 {
        return zcode.entity.count(dal, @This(), s, filter);
    }

    /// 整表缓存：小表常驻，配词查询不再打库；行数超过 `max_cache_count` 时自动退回查库。
    pub fn cache(dal: *zcode.Dal) zcode.cache.Cache(@This()) {
        return zcode.cache.Cache(@This()).init(dal, zcode.setting.current().entity_cache_expire);
    }

    /// 单对象缓存：大表按主键取，只缓存访问过的行。
    pub fn singleCache(dal: *zcode.Dal) zcode.cache.SingleCache(@This()) {
        return zcode.cache.SingleCache(@This()).init(dal, zcode.setting.current().single_cache_expire);
    }

    /// 必填校验：返回第一个为空的非空字符列名，全通过返回 null。
    pub fn valid(self: *const @This()) ?[]const u8 {
        return zcode.entity_ext.checkRequired(self);
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
    pub fn getType(self: @This()) i32 { return self.@"Type"; }
    pub fn setType(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Type", v)) return;
        self.@"Type" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getEnable(self: @This()) bool { return self.@"Enable"; }
    pub fn setEnable(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Enable", v)) return;
        self.@"Enable" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getLevel(self: @This()) i32 { return self.@"Level"; }
    pub fn setLevel(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Level", v)) return;
        self.@"Level" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getManagerId(self: @This()) i32 { return self.@"ManagerId"; }
    pub fn setManagerId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ManagerId", v)) return;
        self.@"ManagerId" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getRoleIds(self: @This()) []const u8 { return self.@"RoleIds"; }
    pub fn setRoleIds(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"RoleIds", v)) return;
        self.@"RoleIds" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getLogo(self: @This()) []const u8 { return self.@"Logo"; }
    pub fn setLogo(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Logo", v)) return;
        self.@"Logo" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getDomain(self: @This()) []const u8 { return self.@"Domain"; }
    pub fn setDomain(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Domain", v)) return;
        self.@"Domain" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getMaxUsers(self: @This()) i32 { return self.@"MaxUsers"; }
    pub fn setMaxUsers(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"MaxUsers", v)) return;
        self.@"MaxUsers" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getMaxStorage(self: @This()) i64 { return self.@"MaxStorage"; }
    pub fn setMaxStorage(self: *@This(), v: i64) void {
        if (zcode.entity.valueEql(self.@"MaxStorage", v)) return;
        self.@"MaxStorage" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getDatabaseName(self: @This()) []const u8 { return self.@"DatabaseName"; }
    pub fn setDatabaseName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"DatabaseName", v)) return;
        self.@"DatabaseName" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getTableName(self: @This()) []const u8 { return self.@"TableName"; }
    pub fn setTableName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"TableName", v)) return;
        self.@"TableName" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getExpired(self: @This()) zcode.DateTime { return self.@"Expired"; }
    pub fn setExpired(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"Expired", v)) return;
        self.@"Expired" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getCreateUserId(self: @This()) i32 { return self.@"CreateUserId"; }
    pub fn setCreateUserId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"CreateUserId", v)) return;
        self.@"CreateUserId" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"CreateTime", v)) return;
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 16);
    }
    pub fn getCreateIP(self: @This()) []const u8 { return self.@"CreateIP"; }
    pub fn setCreateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateIP", v)) return;
        self.@"CreateIP" = v;
        zcode.entity.markDirty(&self.dirty, 17);
    }
    pub fn getUpdateUserId(self: @This()) i32 { return self.@"UpdateUserId"; }
    pub fn setUpdateUserId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"UpdateUserId", v)) return;
        self.@"UpdateUserId" = v;
        zcode.entity.markDirty(&self.dirty, 18);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"UpdateTime", v)) return;
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 19);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateIP", v)) return;
        self.@"UpdateIP" = v;
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
            0 => .{ .int = @intCast(self.@"Id") },
            1 => .{ .text = self.@"Code" },
            2 => .{ .text = self.@"Name" },
            3 => .{ .int = @intCast(self.@"Type") },
            4 => .{ .boolean = self.@"Enable" },
            5 => .{ .int = @intCast(self.@"Level") },
            6 => .{ .int = @intCast(self.@"ManagerId") },
            7 => .{ .text = self.@"RoleIds" },
            8 => .{ .text = self.@"Logo" },
            9 => .{ .text = self.@"Domain" },
            10 => .{ .int = @intCast(self.@"MaxUsers") },
            11 => .{ .int = @intCast(self.@"MaxStorage") },
            12 => .{ .text = self.@"DatabaseName" },
            13 => .{ .text = self.@"TableName" },
            14 => .{ .datetime = self.@"Expired" },
            15 => .{ .int = @intCast(self.@"CreateUserId") },
            16 => .{ .datetime = self.@"CreateTime" },
            17 => .{ .text = self.@"CreateIP" },
            18 => .{ .int = @intCast(self.@"UpdateUserId") },
            19 => .{ .datetime = self.@"UpdateTime" },
            20 => .{ .text = self.@"UpdateIP" },
            21 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"Id" = v.asI32() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Code" = t, .null => self.@"Code" = "", else => {} } },
            2 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            3 => { self.@"Type" = v.asI32() orelse 0; },
            4 => { self.@"Enable" = v.asBool() orelse false; },
            5 => { self.@"Level" = v.asI32() orelse 0; },
            6 => { self.@"ManagerId" = v.asI32() orelse 0; },
            7 => { switch (v) { .text => |t| self.@"RoleIds" = t, .null => self.@"RoleIds" = "", else => {} } },
            8 => { switch (v) { .text => |t| self.@"Logo" = t, .null => self.@"Logo" = "", else => {} } },
            9 => { switch (v) { .text => |t| self.@"Domain" = t, .null => self.@"Domain" = "", else => {} } },
            10 => { self.@"MaxUsers" = v.asI32() orelse 0; },
            11 => { self.@"MaxStorage" = v.asI64() orelse 0; },
            12 => { switch (v) { .text => |t| self.@"DatabaseName" = t, .null => self.@"DatabaseName" = "", else => {} } },
            13 => { switch (v) { .text => |t| self.@"TableName" = t, .null => self.@"TableName" = "", else => {} } },
            14 => { self.@"Expired" = v.asDatetime() orelse .{}; },
            15 => { self.@"CreateUserId" = v.asI32() orelse 0; },
            16 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            17 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            18 => { self.@"UpdateUserId" = v.asI32() orelse 0; },
            19 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            20 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            21 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
