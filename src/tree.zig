//! 树形实体（对应 DH.NCode `Tree/EntityTree.cs` 的常用子集）。
//!
//! 提供四种操作，全部基于「父键列 + 主键列」的显式参数（Zig 没有接口/特性可挂）：
//!
//! - `children`：取直接子节点
//! - `descendants`：广度优先取全部后代（**不含自身**，按层返回）
//! - `pathToRoot`：从节点向上到根（**含自身**，顺序为「自己 → … → 根」）
//! - `roots`：取根节点（父键为 NULL 或 0）
//!
//! ## 护栏（与 C# 的差异）
//!
//! C# `EntityTree` 递归时依赖实体缓存；Zig 侧每次都要真查库，因此**必须有限制**：
//! `Options.max_items`（默认 10000）与 `max_depth`（默认 32）到顶即返回
//! `error.TreeTooLarge` / `error.TreeTooDeep`，并打印已扫节点数。
//! 静默截断会造成「树看起来少了几个节点」这种极难排查的问题。
//!
//! 数据本身有环（A 的父是 B、B 的父是 A）时，`max_depth` 会兜住，同时打印告警。

const std = @import("std");
const entity = @import("entity.zig");
const dal_mod = @import("dal.zig");
const Dal = dal_mod.Dal;
const Session = @import("session.zig").Session;
const query = @import("query.zig");
const Where = query.Where;
const Query = query.Query;
const Value = @import("zzig").db.Value;

pub const Options = struct {
    /// 父键列名（缺省 `ParentId`）
    parent_field: []const u8 = "ParentId",
    /// 主键列名（缺省 `Id`）
    key_field: []const u8 = "Id",
    /// 排序列（可选；为空则按主键）
    order_field: ?[]const u8 = null,
    /// 最多返回节点数（默认 10000）
    max_items: usize = 10_000,
    /// 最大深度（默认 32）
    max_depth: usize = 32,
};

