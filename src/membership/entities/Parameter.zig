//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 字典参数。管理用户或系统全局的名值对数据，常用于参数配置场合
const zcode = @import("../../root.zig");

pub const Parameter = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"ID": i32 = 0,
    /// 用户。按用户区分参数，用户0表示系统级
    @"UserID": i32 = 0,
    /// 类别
    @"Category": []const u8 = "",
    /// 名称
    @"Name": []const u8 = "",
    /// 数值
    @"Value": []const u8 = "",
    /// 长数值
    @"LongValue": []const u8 = "",
    /// 种类。0普通，21列表，22名值
    @"Kind": i32 = 0,
    /// 启用
    @"Enable": bool = false,
    /// 扩展1
    @"Ex1": i32 = 0,
    /// 扩展2
    @"Ex2": zcode.Decimal = .{ .mantissa = 0, .scale = 0 },
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
        .name = "Parameter",
        .table_name = "Parameter",
        .fields = &.{
            .{ .name = "ID", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "UserID", .data_type = .int32, .description = "用户。按用户区分参数，用户0表示系统级" },
            .{ .name = "Category", .data_type = .string, .description = "类别" },
            .{ .name = "Name", .data_type = .string, .description = "名称" },
            .{ .name = "Value", .data_type = .string, .length = 200, .description = "数值" },
            .{ .name = "LongValue", .data_type = .string, .description = "长数值" },
            .{ .name = "Kind", .data_type = .int32, .description = "种类。0普通，21列表，22名值" },
            .{ .name = "Enable", .data_type = .boolean, .description = "启用" },
            .{ .name = "Ex1", .data_type = .int32, .description = "扩展1" },
            .{ .name = "Ex2", .data_type = .decimal, .precision = 19, .scale = 4, .description = "扩展2" },
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

    /// 列名常量（写 SQL / `Where` / `Field` 时引用这里）
    pub const Field = struct {
        pub const @"ID" = "ID";
        pub const @"UserID" = "UserID";
        pub const @"Category" = "Category";
        pub const @"Name" = "Name";
        pub const @"Value" = "Value";
        pub const @"LongValue" = "LongValue";
        pub const @"Kind" = "Kind";
        pub const @"Enable" = "Enable";
        pub const @"Ex1" = "Ex1";
        pub const @"Ex2" = "Ex2";
        pub const @"Ex3" = "Ex3";
        pub const @"Ex4" = "Ex4";
        pub const @"Ex5" = "Ex5";
        pub const @"Ex6" = "Ex6";
        pub const @"CreateUser" = "CreateUser";
        pub const @"CreateUserID" = "CreateUserID";
        pub const @"CreateIP" = "CreateIP";
        pub const @"CreateTime" = "CreateTime";
        pub const @"UpdateUser" = "UpdateUser";
        pub const @"UpdateUserID" = "UpdateUserID";
        pub const @"UpdateIP" = "UpdateIP";
        pub const @"UpdateTime" = "UpdateTime";
        pub const @"Remark" = "Remark";
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};
    /// 自增列下标（ID）
    pub const identity_index: usize = 0;

    /// 索引（对应 `Model.xml` 的 `Index`）
    pub const indexes = [_]zcode.codegen.IndexInfo{
        .{ .columns = &.{"UserID", "Category", "Name"}, .unique = true },
        .{ .columns = &.{"Category", "Name"}, .unique = false },
        .{ .columns = &.{"UpdateTime"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("Parameter");
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

    pub fn getID(self: @This()) i32 { return self.@"ID"; }
    pub fn setID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ID", v)) return;
        self.@"ID" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getUserID(self: @This()) i32 { return self.@"UserID"; }
    pub fn setUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"UserID", v)) return;
        self.@"UserID" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getCategory(self: @This()) []const u8 { return self.@"Category"; }
    pub fn setCategory(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Category", v)) return;
        self.@"Category" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getName(self: @This()) []const u8 { return self.@"Name"; }
    pub fn setName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Name", v)) return;
        self.@"Name" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getValue(self: @This()) []const u8 { return self.@"Value"; }
    pub fn setValue(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Value", v)) return;
        self.@"Value" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getLongValue(self: @This()) []const u8 { return self.@"LongValue"; }
    pub fn setLongValue(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"LongValue", v)) return;
        self.@"LongValue" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getKind(self: @This()) i32 { return self.@"Kind"; }
    pub fn setKind(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Kind", v)) return;
        self.@"Kind" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getEnable(self: @This()) bool { return self.@"Enable"; }
    pub fn setEnable(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Enable", v)) return;
        self.@"Enable" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getEx1(self: @This()) i32 { return self.@"Ex1"; }
    pub fn setEx1(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Ex1", v)) return;
        self.@"Ex1" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getEx2(self: @This()) zcode.Decimal { return self.@"Ex2"; }
    pub fn setEx2(self: *@This(), v: zcode.Decimal) void {
        if (zcode.entity.valueEql(self.@"Ex2", v)) return;
        self.@"Ex2" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getEx3(self: @This()) f64 { return self.@"Ex3"; }
    pub fn setEx3(self: *@This(), v: f64) void {
        if (zcode.entity.valueEql(self.@"Ex3", v)) return;
        self.@"Ex3" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getEx4(self: @This()) []const u8 { return self.@"Ex4"; }
    pub fn setEx4(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex4", v)) return;
        self.@"Ex4" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getEx5(self: @This()) []const u8 { return self.@"Ex5"; }
    pub fn setEx5(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex5", v)) return;
        self.@"Ex5" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getEx6(self: @This()) []const u8 { return self.@"Ex6"; }
    pub fn setEx6(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex6", v)) return;
        self.@"Ex6" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getCreateUser(self: @This()) []const u8 { return self.@"CreateUser"; }
    pub fn setCreateUser(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateUser", v)) return;
        self.@"CreateUser" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getCreateUserID(self: @This()) i32 { return self.@"CreateUserID"; }
    pub fn setCreateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"CreateUserID", v)) return;
        self.@"CreateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getCreateIP(self: @This()) []const u8 { return self.@"CreateIP"; }
    pub fn setCreateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateIP", v)) return;
        self.@"CreateIP" = v;
        zcode.entity.markDirty(&self.dirty, 16);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"CreateTime", v)) return;
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 17);
    }
    pub fn getUpdateUser(self: @This()) []const u8 { return self.@"UpdateUser"; }
    pub fn setUpdateUser(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateUser", v)) return;
        self.@"UpdateUser" = v;
        zcode.entity.markDirty(&self.dirty, 18);
    }
    pub fn getUpdateUserID(self: @This()) i32 { return self.@"UpdateUserID"; }
    pub fn setUpdateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"UpdateUserID", v)) return;
        self.@"UpdateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 19);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateIP", v)) return;
        self.@"UpdateIP" = v;
        zcode.entity.markDirty(&self.dirty, 20);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"UpdateTime", v)) return;
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 21);
    }
    pub fn getRemark(self: @This()) []const u8 { return self.@"Remark"; }
    pub fn setRemark(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Remark", v)) return;
        self.@"Remark" = v;
        zcode.entity.markDirty(&self.dirty, 22);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"ID") },
            1 => .{ .int = @intCast(self.@"UserID") },
            2 => .{ .text = self.@"Category" },
            3 => .{ .text = self.@"Name" },
            4 => .{ .text = self.@"Value" },
            5 => .{ .text = self.@"LongValue" },
            6 => .{ .int = @intCast(self.@"Kind") },
            7 => .{ .boolean = self.@"Enable" },
            8 => .{ .int = @intCast(self.@"Ex1") },
            9 => .{ .decimal = self.@"Ex2" },
            10 => .{ .float = self.@"Ex3" },
            11 => .{ .text = self.@"Ex4" },
            12 => .{ .text = self.@"Ex5" },
            13 => .{ .text = self.@"Ex6" },
            14 => .{ .text = self.@"CreateUser" },
            15 => .{ .int = @intCast(self.@"CreateUserID") },
            16 => .{ .text = self.@"CreateIP" },
            17 => .{ .datetime = self.@"CreateTime" },
            18 => .{ .text = self.@"UpdateUser" },
            19 => .{ .int = @intCast(self.@"UpdateUserID") },
            20 => .{ .text = self.@"UpdateIP" },
            21 => .{ .datetime = self.@"UpdateTime" },
            22 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"ID" = v.asI32() orelse 0; },
            1 => { self.@"UserID" = v.asI32() orelse 0; },
            2 => { switch (v) { .text => |t| self.@"Category" = t, .null => self.@"Category" = "", else => {} } },
            3 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            4 => { switch (v) { .text => |t| self.@"Value" = t, .null => self.@"Value" = "", else => {} } },
            5 => { switch (v) { .text => |t| self.@"LongValue" = t, .null => self.@"LongValue" = "", else => {} } },
            6 => { self.@"Kind" = v.asI32() orelse 0; },
            7 => { self.@"Enable" = v.asBool() orelse false; },
            8 => { self.@"Ex1" = v.asI32() orelse 0; },
            9 => { self.@"Ex2" = v.asDecimal() orelse .{ .mantissa = 0, .scale = 0 }; },
            10 => { self.@"Ex3" = v.asF64() orelse 0; },
            11 => { switch (v) { .text => |t| self.@"Ex4" = t, .null => self.@"Ex4" = "", else => {} } },
            12 => { switch (v) { .text => |t| self.@"Ex5" = t, .null => self.@"Ex5" = "", else => {} } },
            13 => { switch (v) { .text => |t| self.@"Ex6" = t, .null => self.@"Ex6" = "", else => {} } },
            14 => { switch (v) { .text => |t| self.@"CreateUser" = t, .null => self.@"CreateUser" = "", else => {} } },
            15 => { self.@"CreateUserID" = v.asI32() orelse 0; },
            16 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            17 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            18 => { switch (v) { .text => |t| self.@"UpdateUser" = t, .null => self.@"UpdateUser" = "", else => {} } },
            19 => { self.@"UpdateUserID" = v.asI32() orelse 0; },
            20 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            21 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            22 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
