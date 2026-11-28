//! SEO 别名（slug）生成：**中文转拼音、异常字符归一化为 `-`**，只产出 `[a-z0-9-]`。
//!
//! 放进公共库的理由：这是纯文本规则，和具体站点无关；拼音表本来就在本库（`pinyin.zig`），
//! 放这里可以避免每个站点各写一份（`zzig` 不该反向依赖本库，所以不放到框架里）。
//!
//! 典型用法（栏目 / 文章的 `Code` 留空时自动生成）：
//!
//! ```zig
//! const s = try zcode.slug.alloc(arena, "公司简介");      // "gong-si-jian-jie"
//! const s2 = try zcode.slug.alloc(arena, "About Us");    // "about-us"
//! ```

const std = @import("std");
const pinyin = @import("pinyin.zig");

/// 别名最大长度（含后缀余量）：超过 80 字符对 SEO 无益，且会让 URL 变难读。
pub const MAX_LEN: usize = 80;

/// 从名称生成 slug（全小写、单词之间单个 `-`、首尾无 `-`）。
///
/// 逐字符处理：中文出拼音并在音节间加 `-`（`关于我们` → `guan-yu-wo-men`），
/// 英文字母数字原样保留（`About Us` → `about-us`），其余字符一律当一个分隔符。
/// 生成不出任何字符时返回空串（调用方需给兜底名）。
pub fn alloc(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var pending_dash = false;
    var i: usize = 0;
    while (i < name.len) {
        const len = std.unicode.utf8ByteSequenceLength(name[i]) catch 1;
        if (i + len > name.len) break;
        const cp: u21 = std.unicode.utf8Decode(name[i .. i + len]) catch 0;
        i += len;

        switch (pinyin.get(cp)) {
            // 中文：出拼音，前面补一个 `-`（音节之间必须分开，SEO 与可读性都要求）
            .name => |py| {
                if (out.items.len > 0) try pushByte(&out, a, '-');
                pending_dash = false;
                for (py) |raw| try pushByte(&out, a, std.ascii.toLower(raw));
            },
            // GB2312 空隙里的字：当分隔符处理，避免粘出一个假单词
            .none => {
                if (out.items.len > 0) pending_dash = true;
            },
            .self => {
                if (cp < 128 and std.ascii.isAlphanumeric(@as(u8, @intCast(cp)))) {
                    if (pending_dash) try pushByte(&out, a, '-');
                    pending_dash = false;
                    try pushByte(&out, a, std.ascii.toLower(@as(u8, @intCast(cp))));
                } else if (out.items.len > 0) {
                    pending_dash = true;
                }
            },
        }
    }
    return try out.toOwnedSlice(a);
}

/// 给 slug 加序号后缀（冲突时 `about` → `about-2`）。
pub fn withSuffixAlloc(a: std.mem.Allocator, base: []const u8, n: usize) ![]const u8 {
    if (n <= 1) return try a.dupe(u8, base);
    return try std.fmt.allocPrint(a, "{s}-{d}", .{ base, n });
}

/// 写一个字节，但不超过 `MAX_LEN`（超长的尾巴直接丢，不产生半个音节）。
fn pushByte(out: *std.ArrayList(u8), a: std.mem.Allocator, ch: u8) !void {
    if (out.items.len >= MAX_LEN) return;
    try out.append(a, ch);
}

const testing = std.testing;

test "slug：中文→拼音、英文→连字符短语、符号归一" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("guan-yu-wo-men", try alloc(a, "关于我们"));
    try testing.expectEqualStrings("gong-si-jian-jie", try alloc(a, "公司简介"));
    try testing.expectEqualStrings("about-us", try alloc(a, "About Us"));
    try testing.expectEqualStrings("about-us", try alloc(a, "  About   Us!! "));
    try testing.expectEqualStrings("c-c", try alloc(a, "C/C++"));
    try testing.expectEqualStrings("", try alloc(a, "！！！"));
}

test "slug：超长名称被截断且不以 `-` 结尾" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const long = "这是一个很长很长的栏目名称用来验证截断逻辑是否正常工作并且不会产生奇怪的结尾横线";
    const s = try alloc(a, long);
    try testing.expect(s.len <= MAX_LEN);
    try testing.expect(s.len > 0);
    try testing.expect(!std.mem.endsWith(u8, s, "-"));
}

test "slug：冲突后缀" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("about", try withSuffixAlloc(a, "about", 1));
    try testing.expectEqualStrings("about-2", try withSuffixAlloc(a, "about", 2));
}