/// 取直接子节点。
pub fn children(dal: *Dal, comptime T: type, s: *Session, parent_value: Value, opts: Options) ![]T {
    var w = Where.init(dal.gpa);
    defer w.deinit();
    _ = try w.eq(opts.parent_field, parent_value);

    var q = Query.init(dal.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    if (opts.order_field) |col| {
        _ = try q.orderBy(col, false);
    } else {
        _ = try q.orderBy(opts.key_field, false);
    }
    if (opts.max_items > 0) _ = q.take(opts.max_items);

    return entity.queryRows(dal, T, s, &q);
}

/// 取根节点（父键 IS NULL 或 = 0）。
pub fn roots(dal: *Dal, comptime T: type, s: *Session, opts: Options) ![]T {
    var w = Where.init(dal.gpa);
    defer w.deinit();
    const cond = try std.fmt.allocPrint(dal.gpa, "({s} IS NULL OR {s} = 0)", .{ opts.parent_field, opts.parent_field });
    defer dal.gpa.free(cond);
    _ = try w.raw(cond, &.{});

    var q = Query.init(dal.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    if (opts.order_field) |col| _ = try q.orderBy(col, false) else _ = try q.orderBy(opts.key_field, false);
    if (opts.max_items > 0) _ = q.take(opts.max_items);

    return entity.queryRows(dal, T, s, &q);
}

/// 广度优先取全部后代（不含自身）。
///
/// 返回值分配在**会话 arena** 上（与 `entity.queryRows` 一致），调用方不需要 free；
/// `Session.resetResults()` 后失效。
pub fn descendants(dal: *Dal, comptime T: type, s: *Session, root_key: Value, opts: Options) ![]T {
    const arena = s.resultAllocator();
    var out: std.ArrayList(T) = .empty;
    errdefer out.deinit(arena);

    var frontier: std.ArrayList(Value) = .empty;
    defer frontier.deinit(dal.gpa);
    try frontier.append(dal.gpa, root_key);

    var depth: usize = 0;
    while (frontier.items.len > 0) {
        if (depth >= opts.max_depth) {
            std.debug.print(
                "[zcode] 树形：达到最大深度 {d}（已取 {d} 个后代，可能是数据成环）\n",
                .{ opts.max_depth, out.items.len },
            );
            return error.TreeTooDeep;
        }

        var level: std.ArrayList(T) = .empty;
        defer level.deinit(dal.gpa);

        // 一次 IN 查一层（避免逐个父键查库）
        var w = Where.init(dal.gpa);
        defer w.deinit();
        _ = try w.in(opts.parent_field, frontier.items);

        var q = Query.init(dal.gpa);
        defer q.deinit();
        _ = q.filterWhere(&w);
        if (opts.order_field) |col| _ = try q.orderBy(col, false) else _ = try q.orderBy(opts.key_field, false);
        if (opts.max_items > 0) _ = q.take(opts.max_items);

        const rows = try entity.queryRows(dal, T, s, &q);
        for (rows) |row| try level.append(dal.gpa, row);

        frontier.clearRetainingCapacity();
        for (level.items) |row| {
            try out.append(arena, row);
            if (opts.max_items > 0 and out.items.len >= opts.max_items) {
                std.debug.print("[zcode] 树形：达到最大节点数 {d}，停止展开\n", .{opts.max_items});
                return error.TreeTooLarge;
            }
            try frontier.append(dal.gpa, keyValueOf(T, row, opts.key_field));
        }
        depth += 1;
    }

    return out.toOwnedSlice(arena);
}

/// 从节点向上到根（含自身，顺序：自己 → … → 根）。
///
/// 返回值分配在**会话 arena** 上，调用方不需要 free。
pub fn pathToRoot(dal: *Dal, comptime T: type, s: *Session, node_key: Value, opts: Options) ![]T {
    const arena = s.resultAllocator();
    var out: std.ArrayList(T) = .empty;
    errdefer out.deinit(arena);

    var current = node_key;
    var depth: usize = 0;
    while (depth < opts.max_depth) : (depth += 1) {
        var w = Where.init(dal.gpa);
        defer w.deinit();
        _ = try w.eq(opts.key_field, current);

        var q = Query.init(dal.gpa);
        defer q.deinit();
        _ = q.filterWhere(&w).take(1);

        const rows = try entity.queryRows(dal, T, s, &q);
        if (rows.len == 0) break;

        const row = rows[0];
        try out.append(arena, row);
        if (opts.max_items > 0 and out.items.len >= opts.max_items) break;

        const parent = valueOfField(T, row, opts.parent_field);
        if (isRootValue(parent)) break;
        current = parent;
    }

    if (depth >= opts.max_depth) {
        std.debug.print("[zcode] 树形：向上取路径达到最大深度 {d}（可能是数据成环）\n", .{opts.max_depth});
        return error.TreeTooDeep;
    }
    return out.toOwnedSlice(arena);
}

fn isRootValue(v: Value) bool {
    return switch (v) {
        .null => true,
        .int => |n| n == 0,
        .text => |t| t.len == 0,
        else => false,
    };
}

fn keyValueOf(comptime T: type, row: T, key_field: []const u8) Value {
    return valueOfField(T, row, key_field);
}

/// 按字段名取实体字段值（字段不存在返回 `.null`）。
pub fn valueOfField(comptime T: type, row: T, field_name: []const u8) Value {
    for (T.meta.fields, 0..) |f, i| {
        if (std.ascii.eqlIgnoreCase(f.name, field_name)) return row.columnValue(i);
    }
    return .null;
}

// ───────────────────────────── 测试 ─────────────────────────────

/// 测试用树节点实体：`Tree_Node(Id, ParentId, Name, Sort)`。
const TestNode = struct {
    Id: i32 = 0,
    ParentId: i32 = 0,
    Name: []const u8 = "",
    Sort: i32 = 0,
    dirty: entity.DirtyBits = 0,

    pub const meta = entity.EntityMeta{
        .name = "TreeNode",
        .table_name = "Tree_Node",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "ParentId", .data_type = .int32 },
            .{ .name = "Name", .data_type = .string },
            .{ .name = "Sort", .data_type = .int32 },
        },
    };

    pub fn columnValue(self: @This(), i: usize) Value {
        return switch (i) {
            0 => .{ .int = self.Id },
            1 => .{ .int = self.ParentId },
            2 => .{ .text = self.Name },
            3 => .{ .int = self.Sort },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: Value) !void {
        switch (i) {
            0 => self.Id = v.asI32() orelse 0,
            1 => self.ParentId = v.asI32() orelse 0,
            2 => self.Name = v.asText() orelse "",
            3 => self.Sort = v.asI32() orelse 0,
            else => return error.ColumnNotFound,
        }
    }
};

test "树形：子节点 / 后代（BFS）/ 向上路径 / 根节点" {
    const a = std.testing.allocator;
    const xml =
        \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
        \\  <Table Name="TreeNode" TableName="Tree_Node">
        \\    <Columns>
        \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\      <Column Name="ParentId" DataType="Int32" />
        \\      <Column Name="Name" DataType="String" Length="20" />
        \\      <Column Name="Sort" DataType="Int32" Nullable="True" />
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

    const t = try dal.table("TreeNode");
    // 1(根) ├─ 2 ├─ 4
    //           └─ 5
    //   └─ 3
    const n1 = try t.insert(&s, &.{
        .{ .name = "ParentId", .value = .{ .int = 0 } },
        .{ .name = "Name", .value = .{ .text = "root" } },
    });
    const n2 = try t.insert(&s, &.{
        .{ .name = "ParentId", .value = .{ .int = n1 } },
        .{ .name = "Name", .value = .{ .text = "a" } },
    });
    const n3 = try t.insert(&s, &.{
        .{ .name = "ParentId", .value = .{ .int = n1 } },
        .{ .name = "Name", .value = .{ .text = "b" } },
    });
    const n4 = try t.insert(&s, &.{
        .{ .name = "ParentId", .value = .{ .int = n2 } },
        .{ .name = "Name", .value = .{ .text = "a1" } },
    });

    const opts = Options{ .order_field = "Id" };

    // 根
    const r = try roots(&dal, TestNode, &s, opts);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("root", r[0].Name);

    // 直接子节点
    const kids = try children(&dal, TestNode, &s, .{ .int = n1 }, opts);
    try std.testing.expectEqual(@as(usize, 2), kids.len);

    // 后代（BFS，不含自身）：a、b、a1
    const all = try descendants(&dal, TestNode, &s, .{ .int = n1 }, opts);
    try std.testing.expectEqual(@as(usize, 3), all.len);

    // 向上路径：a1 → a → root
    const path = try pathToRoot(&dal, TestNode, &s, .{ .int = n4 }, opts);
    try std.testing.expectEqual(@as(usize, 3), path.len);
    try std.testing.expectEqualStrings("a1", path[0].Name);
    try std.testing.expectEqualStrings("a", path[1].Name);
    try std.testing.expectEqualStrings("root", path[2].Name);

    _ = n3;
}

test "树形：深度护栏（数据成环时明确报错，不静默截断）" {
    const a = std.testing.allocator;
    const xml =
        \\<EntityModel><Tables><Table Name="TreeNode" TableName="Tree_Node">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="ParentId" DataType="Int32" />
        \\    <Column Name="Name" DataType="String" Length="20" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m = try @import("model.zig").EntityModel.parse(a, xml);
    var dal = try Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const t = try dal.table("TreeNode");
    // 自环：1 的父是自己
    const n1 = try t.insert(&s, &.{
        .{ .name = "ParentId", .value = .{ .int = 1 } },
        .{ .name = "Name", .value = .{ .text = "loop" } },
    });

    const opts = Options{ .max_depth = 3 };
    try std.testing.expectError(error.TreeTooDeep, pathToRoot(&dal, TestNode, &s, .{ .int = n1 }, opts));
}
