//! 查询条件与查询描述：对应 XCode 的 `WhereExpression` 与 `PageParameter`。
//!
//! 条件以结构化方式收集，渲染时按目标方言生成占位符与参数序列，**全程参数绑定**。
//!
//! 注意（与 Rust 版同一坑）：比较运算不匹配 NULL —— SQL 里 `NULL = ?` 结果是 NULL。
//! 「为空 / 非空」用 `isNull` / `notNull`；「为空或满足阈值」用 `raw`。

const std = @import("std");
const Buf = @import("zzig").Buf;
const Value = @import("zzig").db.Value;
const DatabaseKind = @import("dialect.zig").DatabaseKind;

pub const Op = enum {
    eq,
    ne,
    gt,
    ge,
    lt,
    le,
    like,
    not_like,
    in,
    not_in,
    is_null,
    not_null,
    between,
    /// 原始 SQL 片段（`column` 原样输出，`?` 按顺序由 `values` 填占位；仅限可信字面量）
    raw,
};

pub const Cond = struct {
    column: []const u8,
    op: Op,
    values: []const Value,
    /// `column` 是否由 Where 自己分配（如 `anyLike` 拼接的片段），deinit 时需释放
    owns_column: bool = false,
};

pub const Where = struct {
    a: std.mem.Allocator,
    conds: std.ArrayList(Cond) = .empty,

    pub fn init(a: std.mem.Allocator) Where {
        return .{ .a = a };
    }

    pub fn deinit(self: *Where) void {
        for (self.conds.items) |c| {
            if (c.owns_column) self.a.free(c.column);
            self.a.free(c.values);
        }
        self.conds.deinit(self.a);
    }

    pub fn isEmpty(self: *const Where) bool {
        return self.conds.items.len == 0;
    }

    /// 底层追加（复制 values）。
    pub fn andRaw(self: *Where, column: []const u8, op: Op, values: []const Value) !*Where {
        const vals = try self.a.dupe(Value, values);
        return self.appendOwned(column, op, vals);
    }

    /// 底层追加（接管 values 所有权）。
    fn appendOwned(self: *Where, column: []const u8, op: Op, values: []const Value) !*Where {
        try self.conds.append(self.a, .{ .column = column, .op = op, .values = values });
        return self;
    }

    /// 底层追加（接管 column 与 values 所有权）。
    fn appendOwnedAll(self: *Where, column: []const u8, op: Op, values: []const Value) !*Where {
        try self.conds.append(self.a, .{ .column = column, .op = op, .values = values, .owns_column = true });
        return self;
    }

    fn one(self: *Where, column: []const u8, op: Op, value: Value) !*Where {
        const vals = try self.a.alloc(Value, 1);
        vals[0] = value;
        return self.appendOwned(column, op, vals);
    }

    pub fn eq(self: *Where, column: []const u8, value: Value) !*Where {
        return self.one(column, .eq, value);
    }

    pub fn ne(self: *Where, column: []const u8, value: Value) !*Where {
        return self.one(column, .ne, value);
    }

    pub fn gt(self: *Where, column: []const u8, value: Value) !*Where {
        return self.one(column, .gt, value);
    }

    pub fn ge(self: *Where, column: []const u8, value: Value) !*Where {
        return self.one(column, .ge, value);
    }

    pub fn lt(self: *Where, column: []const u8, value: Value) !*Where {
        return self.one(column, .lt, value);
    }

    pub fn le(self: *Where, column: []const u8, value: Value) !*Where {
        return self.one(column, .le, value);
    }

    pub fn like(self: *Where, column: []const u8, pattern: []const u8) !*Where {
        return self.one(column, .like, .{ .text = pattern });
    }

    pub fn notLike(self: *Where, column: []const u8, pattern: []const u8) !*Where {
        return self.one(column, .not_like, .{ .text = pattern });
    }

    pub fn in(self: *Where, column: []const u8, values: []const Value) !*Where {
        const vals = try self.a.dupe(Value, values);
        return self.appendOwned(column, .in, vals);
    }

    pub fn notIn(self: *Where, column: []const u8, values: []const Value) !*Where {
        const vals = try self.a.dupe(Value, values);
        return self.appendOwned(column, .not_in, vals);
    }

    pub fn between(self: *Where, column: []const u8, low: Value, high: Value) !*Where {
        const vals = try self.a.alloc(Value, 2);
        vals[0] = low;
        vals[1] = high;
        return self.appendOwned(column, .between, vals);
    }

    pub fn isNull(self: *Where, column: []const u8) !*Where {
        return self.andRaw(column, .is_null, &.{});
    }

    pub fn notNull(self: *Where, column: []const u8) !*Where {
        return self.andRaw(column, .not_null, &.{});
    }

    /// 原始条件片段（`?` 由 values 按序填充）。
    pub fn raw(self: *Where, fragment: []const u8, values: []const Value) !*Where {
        const vals = try self.a.dupe(Value, values);
        return self.appendOwned(fragment, .raw, vals);
    }

    /// 任一列模糊匹配：`(c1 LIKE ? OR c2 LIKE ? ...)`（关键字搜索语义）。
    pub fn anyLike(self: *Where, columns: []const []const u8, pattern: []const u8) !*Where {
        if (columns.len == 0) return self;
        var expr: std.ArrayList(u8) = .empty;
        defer expr.deinit(self.a);
        for (columns, 0..) |c, i| {
            if (i > 0) try expr.appendSlice(self.a, " OR ");
            try expr.appendSlice(self.a, c);
            try expr.appendSlice(self.a, " LIKE ?");
        }
        const fragment = try std.fmt.allocPrint(self.a, "({s})", .{expr.items});
        const vals = try self.a.alloc(Value, columns.len);
        for (vals) |*v| v.* = .{ .text = pattern };
        return self.appendOwnedAll(fragment, .raw, vals);
    }

    /// 渲染条件片段并追加参数（外层带括号；空条件返回空串）。
    pub fn renderAlloc(self: *const Where, gpa: std.mem.Allocator, kind: DatabaseKind, params: *std.ArrayList(Value)) ![]u8 {
        var b = Buf.init(gpa);
        defer b.deinit();
        try self.renderInto(gpa, kind, params, &b);
        return b.toOwnedSlice();
    }

    /// 渲染条件片段并**追加**到 `out`（外层带括号；空条件不追加任何内容）。
    pub fn renderInto(self: *const Where, gpa: std.mem.Allocator, kind: DatabaseKind, params: *std.ArrayList(Value), out: *Buf) !void {
        if (self.conds.items.len == 0) return;
        const a = gpa;

        try out.addByte('(');
        for (self.conds.items, 0..) |cond, index| {
            if (index > 0) try out.add(" AND ");
            switch (cond.op) {
                .is_null => {
                    try pushQuotedOrRaw(kind, out, cond.column);
                    try out.add(" IS NULL");
                },
                .not_null => {
                    try pushQuotedOrRaw(kind, out, cond.column);
                    try out.add(" IS NOT NULL");
                },
                .in, .not_in => {
                    if (cond.values.len == 0) {
                        // 空集合：IN → 恒假；NOT IN → 恒真（避免生成非法 SQL）
                        try out.add(if (cond.op == .in) "1 = 0" else "1 = 1");
                    } else {
                        try pushQuotedOrRaw(kind, out, cond.column);
                        try out.add(if (cond.op == .in) " IN (" else " NOT IN (");
                        for (cond.values, 0..) |value, position| {
                            if (position > 0) try out.add(", ");
                            try kind.pushPlaceholder(out, params.items.len);
                            try params.append(a, value);
                        }
                        try out.addByte(')');
                    }
                },
                .between => {
                    try pushQuotedOrRaw(kind, out, cond.column);
                    try out.add(" BETWEEN ");
                    try kind.pushPlaceholder(out, params.items.len);
                    try params.append(a, cond.values[0]);
                    try out.add(" AND ");
                    try kind.pushPlaceholder(out, params.items.len);
                    try params.append(a, cond.values[1]);
                },
                .raw => {
                    // 片段原样输出，`?` 逐个替换为方言占位符并填参数
                    var it = std.mem.splitScalar(u8, cond.column, '?');
                    if (it.next()) |first| try out.add(first);
                    var vi: usize = 0;
                    while (it.next()) |part| {
                        if (vi < cond.values.len) {
                            try kind.pushPlaceholder(out, params.items.len);
                            try params.append(a, cond.values[vi]);
                            vi += 1;
                        } else {
                            // 占位符多于值：按原文输出，不静默吞掉（便于暴露调用方错误）
                            try out.addByte('?');
                        }
                        try out.add(part);
                    }
                },
                else => {
                    const op_text: []const u8 = switch (cond.op) {
                        .eq => "=",
                        .ne => "<>",
                        .gt => ">",
                        .ge => ">=",
                        .lt => "<",
                        .le => "<=",
                        .like => "LIKE",
                        .not_like => "NOT LIKE",
                        else => unreachable,
                    };
                    try pushQuotedOrRaw(kind, out, cond.column);
                    try out.addByte(' ');
                    try out.add(op_text);
                    try out.addByte(' ');
                    try kind.pushPlaceholder(out, params.items.len);
                    try params.append(a, cond.values[0]);
                },
            }
        }
        try out.addByte(')');
    }
};

