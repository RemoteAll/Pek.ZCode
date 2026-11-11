//! 导航属性加载（对应 DH.NCode `Model/NavigationLoader.cs` + `NavigationExtensions.cs`
//! 与 Rust `Pek.RCode/src/navigation.rs`）。
//!
//! C# 用 `[BindRelation]` 在编译期生成访问器；Zig 没有特性（attribute），
//! 因此这里用**显式参数**表达同样的语义：给「子表类型 + 外键列 + 外键值」，
//! 拿回一条或多条子实体。
//!
//! ## 与 C# 的对应
//!
//! | C# | 本模块 |
//! |---|---|
//! | `entity.GetSingle<TSlave>(name)` | `loadOne` |
//! | `entity.GetList<TSlave>(name)` | `loadList` |
//! | `List<TSlave>.Fill(keys)`（批量填充，避免 N+1） | `fillMany` |
//!
//! ## 为什么单独提供 `fillMany`
//!
//! 逐条 `loadList` 是最典型的 N+1：列表页 20 行主表 → 20 次子表查询。
//! `fillMany` 把主子键一次性用 `IN (...)` 查回来再按外键分组，**往返次数从 N 降到 1**。
//! 这正是 C# `Fill` 的用途，也是列表页性能的关键。
//!
//! ## 边界
//!
//! - 只做「子表 → 父表」的一层加载；多级级联由调用方组合（避免隐式深查询把库拖垮）。
//! - 子实体借用会话 arena，`Session.resetResults()` 之后失效；
//!   需要长期持有请自行 `dupe`（与实体层约定一致）。

const std = @import("std");
const entity = @import("entity.zig");
const dal_mod = @import("dal.zig");
const Dal = dal_mod.Dal;
const Session = @import("session.zig").Session;
const query = @import("query.zig");
const Where = query.Where;
const Query = query.Query;
const Value = @import("zzig").db.Value;

/// 取单条子实体（对应 `GetSingle`）。多条命中时返回第一条（与 XCode 一致，不报错）。
pub fn loadOne(
    dal: *Dal,
    comptime R: type,
    s: *Session,
    fk_field: []const u8,
    fk_value: Value,
) !?R {
    var w = Where.init(dal.gpa);
    defer w.deinit();
    _ = try w.eq(fk_field, fk_value);

    var q = Query.init(dal.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w).take(1);

    const rows = try entity.queryRows(dal, R, s, &q);
    if (rows.len == 0) return null;
    return rows[0];
}

/// 取子实体列表（对应 `GetList`）。
pub fn loadList(
    dal: *Dal,
    comptime R: type,
    s: *Session,
    fk_field: []const u8,
    fk_value: Value,
    order_by: ?[]const u8,
    limit: ?usize,
) ![]R {
    var w = Where.init(dal.gpa);
    defer w.deinit();
    _ = try w.eq(fk_field, fk_value);

    var q = Query.init(dal.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    if (order_by) |col| _ = try q.orderBy(col, false);
    if (limit) |n| _ = q.take(n);

    return entity.queryRows(dal, R, s, &q);
}

/// 批量填充的一组子实体（按外键值分组）。
pub fn Group(comptime R: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        keys: std.ArrayListUnmanaged(i64) = .empty,
        lists: std.ArrayListUnmanaged([]R) = .empty,

        pub fn deinit(self: *Self) void {
            self.keys.deinit(self.gpa);
            self.lists.deinit(self.gpa);
        }

        /// 取某个外键值对应的子实体列表（没有则返回空切片）。
        pub fn get(self: *const Self, key: i64) []const R {
            for (self.keys.items, 0..) |k, i| {
                if (k == key) return self.lists.items[i];
            }
            return &.{};
        }

        pub fn groupCount(self: *const Self) usize {
            return self.keys.items.len;
        }

        pub fn total(self: *const Self) usize {
            var n: usize = 0;
            for (self.lists.items) |l| n += l.len;
            return n;
        }
    };
}

