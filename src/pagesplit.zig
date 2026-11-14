//! MS SQL Server 传统分页算法（对应 DH.NCode `DataAccessLayer/MSPageSplit`）。
//!
//! SQL Server 2012 之前没有 `OFFSET..FETCH`，XCode 用四套算法兜底，本模块逐条移植：
//!
//! | 算法 | 适用 | 生成的形状 |
//! |---|---|---|
//! | `rowNumber`（2005+） | 任何排序列 | `SELECT * FROM (SELECT *, row_number() over(...) as rowNumber FROM t) X WHERE rowNumber BETWEEN a AND b` |
//! | `maxMin` | 数字主键且**排序就是主键** | `WHERE Key > (SELECT Max(Key) FROM (SELECT TOP n Key ...))` |
//! | `doubleTop` | 有排序、页大小已知 | 三层 `TOP` 嵌套（倒序取完再正序还原） |
//! | `topNotIn` | 只有一个排序列（最通用、也最慢） | `WHERE Key Not In (SELECT TOP n Key ...)` |
//!
//! 选择顺序与 C# `MSPageSplit.PageSplit` 完全一致：首页按主键排序时直接 `TOP n` →
//! 2005 走 `rowNumber` → 数字主键且按主键排序走 `maxMin` → 页大小 > 0 走 `doubleTop` → 否则 `topNotIn`。
//!
//! 约定与限制（与 C# 一致，但这里写明）：
//! - 生成的是 **SQL Server 语法**（`Select Top n`）：SQLite/MySQL 不要用，它们走 `dialect.applyPagingAlloc`；
//! - 本模块只重排**结构**、不绑定参数：`Spec.where` 用字面量。若必须带参，
//!   `topNotIn` / `maxMin` 的 `where` 会出现两次（外层一次 + 子查询一次），参数要按同序重复；
//!   `rowNumber` / `doubleTop` 的 `where` 只出现一次。

const std = @import("std");
const Buf = @import("zzig").Buf;

/// 深分页倒序优化（≂ C# `Entity.FindAll` 里的「海量数据查询优化」）。
///
/// 背景：`LIMIT n OFFSET 900000` 这种深页，数据库要把前面 90 万行都扫一遍再丢掉。
/// C# 的做法是——**偏移过半时把排序反过来、从尾部取，取回来再在内存里翻一次**，
/// 这样扫描量从 90 万降到 10 万。
///
/// 三条门槛与 C# 一致（`startRowIndex > 500_000`、`count > 1_000_000`、`startRowIndex * 2 > count`），
/// 但做成可配置字段：亿级表的实际阈值未必一样，也因为集成用例要用小表验证这套逻辑
/// （常量写死就只能靠人工推理，测不了）。
pub const DeepPage = struct {
    /// 偏移超过它才考虑倒序（C# 500_000）
    min_offset: usize = 500_000,
    /// 总行数超过它才考虑倒序（C# 1_000_000）
    min_total: i64 = 1_000_000,

    /// 是否值得倒序取尾部。
    ///
    /// `page_size` 只用于「尾部对齐」的边界判断（见 `reversedOffset`），
    /// 这里保留参数是为了调用方同签名使用、避免两处口径漂移。
    pub fn shouldReverse(self: DeepPage, offset: usize, page_size: usize, total: i64) bool {
        _ = page_size;
        if (offset <= self.min_offset) return false;
        if (total <= self.min_total) return false;
        const o: i64 = @intCast(offset);
        return o * 2 > total;
    }

    /// 倒序后的偏移：原页覆盖 `[offset, offset + page_size)`，
    /// 倒序后覆盖 `[total - offset - page_size, total - offset)`。
    ///
    /// 该页不在表尾完整范围内（`total - offset - page_size < 0`）、或 `page_size == 0` 时返回 null。
    pub fn reversedOffset(self: DeepPage, offset: usize, page_size: usize, total: i64) ?usize {
        _ = self;
        if (page_size == 0) return null;
        const t = total;
        const o: i64 = @intCast(offset);
        const p: i64 = @intCast(page_size);
        const start = t - o - p;
        if (start < 0) return null;
        return @intCast(start);
    }

    /// 一次给出结论：`null` = 不值得倒序（按原样查）。
    pub fn plan(self: DeepPage, offset: usize, page_size: usize, total: i64) ?usize {
        if (!self.shouldReverse(offset, page_size, total)) return null;
        return self.reversedOffset(offset, page_size, total);
    }
};

