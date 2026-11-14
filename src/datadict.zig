//! 数据字典（HTML）生成器（对应 C# `Code/HtmlBuilder.BuildDataDictionary`）。
//!
//! ## 用途
//!
//! 交付/评审时给业务方看的「这张表有哪些字段、什么类型、能不能空」。
//! C# 侧把整个 `Model` 渲染成一个 `.htm`（每张表一个 `<table>`），这里保持同样的版式：
//!
//! ```text
//! <style>…</style>
//! <h3>显示名（物理表名）</h3>
//! <table><thead>名称/显示名/类型/长度/精度/主键/允许空/备注</thead>
//!        <tbody>每个字段一行</tbody></table><br>
//! ```
//!
//! ## 「主键」列的三种标记（与 C# 一致）
//! - `AI`：自增列（`Identity`）
//! - `PK`：主键
//! - `UQ`：单列唯一索引（既不是主键也不是自增时）
//!
//! ## 与 C# 的差异（写清楚，别指望逐字节一致）
//! - C# 的「显示名」来自 `IDataColumn.DisplayName`（实体元数据提供）；本仓模型只有 `Description`，
//!   所以这里**把描述的首行当显示名、其余当备注**；
//! - C# 的「精度」列会和类型缺省精度比较后再决定是否显示；这里只要 `Precision > 0` 就显示
//!   `(p, s)`（decimal/numeric 才有），不猜缺省值；
//! - 输出是**一份字符串**（调用方自己写文件），不像 C# 那样直接落 `.htm`。

const std = @import("std");
const model = @import("model.zig");

pub const Options = struct {
    /// 页面标题（写进 `<title>`）
    title: []const u8 = "数据字典",
    /// 按 `Table@Name` 或 `Table@TableName` 排除整张表
    excludes: []const []const u8 = &.{},
    /// 按列名排除字段（所有表适用）
    exclude_columns: []const []const u8 = &.{},
    /// 是否内联样式（默认带；嵌进已有页面时可关掉）
    include_style: bool = true,
};

