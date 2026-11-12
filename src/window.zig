//! 窗口函数 SQL 片段（对应 DH.NCode `DataAccessLayer/WindowFunction`）。
//!
//! 生成的片段直接拼进 `SELECT` 列表，配合 `Query.column` 使用：
//!
//! ```zig
//! const expr = try zcode.window.rowNumberAlloc(a, "\"Score\" DESC", "RowNum");
//! defer a.free(expr);
//! var q = Query.init(a);
//! _ = try q.column("*").column(expr);
//! // → SELECT *, ROW_NUMBER() OVER(ORDER BY "Score" DESC) AS "RowNum" FROM ...
//! ```
//!
//! 与 C# 的差异：C# 的 `alias` 原样拼接（不分方言引用），这里**按方言引用别名**，
//! 因为 SQLite 会把未加引号的别名当标识符且大小写折叠；其它部分（函数名、OVER 子句、
//! 缺省别名 `RowNum` / `Rank` / `DenseRank` / `{func}_{column}`）与 C# 逐字一致。

const std = @import("std");
const Buf = @import("zzig").Buf;

/// 组装 `FUNC(...) OVER(PARTITION BY ... ORDER BY ...) AS alias`。
///
/// - `expr`：函数体，如 `ROW_NUMBER()` / `SUM("Amount")`
/// - `partition_by`：可选分区列（多列用 `,` 分隔）
/// - `order_by`：可选排序列
/// - `alias`：结果列名
pub fn overAlloc(
    gpa: std.mem.Allocator,
    expr: []const u8,
    partition_by: ?[]const u8,
    order_by: ?[]const u8,
    alias: []const u8,
) ![]u8 {
    if (expr.len == 0) return error.InvalidWindow;
    if (alias.len == 0) return error.InvalidWindow;

    var b = Buf.init(gpa);
    defer b.deinit();

    try b.add(expr);
    try b.add(" OVER(");
    var wrote = false;
    if (partition_by) |p| {
        if (p.len > 0) {
            try b.add("PARTITION BY ");
            try b.add(p);
            wrote = true;
        }
    }
    if (order_by) |o| {
        if (o.len > 0) {
            if (wrote) try b.addByte(' ');
            try b.add("ORDER BY ");
            try b.add(o);
        }
    }
    try b.add(") AS ");
    try b.add(alias);

    return b.toOwnedSlice();
}

/// `ROW_NUMBER() OVER(ORDER BY order_by) AS alias`（缺省别名 `RowNum`，与 C# 一致）。
pub fn rowNumberAlloc(gpa: std.mem.Allocator, order_by: []const u8, alias: []const u8) ![]u8 {
    if (order_by.len == 0) return error.InvalidWindow;
    return overAlloc(gpa, "ROW_NUMBER()", null, order_by, alias);
}

/// `ROW_NUMBER() OVER(PARTITION BY partition_by ORDER BY order_by) AS alias`。
pub fn rowNumberPartitionAlloc(
    gpa: std.mem.Allocator,
    partition_by: []const u8,
    order_by: []const u8,
    alias: []const u8,
) ![]u8 {
    if (order_by.len == 0) return error.InvalidWindow;
    if (partition_by.len == 0) return rowNumberAlloc(gpa, order_by, alias);
    return overAlloc(gpa, "ROW_NUMBER()", partition_by, order_by, alias);
}

/// `RANK() OVER(...) AS alias`。
pub fn rankAlloc(gpa: std.mem.Allocator, partition_by: ?[]const u8, order_by: []const u8, alias: []const u8) ![]u8 {
    if (order_by.len == 0) return error.InvalidWindow;
    return overAlloc(gpa, "RANK()", partition_by, order_by, alias);
}