/// 分页规格（对应 C# `SelectBuilder` 里用得着的那几个字段）。
pub const Spec = struct {
    /// 表名或子查询（`(Select ...) X` 由调用方自己拼）
    table: []const u8,
    /// 选择列；null/空 = `*`
    column: ?[]const u8 = null,
    /// 条件（不含 `Where` 关键字）
    where: ?[]const u8 = null,
    group_by: ?[]const u8 = null,
    having: ?[]const u8 = null,
    /// 排序（不含 `Order By`）——`doubleTop` 会把它反过来再还原
    order_by: ?[]const u8 = null,
    /// 分页主键（C# `Key`）；缺省取 `order_by` 的首字段
    key: ?[]const u8 = null,
    /// 该键是否为整数（C# `IsInt`）：只有整数键能走 `maxMin`
    key_is_int: bool = false,

    /// 实际使用的分页键：显式 `key` 优先，否则取 `order_by` 首字段（不是 `asc/desc` 关键字时）。
    pub fn effectiveKey(self: Spec) ?[]const u8 {
        if (self.key) |k| {
            if (k.len > 0) return k;
        }
        const first = firstToken(self.order_by orelse return null) orelse return null;
        if (isDirection(first)) return null;
        return first;
    }

    /// 排序是否以主键开头（C# `KeyIsOrderBy`）。
    pub fn keyIsOrderBy(self: Spec) bool {
        const key = self.effectiveKey() orelse return false;
        const order = self.order_by orelse return false;
        return std.mem.startsWith(u8, order, key);
    }

    /// 主键是否降序（`Id Desc` → true）。
    fn isDesc(self: Spec, key: []const u8) bool {
        const order = self.order_by orelse return false;
        var it = std.mem.splitScalar(u8, order, ',');
        while (it.next()) |part| {
            var tokens = std.mem.tokenizeAny(u8, part, " \t");
            const col = tokens.next() orelse continue;
            if (!std.ascii.eqlIgnoreCase(col, key)) continue;
            const dir = tokens.next() orelse return false;
            return std.ascii.eqlIgnoreCase(dir, "desc");
        }
        return false;
    }
};

fn isDirection(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "asc") or std.ascii.eqlIgnoreCase(token, "desc");
}

fn firstToken(text: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    return it.next();
}

