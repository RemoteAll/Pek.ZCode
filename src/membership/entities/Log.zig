//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 日志。应用系统审计日志，记录用户的各种操作，禁止修改和删除
const zcode = @import("../../root.zig");

pub const Log = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"ID": i64 = 0,
    /// 类别
    @"Category": []const u8 = "",
    /// 操作
    @"Action": []const u8 = "",
    /// 链接
    @"LinkID": i64 = 0,
    /// 成功
    @"Success": bool = false,
    /// 用户名
    @"UserName": []const u8 = "",
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
    /// 性能追踪。用于APM性能追踪定位，还原该事件的调用链
    @"TraceId": []const u8 = "",
    /// 创建者
    @"CreateUser": []const u8 = "",
    /// 创建用户
    @"CreateUserID": i32 = 0,
    /// 创建地址
    @"CreateIP": []const u8 = "",
    /// 时间
    @"CreateTime": zcode.DateTime = .{},
    /// 详细信息
    @"Remark": []const u8 = "",

    pub const meta = zcode.entity.EntityMeta{
        .name = "Log",
        .table_name = "Log",
        .fields = &.{
            .{ .name = "ID", .data_type = .int64, .primary_key = true, .description = "编号" },
            .{ .name = "Category", .data_type = .string, .description = "类别" },
            .{ .name = "Action", .data_type = .string, .description = "操作" },
            .{ .name = "LinkID", .data_type = .int64, .description = "链接" },
            .{ .name = "Success", .data_type = .boolean, .description = "成功" },
            .{ .name = "UserName", .data_type = .string, .description = "用户名" },
            .{ .name = "Ex1", .data_type = .int32, .description = "扩展1" },
            .{ .name = "Ex2", .data_type = .int32, .description = "扩展2" },
            .{ .name = "Ex3", .data_type = .double, .description = "扩展3" },
            .{ .name = "Ex4", .data_type = .string, .description = "扩展4" },
            .{ .name = "Ex5", .data_type = .string, .description = "扩展5" },
            .{ .name = "Ex6", .data_type = .string, .description = "扩展6" },
            .{ .name = "TraceId", .data_type = .string, .description = "性能追踪。用于APM性能追踪定位，还原该事件的调用链" },
            .{ .name = "CreateUser", .data_type = .string, .description = "创建者" },
            .{ .name = "CreateUserID", .data_type = .int32, .description = "创建用户" },
            .{ .name = "CreateIP", .data_type = .string, .description = "创建地址" },
            .{ .name = "CreateTime", .data_type = .datetime, .description = "时间" },
            .{ .name = "Remark", .data_type = .string, .length = 2000, .description = "详细信息" },
        },
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};

    /// 索引（对应 `Model.xml` 的 `Index`）
    pub const indexes = [_]zcode.codegen.IndexInfo{
        .{ .columns = &.{"Action", "Category", "ID"}, .unique = false },
        .{ .columns = &.{"Category", "LinkID", "ID"}, .unique = false },
        .{ .columns = &.{"CreateUserID", "ID"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("Log");
    }
    pub fn getID(self: @This()) i64 { return self.@"ID"; }
    pub fn setID(self: *@This(), v: i64) void {
        if (zcode.entity.valueEql(self.@"ID", v)) return;
        self.@"ID" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getCategory(self: @This()) []const u8 { return self.@"Category"; }
    pub fn setCategory(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Category", v)) return;
        self.@"Category" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getAction(self: @This()) []const u8 { return self.@"Action"; }
    pub fn setAction(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Action", v)) return;
        self.@"Action" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getLinkID(self: @This()) i64 { return self.@"LinkID"; }
    pub fn setLinkID(self: *@This(), v: i64) void {
        if (zcode.entity.valueEql(self.@"LinkID", v)) return;
        self.@"LinkID" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getSuccess(self: @This()) bool { return self.@"Success"; }
    pub fn setSuccess(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"Success", v)) return;
        self.@"Success" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getUserName(self: @This()) []const u8 { return self.@"UserName"; }
    pub fn setUserName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UserName", v)) return;
        self.@"UserName" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getEx1(self: @This()) i32 { return self.@"Ex1"; }
    pub fn setEx1(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Ex1", v)) return;
        self.@"Ex1" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getEx2(self: @This()) i32 { return self.@"Ex2"; }
    pub fn setEx2(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Ex2", v)) return;
        self.@"Ex2" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getEx3(self: @This()) f64 { return self.@"Ex3"; }
    pub fn setEx3(self: *@This(), v: f64) void {
        if (zcode.entity.valueEql(self.@"Ex3", v)) return;
        self.@"Ex3" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getEx4(self: @This()) []const u8 { return self.@"Ex4"; }
    pub fn setEx4(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex4", v)) return;
        self.@"Ex4" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getEx5(self: @This()) []const u8 { return self.@"Ex5"; }
    pub fn setEx5(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex5", v)) return;
        self.@"Ex5" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getEx6(self: @This()) []const u8 { return self.@"Ex6"; }
    pub fn setEx6(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Ex6", v)) return;
        self.@"Ex6" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getTraceId(self: @This()) []const u8 { return self.@"TraceId"; }
    pub fn setTraceId(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"TraceId", v)) return;
        self.@"TraceId" = v;
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
            1 => .{ .text = self.@"Category" },
            2 => .{ .text = self.@"Action" },
            3 => .{ .int = @intCast(self.@"LinkID") },
            4 => .{ .boolean = self.@"Success" },
            5 => .{ .text = self.@"UserName" },
            6 => .{ .int = @intCast(self.@"Ex1") },
            7 => .{ .int = @intCast(self.@"Ex2") },
            8 => .{ .float = self.@"Ex3" },
            9 => .{ .text = self.@"Ex4" },
            10 => .{ .text = self.@"Ex5" },
            11 => .{ .text = self.@"Ex6" },
            12 => .{ .text = self.@"TraceId" },
            13 => .{ .text = self.@"CreateUser" },
            14 => .{ .int = @intCast(self.@"CreateUserID") },
            15 => .{ .text = self.@"CreateIP" },
            16 => .{ .datetime = self.@"CreateTime" },
            17 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"ID" = v.asI64() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Category" = t, .null => self.@"Category" = "", else => {} } },
            2 => { switch (v) { .text => |t| self.@"Action" = t, .null => self.@"Action" = "", else => {} } },
            3 => { self.@"LinkID" = v.asI64() orelse 0; },
            4 => { self.@"Success" = v.asBool() orelse false; },
            5 => { switch (v) { .text => |t| self.@"UserName" = t, .null => self.@"UserName" = "", else => {} } },
            6 => { self.@"Ex1" = v.asI32() orelse 0; },
            7 => { self.@"Ex2" = v.asI32() orelse 0; },
            8 => { self.@"Ex3" = v.asF64() orelse 0; },
            9 => { switch (v) { .text => |t| self.@"Ex4" = t, .null => self.@"Ex4" = "", else => {} } },
            10 => { switch (v) { .text => |t| self.@"Ex5" = t, .null => self.@"Ex5" = "", else => {} } },
            11 => { switch (v) { .text => |t| self.@"Ex6" = t, .null => self.@"Ex6" = "", else => {} } },
            12 => { switch (v) { .text => |t| self.@"TraceId" = t, .null => self.@"TraceId" = "", else => {} } },
            13 => { switch (v) { .text => |t| self.@"CreateUser" = t, .null => self.@"CreateUser" = "", else => {} } },
            14 => { self.@"CreateUserID" = v.asI32() orelse 0; },
            15 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            16 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            17 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};
