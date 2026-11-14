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
const model = @import("model.zig");
const DataType = @import("types.zig").DataType;

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

// ── 模糊匹配（≂ C# `LikeExpression`）────────────────────────────────────

/// 模糊匹配的四种模式（≂ C# `FieldItem` 的 `Contains` / `NotContains` / `StartsWith` / `EndsWith`）。
pub const LikeMode = enum {
    contains,
    not_contains,
    starts_with,
    ends_with,

    /// 格式串（与 C# `FieldItem` 里写死的完全一致；`{0}` 列名、`{1}` 值）
    pub fn format(self: LikeMode) []const u8 {
        return switch (self) {
            .contains => "{0} Like '%{1}%'",
            .not_contains => "{0} Not Like '%{1}%'",
            .starts_with => "{0} Like '{1}%'",
            .ends_with => "{0} Like '%{1}'",
        };
    }
};

pub const LikeError = error{ EmptyLikeValue, LikeOnNonStringColumn };

/// 模糊匹配表达式（≂ C# `LikeExpression`）。
///
/// **与 C# 的差异（显式写下，不偷偷改断言）**：
/// - 值一律**内联**（`'` → `''`、`%` → `\%`、`_` → `\_`，与 C# `FormatLike` 同一套转义），
///   **不提供参数化**：C# 的参数化分支输出 `'%@Name%'`（命名参数被写进引号里），
///   实际执行时不会被替换成值 —— 那是个已知坑，Zig 不复刻；
/// - 空值：C# 抛 `ArgumentNullException` → 这里 `error.EmptyLikeValue`；
///   非字符串列：C# 抛 `NotSupportedException` → 这里 `error.LikeOnNonStringColumn`。
pub const LikeExpression = struct {
    /// 物理列名
    column: []const u8,
    format: []const u8,
    value: []const u8,

    pub fn isEmpty(self: LikeExpression) bool {
        return self.column.len == 0 or std.mem.trim(u8, self.format, " \t\r\n").len == 0;
    }

    pub fn renderInto(
        self: LikeExpression,
        gpa: std.mem.Allocator,
        kind: DatabaseKind,
        params: ?*std.ArrayList(Value),
        b: *Buf,
    ) !void {
        // 见类型注释：LIKE 值一律内联，不走参数
        _ = params;
        if (self.isEmpty()) return;

        const quoted = try kind.quoteAlloc(gpa, self.column);
        defer gpa.free(quoted);
        const escaped = try escapeLikeAlloc(gpa, self.value);
        defer gpa.free(escaped);
        try pushFormatted(b, self.format, quoted, escaped);
    }
};

/// 构造模糊匹配表达式（列必须是字符串列、值不能为空 —— 与 C# 的异常口径对齐）。
pub fn like(col: *const model.ColumnMeta, mode: LikeMode, value: []const u8) LikeError!LikeExpression {
    if (value.len == 0) return LikeError.EmptyLikeValue;
    if (col.data_type != .string) return LikeError.LikeOnNonStringColumn;
    return .{ .column = col.name, .format = mode.format(), .value = value };
}

