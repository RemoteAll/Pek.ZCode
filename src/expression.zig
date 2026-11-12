//! 表达式树（对应 DH.NCode `Model/Expression.cs` / `FieldExpression.cs` / `ConcatExpression.cs` /
//! `FormatExpression.cs`）。
//!
//! XCode 的条件与选中列可以写成「文本表达式 + 字段表达式 + 格式化表达式」的组合：
//! - `Expression`：一段原始 SQL 文本；`DetectOr` 为真且文本里出现独立单词 `Or` 时自动加括号，
//!   避免 `a OR b` 拼进 `AND` 链时优先级出错（C# 用正则 `\bOr\b`，这里用等价的手写边界扫描）。
//! - `FieldExpression`：只输出一个被引用的列名（按方言引用，MySQL 反引号 / SQL Server 方括号 …）。
//! - `FormatExpression`：`字段 + 格式串 + 右值`，如 `"{0} = {1}"`、`"{0} IS NULL"`。
//!   参数化时右值进参数列表（占位符按方言生成），非参数化时按字面量内联（`Value.toSqlLiteralAlloc`）。
//! - `ConcatExpression`：逗号拼接多个表达式（`SELECT a, b, c` 这类场景），`And` 追加、可嵌套。
//!
//! 与 C# 的差异（有意）：
//! - C# 的参数字典是 `名字 → 值`（`FormatExpression` 里会自动去重成 `Name2`、`Name3`）；
//!   Zig 侧统一用**位置占位符**（`?` / `$n` / `@pN`，由方言决定），因此只追加值、不记名字。
//! - `Expression.Empty` 的等价物是 `Any.empty`。

const std = @import("std");
const Buf = @import("zzig").Buf;
const Value = @import("zzig").db.Value;
const DatabaseKind = @import("dialect.zig").DatabaseKind;

/// 渲染可能返回的错误（`Buf` 返回 `OutOfMemory` / `WriteFailed`，字面量化可能返回 `NoSpaceLeft`）。
pub const RenderError = error{ OutOfMemory, WriteFailed, NoSpaceLeft };

/// 原始文本表达式。
pub const Expression = struct {
    text: []const u8 = "",
    /// 是否检测 `Or` 关键字并加括号（C# 默认 true）
    detect_or: bool = true,

    pub fn init(text: []const u8) Expression {
        return .{ .text = text };
    }

    /// 构造时不检测 Or（对应 C# `new Expression(exp) { DetectOr = false }`）。
    pub fn initLiteral(text: []const u8) Expression {
        return .{ .text = text, .detect_or = false };
    }

    pub fn isEmpty(self: Expression) bool {
        return std.mem.trim(u8, self.text, " \t\r\n").len == 0;
    }

    pub fn renderInto(self: Expression, b: *Buf) !void {
        if (self.isEmpty()) return;
        if (self.detect_or and containsWordOr(self.text)) {
            try b.add("(");
            try b.add(self.text);
            try b.add(")");
        } else {
            try b.add(self.text);
        }
    }
};

/// 字段表达式：只输出被引用的列名。
pub const FieldExpression = struct {
    /// 物理列名（`TableMeta.effectiveColumnName`）
    column: []const u8,

    pub fn init(column: []const u8) FieldExpression {
        return .{ .column = column };
    }

    pub fn isEmpty(self: FieldExpression) bool {
        return self.column.len == 0;
    }

    pub fn renderInto(self: FieldExpression, kind: DatabaseKind, b: *Buf) !void {
        if (self.isEmpty()) return;
        try kind.pushQuoted(b, self.column);
    }
};

