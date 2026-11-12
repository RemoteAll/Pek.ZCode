//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 绿色版演示用文章表
const zcode = @import("zcode");

pub const Article = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"Id": i32 = 0,
    /// 标题
    @"Title": []const u8 = "",
    /// 作者
    @"Author": []const u8 = "",
    /// 评分
    @"Score": i32 = 0,
    /// 是否有效
    @"Ok": bool = false,
    /// 创建时间
    @"CreateTime": zcode.DateTime = .{},

    pub const meta = zcode.entity.EntityMeta{
        .name = "Article",
        .table_name = "ZCode_Article",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "Title", .data_type = .string, .length = 100, .description = "标题" },
            .{ .name = "Author", .data_type = .string, .length = 50, .description = "作者" },
            .{ .name = "Score", .data_type = .int32, .description = "评分" },
            .{ .name = "Ok", .data_type = .boolean, .description = "是否有效" },
            .{ .name = "CreateTime", .data_type = .datetime, .description = "创建时间" },
        },
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};
    /// 自增列下标（Id）
    pub const identity_index: usize = 0;

    /// 索引（对应 `Model.xml` 的 `Index`）
    pub const indexes = [_]zcode.codegen.IndexInfo{
        .{ .columns = &.{"Title"}, .unique = true },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("ZCode_Article");
    }
    pub fn getId(self: @This()) i32 { return self.@"Id"; }
    pub fn setId(self: *@This(), v: i32) void {
        self.@"Id" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getTitle(self: @This()) []const u8 { return self.@"Title"; }
    pub fn setTitle(self: *@This(), v: []const u8) void {
        self.@"Title" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getAuthor(self: @This()) []const u8 { return self.@"Author"; }
    pub fn setAuthor(self: *@This(), v: []const u8) void {
        self.@"Author" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getScore(self: @This()) i32 { return self.@"Score"; }
    pub fn setScore(self: *@This(), v: i32) void {
        self.@"Score" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getOk(self: @This()) bool { return self.@"Ok"; }
    pub fn setOk(self: *@This(), v: bool) void {
        self.@"Ok" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"Id") },
            1 => .{ .text = self.@"Title" },
            2 => .{ .text = self.@"Author" },
            3 => .{ .int = @intCast(self.@"Score") },
            4 => .{ .boolean = self.@"Ok" },
            5 => .{ .datetime = self.@"CreateTime" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"Id" = v.asI32() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Title" = t, .null => self.@"Title" = "", else => {} } },
            2 => { switch (v) { .text => |t| self.@"Author" = t, .null => self.@"Author" = "", else => {} } },
            3 => { self.@"Score" = v.asI32() orelse 0; },
            4 => { self.@"Ok" = v.asBool() orelse false; },
            5 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            else => {},
        }
    }
};