/// 批量填充：一次 `IN (...)` 查回所有子实体，再按外键分组（**消除 N+1**）。
///
/// `keys` 里只需要传非空主键值；重复键会被忽略。
pub fn fillMany(
    dal: *Dal,
    comptime R: type,
    s: *Session,
    fk_field: []const u8,
    keys: []const i64,
) !Group(R) {
    var g = Group(R){ .gpa = dal.gpa };
    errdefer g.deinit();

    if (keys.len == 0) return g;

    // 去重
    var unique: std.ArrayListUnmanaged(Value) = .empty;
    defer unique.deinit(dal.gpa);
    var seen: std.ArrayListUnmanaged(i64) = .empty;
    defer seen.deinit(dal.gpa);

    for (keys) |k| {
        var dup = false;
        for (seen.items) |x| {
            if (x == k) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        try seen.append(dal.gpa, k);
        try unique.append(dal.gpa, .{ .int = k });
    }

    var w = Where.init(dal.gpa);
    defer w.deinit();
    _ = try w.in(fk_field, unique.items);

    var q = Query.init(dal.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);

    const rows = try entity.queryRows(dal, R, s, &q);

    // 分组：外键值 → 下标
    const R_meta = R.meta;
    var fk_index: ?usize = null;
    for (R_meta.fields, 0..) |f, i| {
        if (std.ascii.eqlIgnoreCase(f.name, fk_field)) {
            fk_index = i;
            break;
        }
    }
    if (fk_index == null) {
        std.debug.print("[zcode] 导航属性：子表 {s} 没有字段 {s}\n", .{ R_meta.name, fk_field });
        return error.ColumnNotFound;
    }

    for (rows) |row| {
        const key = row.columnValue(fk_index.?).asI64() orelse 0;
        if (findKey(R, &g, key)) |idx| {
            const old = g.lists.items[idx];
            const grown = try s.resultAllocator().alloc(R, old.len + 1);
            @memcpy(grown[0..old.len], old);
            grown[old.len] = row;
            g.lists.items[idx] = grown;
        } else {
            const one = try s.resultAllocator().alloc(R, 1);
            one[0] = row;
            try g.keys.append(dal.gpa, key);
            try g.lists.append(dal.gpa, one);
        }
    }
    return g;
}

fn findKey(comptime R: type, g: *const Group(R), key: i64) ?usize {
    for (g.keys.items, 0..) |k, i| {
        if (k == key) return i;
    }
    return null;
}

/// 测试用实体：与 `Nav_Item` 一一对對。
const TestItem = struct {
    Id: i32 = 0,
    OrderId: i32 = 0,
    Name: []const u8 = "",
    dirty: entity.DirtyBits = 0,

    pub const meta = entity.EntityMeta{
        .name = "OrderItem",
        .table_name = "Nav_Item",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "OrderId", .data_type = .int32 },
            .{ .name = "Name", .data_type = .string },
        },
    };

    pub fn columnValue(self: @This(), i: usize) Value {
        return switch (i) {
            0 => .{ .int = self.Id },
            1 => .{ .int = self.OrderId },
            2 => .{ .text = self.Name },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: Value) !void {
        switch (i) {
            0 => self.Id = v.asI32() orelse 0,
            1 => self.OrderId = v.asI32() orelse 0,
            2 => self.Name = v.asText() orelse "",
            else => return error.ColumnNotFound,
        }
    }
};

test "导航属性：单条 / 列表 / 批量填充（SQLite 集成）" {
    const a = std.testing.allocator;
    const xml =
        \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
        \\  <Table Name="Order" TableName="Nav_Order">
        \\    <Columns>
        \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\      <Column Name="Code" DataType="String" Length="20" />
        \\    </Columns>
        \\  </Table>
        \\  <Table Name="OrderItem" TableName="Nav_Item">
        \\    <Columns>
        \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\      <Column Name="OrderId" DataType="Int32" />
        \\      <Column Name="Name" DataType="String" Length="20" />
        \\    </Columns>
        \\  </Table>
        \\</Tables></EntityModel>
    ;
    const m = try @import("model.zig").EntityModel.parse(a, xml);
    var dal = try Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const orders = try dal.table("Order");
    const items = try dal.table("OrderItem");

    const o1 = try orders.insert(&s, &.{.{ .name = "Code", .value = .{ .text = "A" } }});
    const o2 = try orders.insert(&s, &.{.{ .name = "Code", .value = .{ .text = "B" } }});
    _ = try items.insert(&s, &.{
        .{ .name = "OrderId", .value = .{ .int = o1 } },
        .{ .name = "Name", .value = .{ .text = "i1" } },
    });
    _ = try items.insert(&s, &.{
        .{ .name = "OrderId", .value = .{ .int = o1 } },
        .{ .name = "Name", .value = .{ .text = "i2" } },
    });
    _ = try items.insert(&s, &.{
        .{ .name = "OrderId", .value = .{ .int = o2 } },
        .{ .name = "Name", .value = .{ .text = "i3" } },
    });

    const Item = TestItem;

    // 单条
    const one = try loadOne(&dal, Item, &s, "OrderId", .{ .int = o2 });
    try std.testing.expect(one != null);
    try std.testing.expectEqualStrings("i3", one.?.Name);

    // 列表
    const list = try loadList(&dal, Item, &s, "OrderId", .{ .int = o1 }, "Id", null);
    try std.testing.expectEqual(@as(usize, 2), list.len);

    // 批量填充：两个主键一次查回，分组正确
    var g = try fillMany(&dal, Item, &s, "OrderId", &.{ o1, o2, o1 });
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.groupCount());
    try std.testing.expectEqual(@as(usize, 2), g.get(o1).len);
    try std.testing.expectEqual(@as(usize, 1), g.get(o2).len);
    try std.testing.expectEqual(@as(usize, 0), g.get(999).len);
    try std.testing.expectEqual(@as(usize, 3), g.total());
}
