//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 地区。行政区划数据，最高支持四级地址，9位数字
const zcode = @import("../../root.zig");

pub const Area = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编码。行政区划编码
    @"ID": i32 = 0,
    /// 名称
    @"Name": []const u8 = "",
    /// 全名
    @"FullName": []const u8 = "",
    /// 父级
    @"ParentID": i32 = 0,
    /// 层级
    @"Level": i32 = 0,
    /// 类型。省市县，自治州等
    @"Kind": []const u8 = "",
    /// 英文名
    @"English": []const u8 = "",
    /// 拼音
    @"PinYin": []const u8 = "",
    /// 简拼
    @"JianPin": []const u8 = "",
    /// 区号。电话区号
    @"TelCode": []const u8 = "",
    /// 邮编。邮政编码
    @"ZipCode": []const u8 = "",
    /// 经度
    @"Longitude": f64 = 0,
    /// 纬度
    @"Latitude": f64 = 0,
    /// 地址编码。字符串前缀相同越多，地理距离越近，8位精度19米，6位610米
    @"GeoHash": []const u8 = "",
    /// 启用
    @"Enable": bool = false,
    /// 创建时间
    @"CreateTime": zcode.DateTime = .{},
    /// 更新时间
    @"UpdateTime": zcode.DateTime = .{},
    /// 备注
    @"Remark": []const u8 = "",

    pub const meta = zcode.entity.EntityMeta{
        .name = "Area",
        .table_name = "Area",
        .fields = &.{
            .{ .name = "ID", .data_type = .int32, .primary_key = true, .description = "编码。行政区划编码" },
            .{ .name = "Name", .data_type = .string, .description = "名称" },
            .{ .name = "FullName", .data_type = .string, .description = "全名" },
            .{ .name = "ParentID", .data_type = .int32, .description = "父级" },
            .{ .name = "Level", .data_type = .int32, .description = "层级" },
            .{ .name = "Kind", .data_type = .string, .description = "类型。省市县，自治州等" },
            .{ .name = "English", .data_type = .string, .description = "英文名" },
            .{ .name = "PinYin", .data_type = .string, .description = "拼音" },
            .{ .name = "JianPin", .data_type = .string, .description = "简拼" },
            .{ .name = "TelCode", .data_type = .string, .description = "区号。电话区号" },
            .{ .name = "ZipCode", .data_type = .string, .description = "邮编。邮政编码" },
            .{ .name = "Longitude", .data_type = .double, .description = "经度" },
            .{ .name = "Latitude", .data_type = .double, .description = "纬度" },
            .{ .name = "GeoHash", .data_type = .string, .description = "地址编码。字符串前缀相同越多，地理距离越近，8位精度19米，6位610米" },
            .{ .name = "Enable", .data_type = .boolean, .description = "启用" },
            .{ .name = "CreateTime", .data_type = .datetime, .description = "创建时间" },
            .{ .name = "UpdateTime", .data_type = .datetime, .description = "更新时间" },
            .{ .name = "Remark", .data_type = .string, .length = 500, .description = "备注" },
        },
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};

    /// 索引（对应 `Model.xml` 的 `Index`）
    pub const indexes = [_]zcode.codegen.IndexInfo{
        .{ .columns = &.{"ParentID"}, .unique = false },
        .{ .columns = &.{"Name"}, .unique = false },
        .{ .columns = &.{"PinYin"}, .unique = false },
        .{ .columns = &.{"JianPin"}, .unique = false },
        .{ .columns = &.{"GeoHash"}, .unique = false },
        .{ .columns = &.{"UpdateTime", "ID"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("Area");
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
    pub fn getFullName(self: @This()) []const u8 { return self.@"FullName"; }
    pub fn setFullName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"FullName", v)) return;
        self.@"FullName" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getParentID(self: @This()) i32 { return self.@"ParentID"; }
    pub fn setParentID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ParentID", v)) return;
        self.@"ParentID" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getLevel(self: @This()) i32 { return self.@"Level"; }
    pub fn setLevel(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Level", v)) return;
        self.@"Level" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getKind(self: @This()) []const u8 { return self.@"Kind"; }
    pub fn setKind(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Kind", v)) return;
        self.@"Kind" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getEnglish(self: @This()) []const u8 { return self.@"English"; }
    pub fn setEnglish(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"English", v)) return;
        self.@"English" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getPinYin(self: @This()) []const u8 { return self.@"PinYin"; }
    pub fn setPinYin(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"PinYin", v)) return;
        self.@"PinYin" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getJianPin(self: @This()) []const u8 { return self.@"JianPin"; }
    pub fn setJianPin(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"JianPin", v)) return;
        self.@"JianPin" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getTelCode(self: @This()) []const u8 { return self.@"TelCode"; }
    pub fn setTelCode(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"TelCode", v)) return;
        self.@"TelCode" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getZipCode(self: @This()) []const u8 { return self.@"ZipCode"; }
    pub fn setZipCode(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"ZipCode", v)) return;
        self.@"ZipCode" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getLongitude(self: @This()) f64 { return self.@"Longitude"; }
    pub fn setLongitude(self: *@This(), v: f64) void {
        if (zcode.entity.valueEql(self.@"Longitude", v)) return;
        self.@"Longitude" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getLatitude(self: @This()) f64 { return self.@"Latitude"; }
    pub fn setLatitude(self: *@This(), v: f64) void {
        if (zcode.entity.valueEql(self.@"Latitude", v)) return;
        self.@"Latitude" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getGeoHash(self: @This()) []const u8 { return self.@"GeoHash"; }
    pub fn setGeoHash(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"GeoHash", v)) return;
        self.@"GeoHash" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getEnable(self: @This()) bool { return self.@"Enable"; }
    pub fn setEnable(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Enable", v)) return;
        self.@"Enable" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"CreateTime", v)) return;
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"UpdateTime", v)) return;
        self.@"UpdateTime" = v;
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
            2 => .{ .text = self.@"FullName" },
            3 => .{ .int = @intCast(self.@"ParentID") },
            4 => .{ .int = @intCast(self.@"Level") },
            5 => .{ .text = self.@"Kind" },
            6 => .{ .text = self.@"English" },
            7 => .{ .text = self.@"PinYin" },
            8 => .{ .text = self.@"JianPin" },
            9 => .{ .text = self.@"TelCode" },
            10 => .{ .text = self.@"ZipCode" },
            11 => .{ .float = self.@"Longitude" },
            12 => .{ .float = self.@"Latitude" },
            13 => .{ .text = self.@"GeoHash" },
            14 => .{ .boolean = self.@"Enable" },
            15 => .{ .datetime = self.@"CreateTime" },
            16 => .{ .datetime = self.@"UpdateTime" },
            17 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"ID" = v.asI32() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            2 => { switch (v) { .text => |t| self.@"FullName" = t, .null => self.@"FullName" = "", else => {} } },
            3 => { self.@"ParentID" = v.asI32() orelse 0; },
            4 => { self.@"Level" = v.asI32() orelse 0; },
            5 => { switch (v) { .text => |t| self.@"Kind" = t, .null => self.@"Kind" = "", else => {} } },
            6 => { switch (v) { .text => |t| self.@"English" = t, .null => self.@"English" = "", else => {} } },
            7 => { switch (v) { .text => |t| self.@"PinYin" = t, .null => self.@"PinYin" = "", else => {} } },
            8 => { switch (v) { .text => |t| self.@"JianPin" = t, .null => self.@"JianPin" = "", else => {} } },
            9 => { switch (v) { .text => |t| self.@"TelCode" = t, .null => self.@"TelCode" = "", else => {} } },
            10 => { switch (v) { .text => |t| self.@"ZipCode" = t, .null => self.@"ZipCode" = "", else => {} } },
            11 => { self.@"Longitude" = v.asF64() orelse 0; },
            12 => { self.@"Latitude" = v.asF64() orelse 0; },
            13 => { switch (v) { .text => |t| self.@"GeoHash" = t, .null => self.@"GeoHash" = "", else => {} } },
            14 => { self.@"Enable" = v.asBool() orelse false; },
            15 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            16 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            17 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
