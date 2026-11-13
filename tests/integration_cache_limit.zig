//! 集成测试：整表缓存的 `MaxCacheCount`（内存保护）。
//!
//! 口径（对齐 C# `Meta.Cache`）：
//! - 模型 `MaxCacheCount <= 0`（含时序列强制 0）→ **禁用整表缓存**，读写直接走库；
//! - 装载后发现行数超过 `MaxCacheCount` → 放弃缓存（后续同样直接查库），避免把大表全塞内存。

const std = @import("std");
const zcode = @import("zcode");

fn Rec(comptime table: []const u8) type {
    return struct {
        dirty: zcode.entity.DirtyBits = 0,
        Id: i32 = 0,
        Name: []const u8 = "",

        pub const meta = zcode.entity.EntityMeta{
            .name = table,
            .table_name = table,
            .fields = &.{
                .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
                .{ .name = "Name", .data_type = .string },
            },
        };

        pub fn columnValue(self: @This(), i: usize) zcode.Value {
            return switch (i) {
                0 => .{ .int = self.Id },
                1 => .{ .text = self.Name },
                else => .null,
            };
        }

        pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
            switch (i) {
                0 => self.Id = v.asI32() orelse 0,
                1 => self.Name = if (v == .text) v.text else "",
                else => {},
            }
        }

        pub fn setName(self: *@This(), v: []const u8) void {
            if (zcode.entity.valueEql(self.Name, v)) return;
            self.Name = v;
            zcode.entity.markDirty(&self.dirty, 1);
        }
    };
}

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="NoCache" TableName="BH_NoCache" MaxCacheCount="0">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\    </Columns>
    \\  </Table>
    \\  <Table Name="Tiny" TableName="BH_Tiny" MaxCacheCount="2">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\    </Columns>
    \\  </Table>
    \\  <Table Name="Small" TableName="BH_Small" MaxCacheCount="100">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

const NoCache = Rec("NoCache");
const Tiny = Rec("Tiny");
const Small = Rec("Small");

fn openDal(a: std.mem.Allocator, path: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

fn insertRec(comptime T: type, dal: *zcode.Dal, s: *zcode.Session, name: []const u8) !i32 {
    var e = T{};
    e.setName(name);
    const id = try zcode.entity.insert(dal, &e, s);
    return @intCast(id);
}

test "MaxCacheCount=0：禁用整表缓存，读仍走库且结果正确" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache0", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const id = try insertRec(NoCache, &dal, &s, "a");

    var cache = zcode.cache.Cache(NoCache).init(&dal, 60);
    defer cache.deinit();

    try std.testing.expect(cache.disabled);
    const got = (try cache.get(&s, id)).?;
    try std.testing.expectEqualStrings("a", got.Name);
    try std.testing.expectEqual(@as(usize, 1), try cache.count(&s));
    // 没装载过整表（items 为空 = 没进内存）
    try std.testing.expectEqual(@as(usize, 0), cache.items.len);
}

test "MaxCacheCount=2 但表里有 3 行：装载后放弃缓存，结果仍正确" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache2", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    _ = try insertRec(Tiny, &dal, &s, "a");
    _ = try insertRec(Tiny, &dal, &s, "b");
    _ = try insertRec(Tiny, &dal, &s, "c");

    var cache = zcode.cache.Cache(Tiny).init(&dal, 60);
    defer cache.deinit();
    try std.testing.expect(!cache.disabled); // init 时还不知道行数

    const all = try cache.all(&s);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    // 超过上限 → 主动放弃缓存（内存保护）
    try std.testing.expect(cache.disabled);
    try std.testing.expectEqual(@as(usize, 0), cache.items.len);
}

test "MaxCacheCount=100：正常缓存，写后自动失效" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache100", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const id = try insertRec(Small, &dal, &s, "a");

    var cache = zcode.cache.Cache(Small).init(&dal, 60);
    defer cache.deinit();

    const first = (try cache.get(&s, id)).?;
    try std.testing.expectEqualStrings("a", first.Name);
    try std.testing.expect(!cache.disabled);
    try std.testing.expect(cache.items.len > 0);

    // 写操作 → 缓存失效 → 下次读到新值
    var e = first;
    e.setName("b");
    const affected = try zcode.entity.update(&dal, &e, &s);
    try std.testing.expectEqual(@as(usize, 1), affected);

    // 先确认库里真的写进去了（把「缓存问题」和「写库问题」分开）
    const from_db = (try zcode.entity.findByPk(&dal, Small, &s, &.{.{ .int = id }})).?;
    try std.testing.expectEqualStrings("b", from_db.Name);

    const second = (try cache.get(&s, id)).?;
    try std.testing.expectEqualStrings("b", second.Name);
}
