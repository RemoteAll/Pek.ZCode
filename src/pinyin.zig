//! 汉字拼音（对应 C# `DH.NCore/Common/PinYin.cs` 的 `Get` / `GetFirst` / `GetAll`）。
//!
//! 为什么是查表而不是现场算：C# 版完全建立在「GB2312 机内码 + 拼音表」之上，
//! 而 Zig 标准库没有 GB2312 码表。`tools/gen_pinyin.py` 用与 C# **逐行同样的算法**
//! 预先算好 `U+4E00..U+9FA5` 每个字的拼音，生成定长表 `pinyin_table.bin`
//! （20902 项 × u16），运行时只做 O(1) 查表，结果与 C# 一致。
//!
//! 与大写口径一致：`pyName` 表本身是大写开头，二级表（`_py2`）在 C# 里做了首字母大写，
//! 生成时已一并处理；因此本模块**不做任何大小写转换**。

const std = @import("std");
const table = @import("pinyin_table.zig");
const raw = @embedFile("pinyin_table.bin");

/// C# `Get(Char)` 的三种结果。
pub const Pinyin = union(enum) {
    /// 命中拼音表（大写开头，如 `"Zhong"`）
    name: []const u8,
    /// C# 返回 `String.Empty`（在 GB2312 汉字区但落进了表的空隙）——`GetFirst` 会跳过
    none,
    /// C# 原样返回该字符（非中文、GB2312 未收录、半角符号等）
    self,
};

const marker_self: u16 = 0xFFFE;
const marker_empty: u16 = 0xFFFF;

fn lookup(ch: u21) u16 {
    if (ch < table.first_code or ch > table.last_code) return marker_self;
    const i: usize = @intCast((ch - table.first_code) * 2);
    return std.mem.readInt(u16, raw[i..][0..2], .little);
}

/// 单字拼音（对应 C# `PinYin.Get(Char)`）。
pub fn get(ch: u21) Pinyin {
    const v = lookup(ch);
    if (v == marker_self) return .self;
    if (v == marker_empty) return .none;
    return .{ .name = table.names[v] };
}

/// 单字拼音的首字母（对应 C# `PinYin.GetFirst(Char)`）。
/// 空串结果回落为原字符（C# 同口径）。
pub fn getFirstChar(ch: u21) u21 {
    return switch (get(ch)) {
        .name => |n| n[0],
        .none, .self => ch,
    };
}

/// 逐字拼音（对应 C# `PinYin.GetAll`）。
///
/// 返回的每一项**都归调用方**（命中静态表的名字也会 `dupe`），所以可以逐项 `free` 再 `free` 外层；
/// 用 arena 时什么也不用管。
///
/// `重庆` 是 C# 里唯一的地名特例（`["Chong", "Qing"]`），在此保留。
pub fn getAllAlloc(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |p| a.free(p);
        out.deinit(a);
    }
    if (text.len == 0) return out.toOwnedSlice(a);

    if (std.mem.eql(u8, text, "重庆")) {
        try out.append(a, try a.dupe(u8, "Chong"));
        try out.append(a, try a.dupe(u8, "Qing"));
        return out.toOwnedSlice(a);
    }

    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |ch| {
        switch (get(ch)) {
            .name => |n| try out.append(a, try a.dupe(u8, n)),
            .none => try out.append(a, try a.dupe(u8, "")),
            .self => try out.append(a, try utf8Alloc(a, ch)),
        }
    }
    return out.toOwnedSlice(a);
}

/// 全拼（对应 C# `PinYin.Get(String)` = `GetAll().Join("")`）。
pub fn fullAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);

    if (std.mem.eql(u8, text, "重庆")) {
        try buf.appendSlice(a, "ChongQing");
        return buf.toOwnedSlice(a);
    }

    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |ch| {
        switch (get(ch)) {
            .name => |n| try buf.appendSlice(a, n),
            .none => {},
            .self => {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(ch, &tmp) catch continue;
                try buf.appendSlice(a, tmp[0..n]);
            },
        }
    }
    return buf.toOwnedSlice(a);
}

