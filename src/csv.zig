//! CSV 读写（RFC 4180 风格：逗号分隔、`"` 引号包裹、`""` 转义、CRLF/LF 均可）。
//!
//! 为什么自建：本仓没有 CSV 依赖，而 `Area.Import/Export`、实体列表 `SaveCsv/LoadCsv`
//! 都要用同一套规则——**只保留这一份**，其它模块不许再写一遍解析。
//!
//! 约定：
//! - 解析时首行当表头（由调用方决定怎么用），空行忽略；
//! - 生成时只对「含逗号 / 引号 / 换行」的字段加引号（与 C# `SaveCsv` 行为一致）；
//! - 所有返回的切片都归调用方分配器。

const std = @import("std");
const Value = @import("zzig").db.Value;

/// 解析 CSV：返回「行 → 列」的两级切片（`rows[行][列]`）。所有内存归 `a`。
pub fn parseAlloc(a: std.mem.Allocator, text: []const u8) ![]const []const []const u8 {
    var rows: std.ArrayListUnmanaged([]const []const u8) = .empty;
    errdefer rows.deinit(a);

    var row: std.ArrayListUnmanaged([]const u8) = .empty;
    var cell: std.ArrayListUnmanaged(u8) = .empty;
    errdefer {
        for (row.items) |c| a.free(c);
        row.deinit(a);
        cell.deinit(a);
    }

    var i: usize = 0;
    var in_quote = false;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        const ch: u8 = if (at_end) '\n' else text[i];

        if (in_quote) {
            if (ch == '"') {
                if (i + 1 < text.len and text[i + 1] == '"') {
                    try cell.append(a, '"');
                    i += 1;
                } else {
                    in_quote = false;
                }
            } else {
                try cell.append(a, ch);
            }
            continue;
        }

        switch (ch) {
            // 只有**字段起始**的 `"` 才开引号段；裸字段里的 `"` 当普通字符（宽松解析，
            // 不把 `a"b"` 这种脏数据误当引号段）
            '"' => if (cell.items.len == 0) {
                in_quote = true;
            } else {
                try cell.append(a, '"');
            },
            ',' => {
                try row.append(a, try cell.toOwnedSlice(a));
                cell = .empty;
            },
            '\r' => {},
            '\n' => {
                try row.append(a, try cell.toOwnedSlice(a));
                cell = .empty;
                // 末尾空行不算一行；但 "a,," 这种有内容的行要保留
                if (!(row.items.len == 1 and row.items[0].len == 0)) {
                    try rows.append(a, try row.toOwnedSlice(a));
                } else {
                    row.deinit(a);
                }
                row = .empty;
            },
            else => try cell.append(a, ch),
        }
    }
    return rows.toOwnedSlice(a);
}

/// 释放 `parseAlloc` 的结果。
pub fn freeRows(a: std.mem.Allocator, rows: []const []const []const u8) void {
    for (rows) |cells| {
        for (cells) |c| a.free(c);
        a.free(cells);
    }
    a.free(rows);
}

/// 追加一个文本字段（必要时加引号并转义）。
pub fn appendText(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, t: []const u8) !void {
    const need_quote = std.mem.indexOfAny(u8, t, ",\"\r\n") != null;
    if (!need_quote) {
        try buf.appendSlice(a, t);
        return;
    }
    try buf.append(a, '"');
    for (t) |ch| {
        if (ch == '"') try buf.append(a, '"');
        try buf.append(a, ch);
    }
    try buf.append(a, '"');
}

/// 追加一个列值（布尔写 1/0，日期时间按 `ToString` 口径，二进制只写长度与前 8 字节）。
pub fn appendValue(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: Value) !void {
    switch (v) {
        .null => {},
        .boolean => |x| try buf.appendSlice(a, if (x) "1" else "0"),
        .int => |x| {
            var nb: [32]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "{d}", .{x}) catch "");
        },
        .float => |x| {
            var nb: [40]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "{d}", .{x}) catch "");
        },
        .decimal => |x| {
            var nb: [64]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "{}", .{x}) catch "");
        },
        .datetime => |x| {
            var nb: [64]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "{}", .{x}) catch "");
        },
        .text => |t| try appendText(buf, a, t),
        .blob => |t| {
            var nb: [32]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "[{d}]0x{x}", .{ t.len, t[0..@min(t.len, 8)] }) catch "");
        },
    }
}

/// 按 `Value` 的文本口径取字符串（供 `LoadCsv` 之类回填用）。
pub fn valueTextAlloc(a: std.mem.Allocator, v: Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    if (v == .text) return a.dupe(u8, v.text);
    try appendValue(&buf, a, v);
    return buf.toOwnedSlice(a);
}

test "CSV：引号转义 / 逗号 / 空字段 / 末尾空行" {
    const a = std.testing.allocator;

    const text = "ID,Name,Remark\r\n110000,北京市,\"含,逗号\"\r\n110100,,说\"\"引号\"\"\r\n\r\n";
    const rows = try parseAlloc(a, text);
    defer freeRows(a, rows);

    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(usize, 3), rows[0].len);
    try std.testing.expectEqualStrings("北京市", rows[1][1]);
    try std.testing.expectEqualStrings("含,逗号", rows[1][2]);
    try std.testing.expectEqualStrings("", rows[2][1]);
    try std.testing.expectEqualStrings("说\"\"引号\"\"", rows[2][2]);
}

test "CSV：写出时按需加引号" {
    const a = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);

    try appendText(&buf, a, "普通");
    try buf.append(a, ',');
    try appendText(&buf, a, "有,逗号");
    try buf.append(a, ',');
    try appendText(&buf, a, "有\"引号");
    try buf.append(a, ',');
    try appendValue(&buf, a, .{ .int = 42 });
    try buf.append(a, ',');
    try appendValue(&buf, a, .{ .boolean = true });

    try std.testing.expectEqualStrings("普通,\"有,逗号\",\"有\"\"引号\",42,1", buf.items);
}