/// LIKE 转义（≂ C# `DbBase.FormatLike`）。
///
/// C# 只在值里出现 `'` / `%` / `_` 时才处理，处理顺序是 `'→''`、`%→\%`、`_→\_`；
/// 单趟逐字符替换与「连续三次 Replace」结果相同（插入的字符不会被再次扫描）。
pub fn escapeLikeAlloc(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, value, "'%_") == null) return gpa.dupe(u8, value);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, value.len + 8);
    for (value) |c| {
        switch (c) {
            '\'' => try out.appendSlice(gpa, "''"),
            '%' => try out.appendSlice(gpa, "\\%"),
            '_' => try out.appendSlice(gpa, "\\_"),
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

// ── 集合匹配（≂ C# `InExpression`）──────────────────────────────────────

/// `In` 的右值形态（≂ C# `InExpression.Value` 的三种来源）。
pub const InSource = union(enum) {
    /// 值列表（C# `In(IEnumerable)`）；**只剩一项时按 C# 语义退化成 `=` / `<>`**
    values: []const Value,
    /// 逗号分隔文本（C# `In(String)`，C# 注释自己都写着「可能有注入风险」）
    text: []const u8,
    /// 子查询 SQL 文本（C# `In(SelectBuilder)`；本仓传 `sqlbuild` 渲染好的 SQL）
    subquery: []const u8,
};

pub const InError = error{ EmptyInValues, EmptyInText };

/// 集合匹配表达式（≂ C# `InExpression`）。
///
/// 口径（逐条照 C#）：
/// - 值列表**去重且保序**；去重后只剩一项 → 退化成 `列 = 值` / `列 <> 值`（C# `_In` 的行为）；
/// - 文本形态按 `,` 切分，**丢掉空段与含 `%` 的段**（C# 为兼容 `in("a,b")` 与 `like "%,x,%"` 混写），
///   切完仍多于一项才逐项格式化，否则**整段当一个值**（C# 就是 `FormatValue(column, Value)`）；
/// - 值按**列类型**格式化：字符串/日期/二进制加引号（`''` 双写），数值型原样输出。
///
/// 差异：Zig 对每段做 `trim`（C# 不 trim，`"a, b"` 会得到字面量 `' b'`）。
pub const InExpression = struct {
    /// 物理列名
    column: []const u8,
    column_type: DataType = .string,
    negate: bool = false,
    source: InSource,

    pub fn isEmpty(self: InExpression) bool {
        return self.column.len == 0 or switch (self.source) {
            .values => |v| v.len == 0,
            .text => |t| std.mem.trim(u8, t, " \t").len == 0,
            .subquery => |s| std.mem.trim(u8, s, " \t\r\n").len == 0,
        };
    }

    /// 渲染。`params == null` 表示非参数化（值内联为字面量）。
    ///
    /// 只有 `.values` 形态支持参数化（C# 同样如此：文本与子查询不走参数）。
    pub fn renderInto(
        self: InExpression,
        gpa: std.mem.Allocator,
        kind: DatabaseKind,
        params: ?*std.ArrayList(Value),
        b: *Buf,
    ) !void {
        if (self.isEmpty()) return;

        const quoted = try kind.quoteAlloc(gpa, self.column);
        defer gpa.free(quoted);

        switch (self.source) {
            .values => |values| {
                // 只有一项 → 等于/不等于（C# `_In` 的行为）
                if (values.len == 1) {
                    try b.add(quoted);
                    try b.add(if (self.negate) " <> " else " = ");
                    try pushValue(gpa, kind, params, b, values[0]);
                    return;
                }
                try b.add(quoted);
                try b.add(if (self.negate) " Not In(" else " In(");
                for (values, 0..) |v, i| {
                    if (i > 0) try b.add(",");
                    try pushValue(gpa, kind, params, b, v);
                }
                try b.add(")");
            },
            .text => |text| {
                try b.add(quoted);
                try b.add(if (self.negate) " Not In(" else " In(");
                try pushInText(gpa, self.column_type, b, text);
                try b.add(")");
            },
            .subquery => |sql| {
                try b.add(quoted);
                try b.add(if (self.negate) " Not In(" else " In(");
                try b.add(sql);
                try b.add(")");
            },
        }
    }
};

/// 构造值列表形态（去重保序；空列表报错，对应 C# 抛 `ArgumentNullException`）。
pub fn inValues(
    a: std.mem.Allocator,
    col: *const model.ColumnMeta,
    values: []const Value,
    negate: bool,
) !InExpression {
    if (values.len == 0) return InError.EmptyInValues;

    var list: std.ArrayList(Value) = .empty;
    errdefer list.deinit(a);
    try list.ensureTotalCapacity(a, values.len);
    for (values) |v| {
        var dup = false;
        for (list.items) |seen| {
            if (valueEql(seen, v)) {
                dup = true;
                break;
            }
        }
        if (!dup) list.appendAssumeCapacity(v);
    }
    return .{
        .column = col.name,
        .column_type = col.data_type,
        .negate = negate,
        .source = .{ .values = try list.toOwnedSlice(a) },
    };
}

/// 构造文本形态（空串报错，对应 C# 抛 `ArgumentNullException`）。
pub fn inText(col: *const model.ColumnMeta, text: []const u8, negate: bool) InError!InExpression {
    if (std.mem.trim(u8, text, " \t").len == 0) return InError.EmptyInText;
    return .{
        .column = col.name,
        .column_type = col.data_type,
        .negate = negate,
        .source = .{ .text = text },
    };
}

/// 构造子查询形态（空串报错）。
pub fn inSubquery(col: *const model.ColumnMeta, sql: []const u8, negate: bool) InError!InExpression {
    if (std.mem.trim(u8, sql, " \t\r\n").len == 0) return InError.EmptyInText;
    return .{
        .column = col.name,
        .column_type = col.data_type,
        .negate = negate,
        .source = .{ .subquery = sql },
    };
}

/// 两个值是否相等（去重用；数值型之间允许跨类型相等，如 `1` 与 `1.0`）。
fn valueEql(x: Value, y: Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) {
        if (isNumericValue(x) and isNumericValue(y)) {
            const xf = x.asF64() orelse return false;
            const yf = y.asF64() orelse return false;
            return xf == yf;
        }
        return false;
    }
    return switch (x) {
        .null => true,
        .boolean => |v| v == y.boolean,
        .int => |v| v == y.int,
        .float => |v| v == y.float,
        .decimal => |v| v.eql(y.decimal),
        .text => |v| std.mem.eql(u8, v, y.text),
        .blob => |v| std.mem.eql(u8, v, y.blob),
        .datetime => |v| v.eql(y.datetime),
    };
}

fn isNumericValue(v: Value) bool {
    return switch (v) {
        .boolean, .int, .float, .decimal => true,
        else => false,
    };
}

/// 输出一个值：参数化时进参数列表并写占位符，否则内联字面量。
fn pushValue(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    params: ?*std.ArrayList(Value),
    b: *Buf,
    v: Value,
) !void {
    if (params) |list| {
        var ph = Buf.init(gpa);
        defer ph.deinit();
        try kind.pushPlaceholder(&ph, list.items.len);
        try b.add(ph.slice());
        try list.append(gpa, v);
        return;
    }
    const lit = try v.toSqlLiteralAlloc(gpa);
    defer gpa.free(lit);
    try b.add(lit);
}

/// 文本形态：按 `,` 切分 → 丢空段与含 `%` 的段 → 多于一项才逐项格式化，否则整段当一个值。
fn pushInText(gpa: std.mem.Allocator, col_type: DataType, b: *Buf, text: []const u8) !void {
    var pieces: std.ArrayList([]const u8) = .empty;
    defer pieces.deinit(gpa);

    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        if (std.mem.indexOfScalar(u8, p, '%') != null) continue;
        try pieces.append(gpa, p);
    }

    if (pieces.items.len > 1) {
        for (pieces.items, 0..) |p, i| {
            if (i > 0) try b.add(",");
            try pushColumnValue(gpa, col_type, b, p);
        }
        return;
    }
    try pushColumnValue(gpa, col_type, b, text);
}