/// 各字首字母（对应 C# `PinYin.GetFirst(String)`）：空串结果被跳过，其余字取首字符。
pub fn getFirstAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    if (text.len == 0) return buf.toOwnedSlice(a);

    // C# `GetFirst` 走 `GetAll`，所以地名特例同样适用（“重庆” → “CQ” 而不是 “ZQ”）
    if (std.mem.eql(u8, text, "重庆")) {
        try buf.appendSlice(a, "CQ");
        return buf.toOwnedSlice(a);
    }

    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |ch| {
        var tmp: [4]u8 = undefined;
        switch (get(ch)) {
            .name => |n| try buf.append(a, n[0]),
            .none => {},
            .self => {
                const n = std.unicode.utf8Encode(ch, &tmp) catch continue;
                try buf.appendSlice(a, tmp[0..n]);
            },
        }
    }
    return buf.toOwnedSlice(a);
}

fn utf8Alloc(a: std.mem.Allocator, ch: u21) ![]u8 {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &tmp) catch return a.dupe(u8, "");
    return a.dupe(u8, tmp[0..n]);
}

// ── 用例（与 C# 行为对照）──────────────────────────────────────

const testing = std.testing;

test "单字拼音：一级/二级/特殊表/原样" {
    // 一级汉字（GB2312 拼音序表）
    try testing.expectEqualStrings("A", get('阿').name);
    try testing.expectEqualStrings("Zhong", get('重').name);
    try testing.expectEqualStrings("Qing", get('庆').name);
    try testing.expectEqualStrings("Bei", get('北').name);
    try testing.expectEqualStrings("Jing", get('京').name);

    // 非中文原样
    try testing.expectEqual(Pinyin.self, get('a'));
    try testing.expectEqual(Pinyin.self, get(','));
    try testing.expectEqual(Pinyin.self, get('＃'));

    // GB2312 未收录的生僻字原样（C# 里走 `arr.Length < 2` 分支）
    try testing.expectEqual(Pinyin.self, get(0x9F98)); // 龘
}

test "首字母：中文取拼音首字母，非中文原样，空项跳过" {
    const a = testing.allocator;
    {
        const s = try getFirstAlloc(a, "重庆");
        defer a.free(s);
        try testing.expectEqualStrings("CQ", s);
    }
    {
        const s = try getFirstAlloc(a, "北京朝阳");
        defer a.free(s);
        try testing.expectEqualStrings("BJCY", s);
    }
    {
        const s = try getFirstAlloc(a, "A1-北");
        defer a.free(s);
        try testing.expectEqualStrings("A1-B", s);
    }
    {
        const s = try getFirstAlloc(a, "");
        defer a.free(s);
        try testing.expectEqualStrings("", s);
    }
    // 单字符版本
    try testing.expectEqual(@as(u21, 'B'), getFirstChar('北'));
    try testing.expectEqual(@as(u21, 'x'), getFirstChar('x'));
}

test "全拼：逐字拼接，地名特例保留" {
    const a = testing.allocator;
    {
        const s = try fullAlloc(a, "重庆");
        defer a.free(s);
        try testing.expectEqualStrings("ChongQing", s);
    }
    {
        const s = try fullAlloc(a, "北京");
        defer a.free(s);
        try testing.expectEqualStrings("BeiJing", s);
    }
    {
        const s = try fullAlloc(a, "A北");
        defer a.free(s);
        try testing.expectEqualStrings("ABei", s);
    }
    {
        const parts = try getAllAlloc(a, "北京");
        defer {
            for (parts) |p| a.free(p);
            a.free(parts);
        }
        try testing.expectEqual(@as(usize, 2), parts.len);
        try testing.expectEqualStrings("Bei", parts[0]);
        try testing.expectEqualStrings("Jing", parts[1]);
    }
}