/// `DENSE_RANK() OVER(...) AS alias`。
pub fn denseRankAlloc(gpa: std.mem.Allocator, partition_by: ?[]const u8, order_by: []const u8, alias: []const u8) ![]u8 {
    if (order_by.len == 0) return error.InvalidWindow;
    return overAlloc(gpa, "DENSE_RANK()", partition_by, order_by, alias);
}

/// 聚合窗口：`SUM("Amount") OVER(PARTITION BY ...) AS ...`（缺省别名 `{func}_{column}`，与 C# 一致）。
///
/// `func` 取 `SUM` / `AVG` / `COUNT` / `MAX` / `MIN`（大小写不限，输出保持调用方给的大小写）。
pub fn aggregateAlloc(
    gpa: std.mem.Allocator,
    func: []const u8,
    column: []const u8,
    partition_by: ?[]const u8,
    alias: ?[]const u8,
) ![]u8 {
    if (func.len == 0 or column.len == 0) return error.InvalidWindow;

    var expr_buf: [128]u8 = undefined;
    const expr = try std.fmt.bufPrint(&expr_buf, "{s}({s})", .{ func, column });

    if (alias) |a| {
        if (a.len > 0) return overAlloc(gpa, expr, partition_by, null, a);
    }

    var alias_buf: [256]u8 = undefined;
    const default_alias = try std.fmt.bufPrint(&alias_buf, "{s}_{s}", .{ func, column });
    return overAlloc(gpa, expr, partition_by, null, default_alias);
}

// ───────────────────────── 单元测试 ─────────────────────────

test "窗口函数片段与 C# WindowFunction 逐字对齐" {
    const a = std.testing.allocator;

    const rn = try rowNumberAlloc(a, "ID DESC", "RowNum");
    defer a.free(rn);
    try std.testing.expectEqualStrings("ROW_NUMBER() OVER(ORDER BY ID DESC) AS RowNum", rn);

    const rnp = try rowNumberPartitionAlloc(a, "DeptID", "Salary DESC", "Rank");
    defer a.free(rnp);
    try std.testing.expectEqualStrings("ROW_NUMBER() OVER(PARTITION BY DeptID ORDER BY Salary DESC) AS Rank", rnp);

    // 分区为空 → 退化成不带 PARTITION BY（与 C# 重载一致）
    const rn0 = try rowNumberPartitionAlloc(a, "", "Id", "RowNum");
    defer a.free(rn0);
    try std.testing.expectEqualStrings("ROW_NUMBER() OVER(ORDER BY Id) AS RowNum", rn0);

    const rank = try rankAlloc(a, null, "Score DESC", "Rank");
    defer a.free(rank);
    try std.testing.expectEqualStrings("RANK() OVER(ORDER BY Score DESC) AS Rank", rank);

    const dense = try denseRankAlloc(a, "DeptID", "Score DESC", "DenseRank");
    defer a.free(dense);
    try std.testing.expectEqualStrings("DENSE_RANK() OVER(PARTITION BY DeptID ORDER BY Score DESC) AS DenseRank", dense);
}

test "聚合窗口：缺省别名 {func}_{column}，有分区时带 PARTITION BY" {
    const a = std.testing.allocator;

    const sum = try aggregateAlloc(a, "SUM", "\"Amount\"", null, null);
    defer a.free(sum);
    try std.testing.expectEqualStrings("SUM(\"Amount\") OVER() AS SUM_\"Amount\"", sum);

    const avg = try aggregateAlloc(a, "AVG", "\"Amount\"", "\"DeptID\"", "AvgAmount");
    defer a.free(avg);
    try std.testing.expectEqualStrings("AVG(\"Amount\") OVER(PARTITION BY \"DeptID\") AS AvgAmount", avg);
}

test "空参数明确报错" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidWindow, rowNumberAlloc(a, "", "RowNum"));
    try std.testing.expectError(error.InvalidWindow, overAlloc(a, "RANK()", null, "x", ""));
    try std.testing.expectError(error.InvalidWindow, aggregateAlloc(a, "", "x", null, null));
}