/// 格式化表达式：`format` 里 `{0}` 是列名，`{1}` 是右值。
pub const FormatExpression = struct {
    /// 物理列名
    column: []const u8,
    /// 格式串，如 `"{0} = {1}"` / `"{0} IS NULL"`
    format: []const u8,
    /// 右值（`null` = SQL NULL）
    value: ?Value = null,

    pub fn init(column: []const u8, format: []const u8, value: ?Value) FormatExpression {
        return .{ .column = column, .format = format, .value = value };
    }

    pub fn isEmpty(self: FormatExpression) bool {
        return self.column.len == 0 or std.mem.trim(u8, self.format, " \t\r\n").len == 0;
    }

    /// 渲染。
    ///
    /// - `params != null`：参数化，右值追加进 `params`，SQL 里放占位符；
    /// - `params == null`：非参数化，右值按字面量内联（与 C# `ps == null` 分支一致）。
    pub fn renderInto(
        self: FormatExpression,
        gpa: std.mem.Allocator,
        kind: DatabaseKind,
        params: ?*std.ArrayList(Value),
        b: *Buf,
    ) !void {
        if (self.isEmpty()) return;
        if (params) |list| {
            try renderFormatParam(gpa, kind, b, self, list);
            return;
        }

        const quoted = try kind.quoteAlloc(gpa, self.column);
        defer gpa.free(quoted);

        // 不需要右值（如 Is Null）
        if (!containsPlaceholder(self.format, 1)) {
            try pushFormatted(b, self.format, quoted, "");
            return;
        }

        const literal = if (self.value) |v| try v.toSqlLiteralAlloc(gpa) else try gpa.dupe(u8, "NULL");
        defer gpa.free(literal);
        try pushFormatted(b, self.format, quoted, literal);
    }
};

/// 参数化渲染（独立函数，避免 `renderInto` 里两段拼接的复杂度）。
pub fn renderFormatParam(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    b: *Buf,
    self: FormatExpression,
    params: *std.ArrayList(Value),
) !void {
    if (self.isEmpty()) return;

    const quoted = try kind.quoteAlloc(gpa, self.column);
    defer gpa.free(quoted);

    if (!containsPlaceholder(self.format, 1)) {
        try pushFormatted(b, self.format, quoted, "");
        return;
    }

    // 先把占位符渲染到临时缓冲，再整体替换 {1}
    var ph = Buf.init(gpa);
    defer ph.deinit();
    try kind.pushPlaceholder(&ph, params.items.len);
    try params.append(gpa, self.value orelse .null);

    try pushFormatted(b, self.format, quoted, ph.slice());
}

/// 表达式联合：便于把不同类型的表达式放进同一个列表。
pub const Any = union(enum) {
    empty,
    raw: Expression,
    field: FieldExpression,
    format: FormatExpression,
    concat: *const ConcatExpression,

    pub fn isEmpty(self: Any) bool {
        return switch (self) {
            .empty => true,
            .raw => |e| e.isEmpty(),
            .field => |e| e.isEmpty(),
            .format => |e| e.isEmpty(),
            .concat => |c| c.isEmpty(),
        };
    }

    /// 渲染；`params == null` 表示非参数化（右值内联为字面量）。
    ///
    /// 错误集显式写成 `RenderError`：这里与 `ConcatExpression.renderInto` 互相递归，
    /// 两边都用推导错误集会形成「依赖环」而编不过。
    pub fn renderInto(
        self: Any,
        gpa: std.mem.Allocator,
        kind: DatabaseKind,
        params: ?*std.ArrayList(Value),
        b: *Buf,
    ) RenderError!void {
        switch (self) {
            .empty => {},
            .raw => |e| try e.renderInto(b),
            .field => |e| try e.renderInto(kind, b),
            .format => |e| try e.renderInto(gpa, kind, params, b),
            .concat => |c| try c.renderInto(gpa, kind, params, b),
        }
    }
};

/// 逗号连接表达式（对应 C# `ConcatExpression`）。
pub const ConcatExpression = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Any) = .empty,

    pub fn init(gpa: std.mem.Allocator) ConcatExpression {
        return .{ .gpa = gpa };
    }

    /// 用一段文本构造（C# 的 `ConcatExpression(String)`，且 `DetectOr = false`）。
    pub fn initText(gpa: std.mem.Allocator, text: []const u8) !ConcatExpression {
        var self = init(gpa);
        try self.andText(text);
        return self;
    }

    pub fn deinit(self: *ConcatExpression) void {
        self.items.deinit(self.gpa);
    }

    /// 追加一段文本；空串忽略（与 C# 一致）。
    pub fn andText(self: *ConcatExpression, text: []const u8) !void {
        const e = Expression.initLiteral(text);
        if (e.isEmpty()) return;
        try self.items.append(self.gpa, .{ .raw = e });
    }

    /// 追加任意表达式；`Any.empty` 忽略（C# 里 `null` 直接返回 this）。
    pub fn append(self: *ConcatExpression, item: Any) !void {
        if (item.isEmpty()) return;
        try self.items.append(self.gpa, item);
    }

    pub fn isEmpty(self: *const ConcatExpression) bool {
        return self.items.items.len == 0;
    }

    pub fn renderInto(
        self: *const ConcatExpression,
        gpa: std.mem.Allocator,
        kind: DatabaseKind,
        params: ?*std.ArrayList(Value),
        b: *Buf,
    ) RenderError!void {
        for (self.items.items, 0..) |item, i| {
            if (i > 0) try b.add(",");
            try item.renderInto(gpa, kind, params, b);
        }
    }

    /// 渲染成一段文本（调用方 free）。
    pub fn renderAlloc(
        self: *const ConcatExpression,
        gpa: std.mem.Allocator,
        kind: DatabaseKind,
        params: ?*std.ArrayList(Value),
    ) ![]u8 {
        var b = Buf.init(gpa);
        defer b.deinit();
        try self.renderInto(gpa, kind, params, &b);
        return b.toOwnedSlice();
    }
};