/// 列名 → SQL 片段：普通标识符按方言引用（`Table.Column` 逐段引用），含其它字符时原样输出。
fn pushQuotedOrRaw(kind: DatabaseKind, out: *Buf, column: []const u8) !void {
    var plain = column.len > 0;
    for (column) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) {
            plain = false;
            break;
        }
    }
    if (!plain) return out.add(column);

    var it = std.mem.splitScalar(u8, column, '.');
    var first = true;
    while (it.next()) |part| {
        if (!first) try out.addByte('.');
        first = false;
        try kind.pushQuoted(out, part);
    }
}

pub const OrderBy = struct {
    column: []const u8,
    desc: bool = false,
};

/// 查询描述（SELECT 语句的组装参数）。
pub const Query = struct {
    a: std.mem.Allocator,
    select: std.ArrayList([]const u8) = .empty,
    filter: ?*const Where = null,
    order_by: std.ArrayList(OrderBy) = .empty,
    limit: ?usize = null,
    offset: ?usize = null,
    page_index: usize = 0,
    page_size: usize = 0,

    pub fn init(a: std.mem.Allocator) Query {
        return .{ .a = a };
    }

    pub fn deinit(self: *Query) void {
        self.select.deinit(self.a);
        self.order_by.deinit(self.a);
    }

    pub fn column(self: *Query, column_name: []const u8) !*Query {
        try self.select.append(self.a, column_name);
        return self;
    }

    pub fn filterWhere(self: *Query, filter: *const Where) *Query {
        self.filter = filter;
        return self;
    }

    pub fn orderBy(self: *Query, column_name: []const u8, desc: bool) !*Query {
        try self.order_by.append(self.a, .{ .column = column_name, .desc = desc });
        return self;
    }

    /// 设置分页（页码从 1 开始）。
    pub fn page(self: *Query, page_index: usize, page_size: usize) *Query {
        self.page_index = page_index;
        self.page_size = page_size;
        return self;
    }

    pub fn take(self: *Query, n: usize) *Query {
        self.limit = n;
        return self;
    }

    pub fn skip(self: *Query, n: usize) *Query {
        self.offset = n;
        return self;
    }
};