/// 一个只做「列/表/条件/排序/Top/子查询」的 SQL 片段器（C# `SelectBuilder` 的最小子集）。
pub const Builder = struct {
    gpa: std.mem.Allocator,
    column: ?[]const u8 = null,
    table: []const u8,
    where: ?[]const u8 = null,
    having: ?[]const u8 = null,
    order_by: ?[]const u8 = null,
    top_n: ?i64 = null,
    /// `where` / `table` 是否由本结构自己分配（`deinit` 时释放）
    own_where: bool = false,
    own_table: bool = false,

    pub fn fromSpec(gpa: std.mem.Allocator, spec: Spec) Builder {
        return .{
            .gpa = gpa,
            .column = spec.column,
            .table = spec.table,
            .where = spec.where,
            .having = spec.having,
            .order_by = spec.order_by,
        };
    }

    pub fn deinit(self: *const Builder) void {
        if (self.own_where) {
            if (self.where) |w| self.gpa.free(w);
        }
        if (self.own_table) self.gpa.free(self.table);
    }

    /// `Top n [key_column]`：把列改成 `Top n <列>`（C# `Top`）。
    pub fn top(self: *Builder, n: i64, key_column: ?[]const u8) void {
        if (key_column) |k| self.column = k;
        if (self.column == null or self.column.?.len == 0) self.column = "*";
        self.top_n = n;
    }

    /// 追加 `And` 条件（C# `AppendWhereAnd`：原条件含 OR 时先加括号）。
    pub fn appendWhereAnd(self: *Builder, extra: []const u8) !void {
        var b = Buf.init(self.gpa);
        errdefer b.deinit();

        if (self.own_where) {
            // 之前已经拼过一次：先按新内容重拼，最后释放旧的
        }
        if (self.where) |w| {
            if (w.len > 0) {
                const need_paren = std.mem.indexOfScalar(u8, w, ' ') != null and containsIgnoreCase(w, "or");
                if (need_paren) {
                    try b.add("(");
                    try b.add(w);
                    try b.add(")");
                } else {
                    try b.add(w);
                }
                try b.add(" And ");
            }
        }
        try b.add(extra);

        const new_where = try b.toOwnedSlice();
        if (self.own_where) {
            if (self.where) |old| self.gpa.free(old);
        }
        self.where = new_where;
        self.own_where = true;
    }

    /// 作为子查询（C# `AsChild(alias, trimOrder: true)`）。
    ///
    /// 内层有排序且**不是** `Top` 查询时：内层去排序、外层补回
    /// （SQL Server 不允许子查询里无 TOP 的 ORDER BY）。
    pub fn asChild(self: *const Builder, alias: []const u8) !Builder {
        const has_order_without_top = self.top_n == null and self.order_by != null and self.order_by.?.len > 0;

        var inner = self.*;
        if (has_order_without_top) inner.order_by = null;

        const inner_sql = try inner.toStringAlloc(self.gpa);
        defer self.gpa.free(inner_sql);

        const table = try std.fmt.allocPrint(self.gpa, "({s}) {s}", .{ inner_sql, alias });
        return .{
            .gpa = self.gpa,
            .table = table,
            .order_by = if (has_order_without_top) self.order_by else null,
            .own_table = true,
        };
    }

    /// 有 GroupBy 时作为子查询，否则普通克隆（C# `CloneWithGroupBy`）。
    pub fn cloneWithGroupBy(self: *const Builder, alias: []const u8, group_by: ?[]const u8) !Builder {
        if (group_by == null or group_by.?.len == 0) return self.*;
        var x = self.*;
        x.top_n = null;
        return x.asChild(alias);
    }

    /// 渲染 `Select ... From ...`（对应 C# `ToString`）。
    pub fn toStringAlloc(self: *const Builder, gpa: std.mem.Allocator) ![]u8 {
        var b = Buf.init(gpa);
        defer b.deinit();

        try b.add("Select ");
        if (self.top_n) |n| try b.fmt("Top {d} ", .{n});
        if (self.column) |c| {
            try b.add(if (c.len > 0) c else "*");
        } else {
            try b.add("*");
        }
        try b.add(" From ");
        try b.add(self.table);
        if (self.where) |w| {
            if (w.len > 0) {
                try b.add(" Where ");
                try b.add(w);
            }
        }
        if (self.having) |h| {
            if (h.len > 0) {
                try b.add(" Having ");
                try b.add(h);
            }
        }
        if (self.order_by) |o| {
            if (o.len > 0) {
                try b.add(" Order By ");
                try b.add(o);
            }
        }
        return b.toOwnedSlice();
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// 排序串里有多少个字段（`Id Desc, Name` → 2）。
fn countKeys(order: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, order, ',');
    while (it.next()) |part| {
        if (firstToken(part)) |_| n += 1;
    }
    return n;
}

/// 分页算法选择（C# `MSPageSplit.PageSplit`）。
///
/// - `start_row`：起始行，0 表示第一行
/// - `maximum_rows`：本页行数，0/负数 = 「从 start_row 到末尾」
/// - `is_sql2005`：true 走 `rowNumber`（SQL Server 2005+ 才有窗口函数）
pub fn pageSplitAlloc(
    gpa: std.mem.Allocator,
    spec: Spec,
    start_row: i64,
    maximum_rows: i64,
    is_sql2005: bool,
) ![]u8 {
    // 首页：按主键排序时不必进子查询
    if (start_row <= 0) {
        if (maximum_rows < 1) return specToStringAlloc(gpa, spec);
        if (spec.keyIsOrderBy()) {
            var b = Builder.fromSpec(gpa, spec);
            b.top(maximum_rows, null);
            return b.toStringAlloc(gpa);
        }
    }

    if (spec.effectiveKey() == null) return error.NoKey;

    if (is_sql2005) return rowNumberAlloc(gpa, spec, start_row, maximum_rows);
    if (spec.key_is_int and spec.keyIsOrderBy()) return maxMinAlloc(gpa, spec, start_row, maximum_rows);
    if (maximum_rows > 0) return doubleTopAlloc(gpa, spec, start_row, maximum_rows, null);
    return topNotInAlloc(gpa, spec, start_row, maximum_rows);
}

fn specToStringAlloc(gpa: std.mem.Allocator, spec: Spec) ![]u8 {
    const b = Builder.fromSpec(gpa, spec);
    return b.toStringAlloc(gpa);
}

/// 最经典的 `Not In` 分页：通用但最慢，只允许单一主键列。
pub fn topNotInAlloc(gpa: std.mem.Allocator, spec: Spec, start_row: i64, maximum_rows: i64) ![]u8 {
    const key = spec.effectiveKey() orelse return error.NoKey;
    const order = spec.order_by orelse return error.NoKey;
    if (countKeys(order) != 1) return error.SingleKeyRequired;

    // 子查询：Select Top start_row [key] From ... [Where ...] [Order By ...]
    var b1 = Builder.fromSpec(gpa, spec);
    b1.top(start_row, key);
    const sub = try b1.toStringAlloc(gpa);
    defer gpa.free(sub);

    var b2 = try Builder.fromSpec(gpa, spec).cloneWithGroupBy("XCode_T0", spec.group_by);
    defer b2.deinit();
    if (maximum_rows >= 1) b2.top(maximum_rows, null);

    const cond = try std.fmt.allocPrint(gpa, "{s} Not In({s})", .{ key, sub });
    defer gpa.free(cond);
    try b2.appendWhereAnd(cond);

    // 结果列：原样；含 `.`（多表列）时取子查询全部列
    b2.column = spec.column;
    if (spec.column) |c| {
        if (std.mem.indexOfScalar(u8, c, '.') != null) b2.column = "*";
    }

    return b2.toStringAlloc(gpa);
}

/// 双 Top 分页：比 Not In 快，但必须带排序。
///
/// `count_ctx` / `count_fn`：可选的「总行数回调」（C# `queryCountCallback`）。
/// 给了就用它把最后一页的页大小收窄——否则最后一页会取不满。
pub fn doubleTopAlloc(
    gpa: std.mem.Allocator,
    spec: Spec,
    start_row: i64,
    maximum_rows: i64,
    count_fn: ?*const fn (ctx: *const anyopaque, spec: Spec) i64,
) ![]u8 {
    return doubleTopWithAlloc(gpa, spec, start_row, maximum_rows, null, count_fn);
}

fn doubleTopWithAlloc(
    gpa: std.mem.Allocator,
    spec: Spec,
    start_row: i64,
    maximum_rows: i64,
    count_ctx: ?*const anyopaque,
    count_fn: ?*const fn (ctx: *const anyopaque, spec: Spec) i64,
) ![]u8 {
    const key = spec.effectiveKey() orelse return error.NoKey;
    const orderby = spec.order_by orelse key;

    var max_rows = maximum_rows;
    if (count_fn) |f| {
        const ctx = count_ctx orelse return error.MissingCountContext;
        const count = f(ctx, spec);
        if (count <= start_row) return error.EmptyPage;
        if (start_row + max_rows > count) max_rows = count - start_row;
    }

    const reversed = try reverseOrderAlloc(gpa, orderby);
    defer gpa.free(reversed);

    // 1) Select Top (start+max) [排序字段] From ...
    var b1 = Builder.fromSpec(gpa, spec);
    const keys_csv = try keysCsvAlloc(gpa, orderby);
    defer gpa.free(keys_csv);
    b1.column = keys_csv;
    b1.top(start_row + max_rows, null);
    if (b1.order_by == null or b1.order_by.?.len == 0) b1.order_by = key;

    // 2) 倒序取本页
    var b2 = try b1.asChild("XCode_T0");
    defer b2.deinit();
    b2.top(max_rows, null);
    b2.order_by = reversed;

    // 3) 再翻回正序，只取需要的列
    var b3 = try b2.asChild("XCode_T1");
    defer b3.deinit();
    b3.column = spec.column;
    if (spec.column) |c| {
        if (std.mem.indexOfScalar(u8, c, '.') != null) b3.column = "*";
    }
    b3.order_by = orderby;

    return b3.toStringAlloc(gpa);
}

/// 数字主键最大最小分页：性能最好，要求「单一数字主键且排序就是主键」。
pub fn maxMinAlloc(gpa: std.mem.Allocator, spec: Spec, start_row: i64, maximum_rows: i64) ![]u8 {
    const key = spec.effectiveKey() orelse return error.NoKey;
    const order = spec.order_by orelse return error.NoKey;
    if (countKeys(order) != 1) return error.SingleKeyRequired;

    const desc = spec.isDesc(key);

    var b1 = Builder.fromSpec(gpa, spec);
    b1.top(start_row, key);
    const sub1 = try b1.toStringAlloc(gpa);
    defer gpa.free(sub1);

    const sub2 = try std.fmt.allocPrint(
        gpa,
        "Select {s}({s}) From ({s}) XCode_T0",
        .{ if (desc) "Min" else "Max", key, sub1 },
    );
    defer gpa.free(sub2);

    var b3 = try Builder.fromSpec(gpa, spec).cloneWithGroupBy("XCode_T1", spec.group_by);
    defer b3.deinit();
    if (maximum_rows >= 1) b3.top(maximum_rows, null);

    const cond = try std.fmt.allocPrint(gpa, "{s}{s}({s})", .{ key, if (desc) "<" else ">", sub2 });
    defer gpa.free(cond);
    try b3.appendWhereAnd(cond);

    return b3.toStringAlloc(gpa);
}

/// `ROW_NUMBER()` 分页（SQL Server 2005+；也适用于支持窗口函数的方言）。
pub fn rowNumberAlloc(gpa: std.mem.Allocator, spec: Spec, start_row: i64, maximum_rows: i64) ![]u8 {
    const orderby = spec.order_by orelse spec.effectiveKey() orelse return error.NoKey;

    var b1 = try Builder.fromSpec(gpa, spec).cloneWithGroupBy("XCode_T0", spec.group_by);
    defer b1.deinit();

    const cols = try std.fmt.allocPrint(gpa, "*, row_number() over(Order By {s}) as rowNumber", .{orderby});
    defer gpa.free(cols);
    b1.column = cols;
    b1.order_by = spec.order_by;

    var b2 = try b1.asChild("XCode_T1");
    defer b2.deinit();
    b2.column = "*";
    b2.order_by = null;

    const low = start_row + 1;
    const high = if (maximum_rows < 1) low else start_row + maximum_rows;
    const cond = if (maximum_rows < 1)
        try std.fmt.allocPrint(gpa, "rowNumber>={d}", .{low})
    else
        try std.fmt.allocPrint(gpa, "rowNumber Between {d} And {d}", .{ low, high });
    defer gpa.free(cond);
    try b2.appendWhereAnd(cond);

    return b2.toStringAlloc(gpa);
}

/// 排序串里的字段列表，逗号连接（C# `SelectBuilder.Join(keys, …)`）。
fn keysCsvAlloc(gpa: std.mem.Allocator, order: []const u8) ![]u8 {
    var b = Buf.init(gpa);
    defer b.deinit();
    var first = true;
    var it = std.mem.splitScalar(u8, order, ',');
    while (it.next()) |part| {
        const col = firstToken(part) orelse continue;
        if (!first) try b.add(", ");
        try b.add(col);
        first = false;
    }
    return b.toOwnedSlice();
}

/// 排序反向（`Id Desc` → `Id Asc`；`Id`（无方向）→ `Id Desc`，与 C# 缺省反向为 Desc 一致）。
fn reverseOrderAlloc(gpa: std.mem.Allocator, order: []const u8) ![]u8 {
    var b = Buf.init(gpa);
    defer b.deinit();
    var first = true;
    var it = std.mem.splitScalar(u8, order, ',');
    while (it.next()) |part| {
        var tokens = std.mem.tokenizeAny(u8, part, " \t");
        const col = tokens.next() orelse continue;
        if (!first) try b.add(", ");
        first = false;
        try b.add(col);
        if (tokens.next()) |dir| {
            try b.add(if (std.ascii.eqlIgnoreCase(dir, "desc")) " Asc" else " Desc");
        } else {
            try b.add(" Desc");
        }
    }
    return b.toOwnedSlice();
}

// ───────────────────────── 单元测试（黄金 SQL，逐条对照 C# 生成形状） ─────────────────────────

const sample = Spec{
    .table = "User",
    .where = "Status=1",
    .order_by = "Id Desc",
    .key = "Id",
    .key_is_int = true,
};

test "topNotIn：Top + NOT IN 子查询" {
    const a = std.testing.allocator;
    const sql = try topNotInAlloc(a, sample, 20, 10);
    defer a.free(sql);
    try std.testing.expectEqualStrings(
        "Select Top 10 * From User Where Status=1 And Id Not In(Select Top 20 Id From User Where Status=1 Order By Id Desc) Order By Id Desc",
        sql,
    );
}

test "maxMin：降序取 Min 且用 `<`，升序取 Max 且用 `>`（翻页方向决定）" {
    const a = std.testing.allocator;
    const sql = try maxMinAlloc(a, sample, 20, 10);
    defer a.free(sql);
    try std.testing.expectEqualStrings(
        "Select Top 10 * From User Where Status=1 And Id<(Select Min(Id) From (Select Top 20 Id From User Where Status=1 Order By Id Desc) XCode_T0) Order By Id Desc",
        sql,
    );

    var asc = sample;
    asc.order_by = "Id Asc";
    const sql2 = try maxMinAlloc(a, asc, 20, 10);
    defer a.free(sql2);
    try std.testing.expectEqualStrings(
        "Select Top 10 * From User Where Status=1 And Id>(Select Max(Id) From (Select Top 20 Id From User Where Status=1 Order By Id Asc) XCode_T0) Order By Id Asc",
        sql2,
    );
}

test "doubleTop：三层嵌套，内层倒序取完再翻回正序" {
    const a = std.testing.allocator;
    const sql = try doubleTopAlloc(a, sample, 20, 10, null);
    defer a.free(sql);
    try std.testing.expectEqualStrings(
        "Select * From (Select Top 10 * From (Select Top 30 Id From User Where Status=1 Order By Id Desc) XCode_T0 Order By Id Asc) XCode_T1 Order By Id Desc",
        sql,
    );
}

test "rowNumber：窗口函数 + 行号区间" {
    const a = std.testing.allocator;
    const sql = try rowNumberAlloc(a, sample, 20, 10);
    defer a.free(sql);
    try std.testing.expectEqualStrings(
        "Select * From (Select *, row_number() over(Order By Id Desc) as rowNumber From User Where Status=1) XCode_T1 Where rowNumber Between 21 And 30",
        sql,
    );

    // 页大小为 0 → 只留 `rowNumber>=n`
    const open_end = try rowNumberAlloc(a, sample, 20, 0);
    defer a.free(open_end);
    try std.testing.expect(std.mem.endsWith(u8, open_end, "Where rowNumber>=21"));
}

test "首页：按主键排序时直接 Top，不进子查询" {
    const a = std.testing.allocator;
    const sql = try pageSplitAlloc(a, sample, 0, 10, false);
    defer a.free(sql);
    try std.testing.expectEqualStrings("Select Top 10 * From User Where Status=1 Order By Id Desc", sql);

    // 页大小 0 → 原样返回（不分页）
    const all = try pageSplitAlloc(a, sample, 0, 0, false);
    defer a.free(all);
    try std.testing.expectEqualStrings("Select * From User Where Status=1 Order By Id Desc", all);
}

test "算法选择顺序与 C# 一致" {
    const a = std.testing.allocator;

    // 2005 → rowNumber（哪怕键是整数）
    const rn = try pageSplitAlloc(a, sample, 20, 10, true);
    defer a.free(rn);
    try std.testing.expect(std.mem.indexOf(u8, rn, "row_number()") != null);

    // 非整数键 → doubleTop
    var text_key = sample;
    text_key.key_is_int = false;
    const dt = try pageSplitAlloc(a, text_key, 20, 10, false);
    defer a.free(dt);
    try std.testing.expect(std.mem.indexOf(u8, dt, "XCode_T1") != null);

    // 页大小 0 → topNotIn
    const tni = try pageSplitAlloc(a, text_key, 20, 0, false);
    defer a.free(tni);
    try std.testing.expect(std.mem.indexOf(u8, tni, "Not In(") != null);

    // 没有排序列 → 明确报错，不生成乱七八糟的 SQL
    var no_order = sample;
    no_order.order_by = null;
    no_order.key = null;
    try std.testing.expectError(error.NoKey, pageSplitAlloc(a, no_order, 20, 10, false));
}

test "条件含 OR 时追加 And 要加括号" {
    const a = std.testing.allocator;
    var spec = sample;
    spec.where = "A=1 Or B=2";
    const sql = try topNotInAlloc(a, spec, 10, 5);
    defer a.free(sql);
    try std.testing.expect(std.mem.startsWith(u8, sql, "Select Top 5 * From User Where (A=1 Or B=2) And Id Not In("));
}

test "深分页倒序：三条门槛（偏移 / 总数 / 过半）与尾部偏移换算" {
    const plan = DeepPage{}; // 默认阈值与 C# 一致：500_000 / 1_000_000

    // 偏移没超过 50 万 → 不倒序（哪怕总数上亿）
    try std.testing.expect(!plan.shouldReverse(500_000, 20, 100_000_000));
    // 总数没超过 100 万 → 不倒序
    try std.testing.expect(!plan.shouldReverse(900_000, 20, 1_000_000));
    // 过了一半才倒序：90 万 → 是否 > 50 万 ✓
    try std.testing.expect(plan.shouldReverse(900_000, 20, 1_000_000 + 1));
    // 刚好一半（offset*2 == total）不倒序 —— C# 用 `startRowIndex * 2 > count`
    try std.testing.expect(!plan.shouldReverse(1_000_000 - 1, 2, 2_000_000 - 2));

    // 尾部偏移：total=1_000_001, offset=900_000, size=20 → 1_000_001-900_000-20 = 99_981
    try std.testing.expectEqual(@as(?usize, 99_981), plan.reversedOffset(900_000, 20, 1_000_001));
    // 页大小 0 / 越界 → null（调用方按原样查）
    try std.testing.expect(plan.reversedOffset(900_000, 0, 1_000_001) == null);
    try std.testing.expect(plan.reversedOffset(1_000_000, 20, 1_000_001) == null);

    // plan 一步到位
    try std.testing.expectEqual(@as(?usize, 99_981), plan.plan(900_000, 20, 1_000_001));
    try std.testing.expect(plan.plan(10, 20, 1_000_001) == null);

    // 阈值可配（集成用例用小表验证同一套逻辑）
    const small = DeepPage{ .min_offset = 2, .min_total = 4 };
    try std.testing.expect(small.shouldReverse(7, 2, 10));
    try std.testing.expectEqual(@as(?usize, 1), small.plan(7, 2, 10));
}

test "多列排序：topNotIn 明确拒绝，doubleTop 正常反向" {    const a = std.testing.allocator;
    var spec = sample;
    spec.order_by = "Id Desc, Name";

    try std.testing.expectError(error.SingleKeyRequired, topNotInAlloc(a, spec, 5, 5));

    const sql = try doubleTopAlloc(a, spec, 5, 5, null);
    defer a.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "Select Top 10 Id, Name From") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "Order By Id Asc, Name Desc") != null);
}

test "排序反向换算" {
    const a = std.testing.allocator;
    const r1 = try reverseOrderAlloc(a, "Id Desc");
    defer a.free(r1);
    try std.testing.expectEqualStrings("Id Asc", r1);

    const r2 = try reverseOrderAlloc(a, "Id");
    defer a.free(r2);
    try std.testing.expectEqualStrings("Id Desc", r2);

    const r3 = try reverseOrderAlloc(a, "Id Desc, Name");
    defer a.free(r3);
    try std.testing.expectEqualStrings("Id Asc, Name Desc", r3);
}
