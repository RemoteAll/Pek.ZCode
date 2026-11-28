//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 定时作业。定时执行任务
const zcode = @import("../../root.zig");

pub const CronJob = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"ID": i32 = 0,
    /// 名称
    @"Name": []const u8 = "",
    /// 显示名
    @"DisplayName": []const u8 = "",
    /// Cron表达式。用于定时执行的Cron表达式
    @"Cron": []const u8 = "",
    /// 命令。ICubeJob类名或静态方法全名(包含一个String参数)
    @"Method": []const u8 = "",
    /// 参数。方法参数，时间日期、网址、SQL等
    @"Argument": []const u8 = "",
    /// 数据。作业运行中的小量数据，可传递给下一次作业执行，例如记录数据统计的时间点
    @"Data": []const u8 = "",
    /// 启用
    @"Enable": bool = false,
    /// 启用日志
    @"EnableLog": bool = false,
    /// 最后时间。最后一次执行作业的时间
    @"LastTime": zcode.DateTime = .{},
    /// 下一次时间。下一次执行作业的时间
    @"NextTime": zcode.DateTime = .{},
    /// 创建者
    @"CreateUserID": i32 = 0,
    /// 创建时间
    @"CreateTime": zcode.DateTime = .{},
    /// 创建地址
    @"CreateIP": []const u8 = "",
    /// 更新者
    @"UpdateUserID": i32 = 0,
    /// 更新时间
    @"UpdateTime": zcode.DateTime = .{},
    /// 更新地址
    @"UpdateIP": []const u8 = "",
    /// 内容
    @"Remark": []const u8 = "",

    pub const meta = zcode.entity.checkMeta(zcode.entity.EntityMeta{
        .name = "CronJob",
        .table_name = "CronJob",
        .fields = &.{
            .{ .name = "ID", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "Name", .data_type = .string, .length = 50, .description = "名称" },
            .{ .name = "DisplayName", .data_type = .string, .nullable = true, .length = 50, .description = "显示名" },
            .{ .name = "Cron", .data_type = .string, .nullable = true, .length = 50, .description = "Cron表达式。用于定时执行的Cron表达式" },
            .{ .name = "Method", .data_type = .string, .nullable = true, .length = 200, .description = "命令。ICubeJob类名或静态方法全名(包含一个String参数)" },
            .{ .name = "Argument", .data_type = .string, .nullable = true, .description = "参数。方法参数，时间日期、网址、SQL等" },
            .{ .name = "Data", .data_type = .string, .nullable = true, .description = "数据。作业运行中的小量数据，可传递给下一次作业执行，例如记录数据统计的时间点" },
            .{ .name = "Enable", .data_type = .boolean, .description = "启用" },
            .{ .name = "EnableLog", .data_type = .boolean, .description = "启用日志" },
            .{ .name = "LastTime", .data_type = .datetime, .nullable = true, .description = "最后时间。最后一次执行作业的时间" },
            .{ .name = "NextTime", .data_type = .datetime, .nullable = true, .description = "下一次时间。下一次执行作业的时间" },
            .{ .name = "CreateUserID", .data_type = .int32, .description = "创建者" },
            .{ .name = "CreateTime", .data_type = .datetime, .nullable = true, .description = "创建时间" },
            .{ .name = "CreateIP", .data_type = .string, .nullable = true, .description = "创建地址" },
            .{ .name = "UpdateUserID", .data_type = .int32, .description = "更新者" },
            .{ .name = "UpdateTime", .data_type = .datetime, .nullable = true, .description = "更新时间" },
            .{ .name = "UpdateIP", .data_type = .string, .nullable = true, .description = "更新地址" },
            .{ .name = "Remark", .data_type = .string, .nullable = true, .length = 500, .description = "内容" },
        },
    });

    /// 列名常量（写 SQL / `Where` / `Field` 时引用这里）
    pub const Field = struct {
        pub const @"ID" = "ID";
        pub const @"Name" = "Name";
        pub const @"DisplayName" = "DisplayName";
        pub const @"Cron" = "Cron";
        pub const @"Method" = "Method";
        pub const @"Argument" = "Argument";
        pub const @"Data" = "Data";
        pub const @"Enable" = "Enable";
        pub const @"EnableLog" = "EnableLog";
        pub const @"LastTime" = "LastTime";
        pub const @"NextTime" = "NextTime";
        pub const @"CreateUserID" = "CreateUserID";
        pub const @"CreateTime" = "CreateTime";
        pub const @"CreateIP" = "CreateIP";
        pub const @"UpdateUserID" = "UpdateUserID";
        pub const @"UpdateTime" = "UpdateTime";
        pub const @"UpdateIP" = "UpdateIP";
        pub const @"Remark" = "Remark";
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};
    /// 自增列下标（ID）
    pub const identity_index: usize = 0;

    /// 索引（对应 `Model.xml` 的 `Index`）
    pub const indexes = [_]zcode.codegen.IndexInfo{
        .{ .columns = &.{"Name"}, .unique = true },
        .{ .columns = &.{"NextTime"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("CronJob");
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
    pub fn getName(self: @This()) []const u8 { return self.@"Name"; }
    pub fn setName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Name", v)) return;
        self.@"Name" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getDisplayName(self: @This()) []const u8 { return self.@"DisplayName"; }
    pub fn setDisplayName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"DisplayName", v)) return;
        self.@"DisplayName" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getCron(self: @This()) []const u8 { return self.@"Cron"; }
    pub fn setCron(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Cron", v)) return;
        self.@"Cron" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getMethod(self: @This()) []const u8 { return self.@"Method"; }
    pub fn setMethod(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Method", v)) return;
        self.@"Method" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getArgument(self: @This()) []const u8 { return self.@"Argument"; }
    pub fn setArgument(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Argument", v)) return;
        self.@"Argument" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getData(self: @This()) []const u8 { return self.@"Data"; }
    pub fn setData(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Data", v)) return;
        self.@"Data" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getEnable(self: @This()) bool { return self.@"Enable"; }
    pub fn setEnable(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Enable", v)) return;
        self.@"Enable" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getEnableLog(self: @This()) bool { return self.@"EnableLog"; }
    pub fn setEnableLog(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"EnableLog", v)) return;
        self.@"EnableLog" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getLastTime(self: @This()) zcode.DateTime { return self.@"LastTime"; }
    pub fn setLastTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"LastTime", v)) return;
        self.@"LastTime" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getNextTime(self: @This()) zcode.DateTime { return self.@"NextTime"; }
    pub fn setNextTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"NextTime", v)) return;
        self.@"NextTime" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getCreateUserID(self: @This()) i32 { return self.@"CreateUserID"; }
    pub fn setCreateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"CreateUserID", v)) return;
        self.@"CreateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"CreateTime", v)) return;
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getCreateIP(self: @This()) []const u8 { return self.@"CreateIP"; }
    pub fn setCreateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateIP", v)) return;
        self.@"CreateIP" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getUpdateUserID(self: @This()) i32 { return self.@"UpdateUserID"; }
    pub fn setUpdateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"UpdateUserID", v)) return;
        self.@"UpdateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"UpdateTime", v)) return;
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateIP", v)) return;
        self.@"UpdateIP" = v;
        zcode.entity.markDirty(&self.dirty, 16);
    }
    pub fn getRemark(self: @This()) []const u8 { return self.@"Remark"; }
    pub fn setRemark(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Remark", v)) return;
        self.@"Remark" = v;
        zcode.entity.markDirty(&self.dirty, 17);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"ID") },
            1 => .{ .text = self.@"Name" },
            2 => .{ .text = self.@"DisplayName" },
            3 => .{ .text = self.@"Cron" },
            4 => .{ .text = self.@"Method" },
            5 => .{ .text = self.@"Argument" },
            6 => .{ .text = self.@"Data" },
            7 => .{ .boolean = self.@"Enable" },
            8 => .{ .boolean = self.@"EnableLog" },
            9 => .{ .datetime = self.@"LastTime" },
            10 => .{ .datetime = self.@"NextTime" },
            11 => .{ .int = @intCast(self.@"CreateUserID") },
            12 => .{ .datetime = self.@"CreateTime" },
            13 => .{ .text = self.@"CreateIP" },
            14 => .{ .int = @intCast(self.@"UpdateUserID") },
            15 => .{ .datetime = self.@"UpdateTime" },
            16 => .{ .text = self.@"UpdateIP" },
            17 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"ID" = v.asI32() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            2 => { switch (v) { .text => |t| self.@"DisplayName" = t, .null => self.@"DisplayName" = "", else => {} } },
            3 => { switch (v) { .text => |t| self.@"Cron" = t, .null => self.@"Cron" = "", else => {} } },
            4 => { switch (v) { .text => |t| self.@"Method" = t, .null => self.@"Method" = "", else => {} } },
            5 => { switch (v) { .text => |t| self.@"Argument" = t, .null => self.@"Argument" = "", else => {} } },
            6 => { switch (v) { .text => |t| self.@"Data" = t, .null => self.@"Data" = "", else => {} } },
            7 => { self.@"Enable" = v.asBool() orelse false; },
            8 => { self.@"EnableLog" = v.asBool() orelse false; },
            9 => { self.@"LastTime" = v.asDatetime() orelse .{}; },
            10 => { self.@"NextTime" = v.asDatetime() orelse .{}; },
            11 => { self.@"CreateUserID" = v.asI32() orelse 0; },
            12 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            13 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            14 => { self.@"UpdateUserID" = v.asI32() orelse 0; },
            15 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            16 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            17 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