/// 内联样式（与 C# `HtmlBuilder.Style` 同版式：浅紫表头 + 斑马纹）
pub const default_style =
    \\table { border-collapse: collapse; border: 1px solid rgb(211, 202, 221); }
    \\table thead, table tr { border-top-width: 1px; border-top-style: solid; border-top-color: rgb(211, 202, 221); }
    \\table { border-bottom-width: 1px; border-bottom-style: solid; border-bottom-color: rgb(211, 202, 221); }
    \\table td, table th { padding: 5px 10px; font-size: 14px; font-family: Verdana; color: rgb(95, 74, 121); }
    \\table tr:nth-child(even) { background: rgb(223, 216, 232); }
    \\table tr:nth-child(odd) { background: #FFF; }
;

/// 生成整份数据字典 HTML（内存归 `a`）。
pub fn buildAlloc(a: std.mem.Allocator, m: *const model.EntityModel, opts: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    try out.appendSlice(a, "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>");
    try appendEscaped(a, &out, opts.title);
    try out.appendSlice(a, "</title>\n");
    if (opts.include_style) {
        try out.appendSlice(a, "<style>\n");
        try out.appendSlice(a, default_style);
        try out.appendSlice(a, "</style>\n");
    }
    try out.appendSlice(a, "</head>\n<body>\n");

    for (m.tables) |*t| {
        if (isExcluded(t, opts)) continue;
        try appendTable(a, &out, t, opts);
    }

    try out.appendSlice(a, "</body></html>\n");
    return out.toOwnedSlice(a);
}

/// 生成单张表的小节（`<h3>` + `<table>`），便于拼进已有文档。
pub fn tableAlloc(a: std.mem.Allocator, t: *const model.TableMeta, opts: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendTable(a, &out, t, opts);
    return out.toOwnedSlice(a);
}

fn appendTable(a: std.mem.Allocator, out: *std.ArrayList(u8), t: *const model.TableMeta, opts: Options) !void {
    const display = firstLine(t.description);
    // <h3>显示名（物理表名）</h3>；没有描述就只写表名（与 C# 同口径）
    if (display.len > 0) {
        try out.appendSlice(a, "<h3>");
        try appendEscaped(a, out, display);
        try out.appendSlice(a, "（");
        try appendEscaped(a, out, t.effectiveTableName());
        try out.appendSlice(a, "）</h3>\n");
    } else {
        try out.appendSlice(a, "<h3>");
        try appendEscaped(a, out, t.effectiveTableName());
        try out.appendSlice(a, "）</h3>\n");
    }

    try out.appendSlice(a,
        \\<table>
        \\<thead><tr>
        \\<th>名称</th><th>显示名</th><th>类型</th><th>长度</th><th>精度</th><th>主键</th><th>允许空</th><th>备注</th>
        \\</tr></thead>
        \\<tbody>
        \\
    );

    for (t.columns) |*col| {
        if (isColumnExcluded(col.name, opts)) continue;
        if (col.column_name) |cn| {
            if (!std.mem.eql(u8, cn, col.name) and isColumnExcluded(cn, opts)) continue;
        }

        const name = col.column_name orelse col.name;
        const desc = col.description;
        const col_display = firstLine(desc);
        const remark = restLines(desc);

        try out.appendSlice(a, "<tr><td>");
        try appendEscaped(a, out, name);
        try out.appendSlice(a, "</td><td>");
        try appendEscaped(a, out, col_display);
        try out.appendSlice(a, "</td><td>");
        // 类型：优先模型里写的原生类型，否则标准类型名（C# 是 RawType ?? DataType.FullName）
        if (col.raw_type) |rt| {
            if (rt.len > 0) try appendEscaped(a, out, rt) else try appendEscaped(a, out, col.data_type.name());
        } else {
            try appendEscaped(a, out, col.data_type.name());
        }
        try out.appendSlice(a, "</td><td>");
        if (col.length > 0) try appendInt(a, out, col.length);
        try out.appendSlice(a, "</td><td>");
        if (col.precision > 0) try appendPrecision(a, out, col.precision, col.scale);
        try out.appendSlice(a, "</td><td>");
        if (col.identity) {
            try out.appendSlice(a, "<span title=\"自增\">AI</span>");
        } else if (col.primary_key) {
            try out.appendSlice(a, "<span title=\"主键\">PK</span>");
        } else if (isSingleUnique(t, col)) {
            try out.appendSlice(a, "<span title=\"唯一索引\">UQ</span>");
        }
        try out.appendSlice(a, "</td><td>");
        if (!col.nullable) try out.appendSlice(a, "N");
        try out.appendSlice(a, "</td><td>");
        try appendEscaped(a, out, remark);
        try out.appendSlice(a, "</td></tr>\n");
    }

    try out.appendSlice(a, "</tbody>\n</table>\n<br></br>\n");
}

fn isExcluded(t: *const model.TableMeta, opts: Options) bool {
    for (opts.excludes) |x| {
        if (std.ascii.eqlIgnoreCase(x, t.name)) return true;
        if (std.ascii.eqlIgnoreCase(x, t.effectiveTableName())) return true;
    }
    return false;
}

fn isColumnExcluded(name: []const u8, opts: Options) bool {
    for (opts.exclude_columns) |x| {
        if (std.ascii.eqlIgnoreCase(x, name)) return true;
    }
    return false;
}

/// 单列唯一索引（C# 的 `UQ` 判定：`Unique && Columns.Length == 1 && 命中该列`）
fn isSingleUnique(t: *const model.TableMeta, col: *const model.ColumnMeta) bool {
    for (t.indexes) |idx| {
        if (!idx.unique or idx.columns.len != 1) continue;
        const c = idx.columns[0];
        if (std.ascii.eqlIgnoreCase(c, col.name)) return true;
        if (col.column_name) |cn| {
            if (std.ascii.eqlIgnoreCase(c, cn)) return true;
        }
    }
    return false;
}

/// 追加整数（0.17 的 `ArrayListUnmanaged` 没有 `writer()`，用 bufPrint 转一次）
fn appendInt(a: std.mem.Allocator, out: *std.ArrayList(u8), v: anytype) !void {
    var buf: [24]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try out.appendSlice(a, text);
}

/// 追加 `(precision, scale)`（C# 的「精度」列口径）
fn appendPrecision(a: std.mem.Allocator, out: *std.ArrayList(u8), precision: i32, scale: i32) !void {
    var buf: [40]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "({d}, {d})", .{ precision, scale });
    try out.appendSlice(a, text);
}

fn firstLine(text: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, text, '\n') orelse return std.mem.trim(u8, text, " \t\r\n");
    return std.mem.trim(u8, text[0..idx], " \t\r");
}

fn restLines(text: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, text, '\n') orelse return "";
    return std.mem.trim(u8, text[idx + 1 ..], " \t\r\n");
}