test "SQLite 条件渲染（Rust 版黄金断言）" {
    const a = std.testing.allocator;
    var w = Where.init(a);
    defer w.deinit();
    _ = try w.eq("Status", .{ .int = 1 });
    _ = try w.gt("Amount", .{ .text = "100" });
    _ = try w.like("Code", "HLT%");
    _ = try w.in("Type", &[_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } });
    _ = try w.isNull("Remark");

    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);

    const sql = try w.renderAlloc(a, .sqlite, &params);
    defer a.free(sql);
    try std.testing.expectEqualStrings(
        "(\"Status\" = ? AND \"Amount\" > ? AND \"Code\" LIKE ? AND \"Type\" IN (?, ?, ?) AND \"Remark\" IS NULL)",
        sql,
    );
    try std.testing.expectEqual(@as(usize, 6), params.items.len);
}

test "SQL Server 占位符按已占用参数编号" {
    const a = std.testing.allocator;
    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);
    try params.append(a, .{ .int = 1 });

    var w = Where.init(a);
    defer w.deinit();
    _ = try w.eq("Code", .{ .text = "X" });

    const sql = try w.renderAlloc(a, .sqlserver, &params);
    defer a.free(sql);
    try std.testing.expectEqualStrings("([Code] = @p1)", sql);
}

test "空集合 IN / NOT IN 的恒假/恒真" {
    const a = std.testing.allocator;
    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);

    var w1 = Where.init(a);
    defer w1.deinit();
    _ = try w1.andRaw("Id", .in, &.{});
    const s1 = try w1.renderAlloc(a, .sqlite, &params);
    defer a.free(s1);
    try std.testing.expectEqualStrings("(1 = 0)", s1);

    var w2 = Where.init(a);
    defer w2.deinit();
    _ = try w2.andRaw("Id", .not_in, &.{});
    const s2 = try w2.renderAlloc(a, .sqlite, &params);
    defer a.free(s2);
    try std.testing.expectEqualStrings("(1 = 1)", s2);
}

test "raw 片段占位与多列 OR" {
    const a = std.testing.allocator;
    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);

    var w = Where.init(a);
    defer w.deinit();
    _ = try w.anyLike(&[_][]const u8{ "Name", "Code" }, "%k%");

    const sql = try w.renderAlloc(a, .sqlite, &params);
    defer a.free(sql);
    try std.testing.expectEqualStrings("((Name LIKE ? OR Code LIKE ?))", sql);
    try std.testing.expectEqual(@as(usize, 2), params.items.len);
}

test "复合列名逐段引用" {
    const a = std.testing.allocator;
    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);

    var w = Where.init(a);
    defer w.deinit();
    _ = try w.eq("t.Status", .{ .int = 1 });
    const sql = try w.renderAlloc(a, .postgresql, &params);
    defer a.free(sql);
    try std.testing.expectEqualStrings("(\"t\".\"Status\" = $1)", sql);
}