// ============================ 内部辅助 ============================

/// 是否含独立单词 `Or`（等价 C# 正则 `\bOr\b`，忽略大小写）。
pub fn containsWordOr(text: []const u8) bool {
    if (text.len < 2) return false;
    var i: usize = 0;
    while (i + 2 <= text.len) : (i += 1) {
        const c0 = text[i];
        const c1 = text[i + 1];
        if (std.ascii.toLower(c0) != 'o' or std.ascii.toLower(c1) != 'r') continue;
        // 前边界
        if (i > 0 and isWordByte(text[i - 1])) continue;
        // 后边界
        if (i + 2 < text.len and isWordByte(text[i + 2])) continue;
        return true;
    }
    return false;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// 格式串里是否有某号占位符（`{n}`）；`{{` 视为转义的左花括号。
fn containsPlaceholder(format: []const u8, index: usize) bool {
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '{') continue;
        if (i + 1 < format.len and format[i + 1] == '{') {
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, format, i + 1, '}') orelse return false;
        const token = std.mem.trim(u8, format[i + 1 .. close], " \t");
        const value = std.fmt.parseInt(usize, token, 10) catch {
            i = close;
            continue;
        };
        if (value == index) return true;
        i = close;
    }
    return false;
}

/// 把 `{0}` / `{1}` 替换成给定文本，`{{` → `{`、`}}` → `}`。
fn pushFormatted(b: *Buf, format: []const u8, arg0: []const u8, arg1: []const u8) !void {
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        const c = format[i];
        if (c == '{') {
            if (i + 1 < format.len and format[i + 1] == '{') {
                try b.addByte('{');
                i += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, format, i + 1, '}') orelse {
                try b.addByte(c);
                continue;
            };
            const token = std.mem.trim(u8, format[i + 1 .. close], " \t");
            const value = std.fmt.parseInt(usize, token, 10) catch {
                // 不是数字占位符，原样输出
                try b.add(format[i .. close + 1]);
                i = close;
                continue;
            };
            switch (value) {
                0 => try b.add(arg0),
                1 => try b.add(arg1),
                else => try b.add(""), // 更后面的占位符无值可填，等价 C# 的 FormatException 兜底（这里静默留空）
            }
            i = close;
            continue;
        }
        if (c == '}' and i + 1 < format.len and format[i + 1] == '}') {
            try b.addByte('}');
            i += 1;
            continue;
        }
        try b.addByte(c);
    }
}

// ============================ 测试 ============================

const testing = std.testing;

fn renderAnyAlloc(item: Any, kind: DatabaseKind, params: ?*std.ArrayList(Value)) ![]u8 {
    var b = Buf.init(testing.allocator);
    defer b.deinit();
    try item.renderInto(testing.allocator, kind, params, &b);
    return b.toOwnedSlice();
}

test "Expression：Or 自动加括号" {
    const a = try renderAnyAlloc(.{ .raw = Expression.init("a = 1 Or b = 2") }, .sqlite, null);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("(a = 1 Or b = 2)", a);

    const b = try renderAnyAlloc(.{ .raw = Expression.init("a = 1 and b = 2") }, .sqlite, null);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("a = 1 and b = 2", b);

    // OR 出现在标识符内部不算
    const c = try renderAnyAlloc(.{ .raw = Expression.init("OrderId = 1") }, .sqlite, null);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("OrderId = 1", c);

    // 关闭检测
    const d = try renderAnyAlloc(.{ .raw = Expression.initLiteral("a Or b") }, .sqlite, null);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("a Or b", d);
}