/// HTML 转义（`& < > " '`）——不转义的话描述里一个 `<` 就能把表格结构冲掉。
fn appendEscaped(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            '\'' => try out.appendSlice(a, "&#39;"),
            '\n' => try out.appendSlice(a, "<br>"),
            '\r' => {},
            else => try out.append(a, c),
        }
    }
}

// ── 用例 ────────────────────────────────────────────────────────────────────

fn dictModel(a: std.mem.Allocator) !model.EntityModel {
    const xml =
        \\<EntityModel><Tables>
        \\  <Table Name="Order" TableName="Shop_Order" Description="订单&#10;主表">
        \\    <Columns>
        \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\      <Column Name="OrderNo" DataType="String" Length="32" Description="单号&#10;业务生成" />
        \\      <Column Name="Amount" DataType="Decimal" Precision="18" Scale="2" Nullable="True" />
        \\      <Column Name="Secret" DataType="String" Length="10" Description="&lt;script&gt;" />
        \\    </Columns>
        \\    <Indexes><Index Columns="OrderNo" Unique="True" /></Indexes>
        \\  </Table>
        \\  <Table Name="Temp" TableName="Shop_Temp">
        \\    <Columns><Column Name="Id" DataType="Int32" PrimaryKey="True" /></Columns>
        \\  </Table>
        \\</Tables></EntityModel>
    ;
    return model.EntityModel.parse(a, xml);
}

test "数据字典 - 表头/字段行/主键标记/精度/可空" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try dictModel(a);
    const html = try buildAlloc(a, &m, .{ .title = "订单数据字典" });

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>订单数据字典</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<th>名称</th><th>显示名</th><th>类型</th>") != null);
    // 表的显示名取描述首行，括号里是物理表名
    try std.testing.expect(std.mem.indexOf(u8, html, "<h3>订单（Shop_Order）</h3>") != null);
    // 自增列标 AI
    try std.testing.expect(std.mem.indexOf(u8, html, "<span title=\"自增\">AI</span>") != null);
    // 单列唯一索引标 UQ
    try std.testing.expect(std.mem.indexOf(u8, html, "<span title=\"唯一索引\">UQ</span>") != null);
    // decimal(18,2)
    try std.testing.expect(std.mem.indexOf(u8, html, "(18, 2)") != null);
    // 可空列不写 N；Id 不可空写 N
    try std.testing.expect(std.mem.indexOf(u8, html, "<tr><td>Id</td><td></td><td>Int32</td><td></td><td></td><td><span title=\"自增\">AI</span></td><td>N</td>") != null);
}

test "数据字典 - 描述拆成显示名 + 备注，且做 HTML 转义" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try dictModel(a);
    const html = try buildAlloc(a, &m, .{});

    // OrderNo：显示名 = 首行「单号」，备注 = 第二行「业务生成」
    try std.testing.expect(std.mem.indexOf(u8, html, "<tr><td>OrderNo</td><td>单号</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "业务生成") != null);
    // 描述里的 <script> 必须被转义（否则会把表格结构冲掉）
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
}

test "数据字典 - excludes 按 Name 或 TableName 排除整张表 / 按列名排除字段" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try dictModel(a);

    const by_name = try buildAlloc(a, &m, .{ .excludes = &.{"Temp"} });
    try std.testing.expect(std.mem.indexOf(u8, by_name, "Shop_Order") != null);
    try std.testing.expect(std.mem.indexOf(u8, by_name, "Shop_Temp") == null);

    const by_table = try buildAlloc(a, &m, .{ .excludes = &.{"Shop_Temp"} });
    try std.testing.expect(std.mem.indexOf(u8, by_table, "Shop_Temp") == null);

    const no_secret = try buildAlloc(a, &m, .{ .exclude_columns = &.{"Secret"} });
    try std.testing.expect(std.mem.indexOf(u8, no_secret, "Secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, no_secret, "OrderNo") != null);
}

test "数据字典 - 单表小节可单独生成（拼进已有文档用）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try dictModel(a);
    const sec = try tableAlloc(a, &m.tables[0], .{});
    try std.testing.expect(std.mem.startsWith(u8, sec, "<h3>"));
    try std.testing.expect(std.mem.indexOf(u8, sec, "<!DOCTYPE") == null);
    try std.testing.expect(std.mem.indexOf(u8, sec, "</table>") != null);
}