/// 按列类型输出一个文本片段：数值型原样（能解析成数字时），其余加引号。
fn pushColumnValue(gpa: std.mem.Allocator, col_type: DataType, b: *Buf, text: []const u8) !void {
    const t = std.mem.trim(u8, text, " \t");
    const numeric = switch (col_type) {
        .boolean, .byte, .int16, .int32, .int64, .single, .double, .decimal => true,
        else => false,
    };
    if (numeric and t.len > 0) {
        if (std.fmt.parseFloat(f64, t)) |_| {
            try b.add(t);
            return;
        } else |_| {}
    }
    const lit = try (Value{ .text = t }).toSqlLiteralAlloc(gpa);
    defer gpa.free(lit);
    try b.add(lit);
}

/// 表达式联合：便于把不同类型的表达式放进同一个列表。
pub const Any = union(enum) {
    empty,
    raw: Expression,
    field: FieldExpression,
    format: FormatExpression,
    like: LikeExpression,
    in_list: InExpression,
    concat: *const ConcatExpression,

    pub fn isEmpty(self: Any) bool {
        return switch (self) {
            .empty => true,
            .raw => |e| e.isEmpty(),
            .field => |e| e.isEmpty(),
            .format => |e| e.isEmpty(),
            .like => |e| e.isEmpty(),
            .in_list => |e| e.isEmpty(),
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
            .like => |e| try e.renderInto(gpa, kind, params, b),
            .in_list => |e| try e.renderInto(gpa, kind, params, b),
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