test "FieldExpression：按方言引用列名" {
    const a = try renderAnyAlloc(.{ .field = FieldExpression.init("Name") }, .mysql, null);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("`Name`", a);

    const b = try renderAnyAlloc(.{ .field = FieldExpression.init("Name") }, .sqlserver, null);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("[Name]", b);

    const c = try renderAnyAlloc(.{ .field = FieldExpression.init("Name") }, .sqlite, null);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("\"Name\"", c);
}

test "FormatExpression：非参数化内联字面量" {
    const text = try renderAnyAlloc(
        .{ .format = FormatExpression.init("Age", "{0} > {1}", .{ .int = 18 }) },
        .sqlite,
        null,
    );
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("\"Age\" > 18", text);

    // 字符串转义
    const s = try renderAnyAlloc(
        .{ .format = FormatExpression.init("Name", "{0} = {1}", .{ .text = "O'Brien" }) },
        .sqlite,
        null,
    );
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"Name\" = 'O''Brien'", s);

    // 不需要右值
    const n = try renderAnyAlloc(
        .{ .format = FormatExpression.init("Deleted", "{0} IS NULL", null) },
        .sqlite,
        null,
    );
    defer testing.allocator.free(n);
    try testing.expectEqualStrings("\"Deleted\" IS NULL", n);

    // 右值为 null 且格式要用 {1} → NULL
    const z = try renderAnyAlloc(
        .{ .format = FormatExpression.init("Deleted", "{0} = {1}", null) },
        .sqlite,
        null,
    );
    defer testing.allocator.free(z);
    try testing.expectEqualStrings("\"Deleted\" = NULL", z);
}

test "FormatExpression：参数化占位符" {
    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(testing.allocator);

    const sqlite_text = try renderAnyAlloc(
        .{ .format = FormatExpression.init("Age", "{0} >= {1}", .{ .int = 18 }) },
        .sqlite,
        &params,
    );
    defer testing.allocator.free(sqlite_text);
    try testing.expectEqualStrings("\"Age\" >= ?", sqlite_text);
    try testing.expectEqual(@as(usize, 1), params.items.len);
    try testing.expectEqual(@as(i64, 18), params.items[0].int);

    // 第二个参数用递增占位符
    const sqlserver_text = try renderAnyAlloc(
        .{ .format = FormatExpression.init("Age", "{0} < {1}", .{ .int = 60 }) },
        .sqlserver,
        &params,
    );
    defer testing.allocator.free(sqlserver_text);
    try testing.expectEqualStrings("[Age] < @p1", sqlserver_text);
    try testing.expectEqual(@as(usize, 2), params.items.len);
}

test "FormatExpression：转义花括号与未知占位符" {
    const t = try renderAnyAlloc(
        .{ .format = FormatExpression.init("Amount", "{0} > 0 AND {{x}} = 1", null) },
        .sqlite,
        null,
    );
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("\"Amount\" > 0 AND {x} = 1", t);
}

test "ConcatExpression：逗号拼接与嵌套" {
    var inner = ConcatExpression.init(testing.allocator);
    defer inner.deinit();
    try inner.andText("COUNT(*)");
    try inner.append(.{ .field = FieldExpression.init("Status") });

    var outer = ConcatExpression.init(testing.allocator);
    defer outer.deinit();
    try outer.append(.{ .field = FieldExpression.init("Id") });
    try outer.append(.{ .concat = &inner });
    try outer.andText(""); // 空串忽略

    const text = try outer.renderAlloc(testing.allocator, .sqlite, null);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("\"Id\",COUNT(*),\"Status\"", text);
}

test "containsWordOr 边界" {
    try testing.expect(containsWordOr("a Or b"));
    try testing.expect(containsWordOr("OR"));
    try testing.expect(containsWordOr("x OR(y=1)"));
    try testing.expect(!containsWordOr("Order"));
    try testing.expect(!containsWordOr("For"));
    try testing.expect(!containsWordOr("oracle"));
    try testing.expect(!containsWordOr(""));
}
