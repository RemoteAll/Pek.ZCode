//! 配置层三件小件（对应 C# `Configuration/SqlTemplate.cs`、`Configuration/ShowInOption.cs`、
//! `Attributes/ModelSortMode.cs`）。
//!
//! 这三者在 C# 里服务于**代码生成器 / 面板**，不在 ORM 热路径上，但属于「全部迁移」清单里
//! 明确列出的未做项，且都是纯函数式的解析器，适合一次做完并逐条对拍：
//!
//! - `SqlTemplate`：一个名字 + 若干「方言 → SQL」片段。片段用 `-- [MySql]` 这样的注释行分隔，
//!   `-- []` 之前的部分是默认 SQL。取不到对应方言时回落到默认，与 C# 一致。
//! - `ShowInOption`：字段在「列表 / 明细 / 添加表单 / 编辑表单 / 搜索」五区的三态（Show/Hide/Auto），
//!   支持三种等价写法（具名列表 + 宏、管道 5 段、5 字符掩码），解析优先级也照 C# 抄。
//! - `ModelSortMode`：模型字段排序模式（基类优先 / 派生类优先），Zig 侧只保留枚举与解析。
//!
//! 与 C# 的差异：`ShowInOption` 的分区顺序固定为 `List|Detail|AddForm|EditForm|Search`（C# 注释里
//! 管道语法的说明文字与实现顺序一致，这里顺序完全照实现，不照文档笔误）。

const std = @import("std");
const Buf = @import("zzig").Buf;
const DatabaseKind = @import("dialect.zig").DatabaseKind;

// ============================================================================
// SqlTemplate
// ============================================================================

/// SQL 模版：一个 SQL 在不同数据库下的多种写法。
pub const SqlTemplate = struct {
    gpa: std.mem.Allocator,
    /// 名称（C# 取资源文件名的无扩展名部分）
    name: []const u8 = "",
    /// 默认 SQL（未标方言的片段）
    sql: ?[]const u8 = null,
    /// 方言 → SQL（键按 `DatabaseKind.name()`，忽略大小写比较）
    sqls: std.ArrayListUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        /// 方言名（原样保留，比较时忽略大小写）
        kind: []const u8,
        sql: []const u8,
    };

    pub fn init(gpa: std.mem.Allocator) SqlTemplate {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *SqlTemplate) void {
        if (self.sql) |s| self.gpa.free(s);
        for (self.sqls.items) |item| {
            self.gpa.free(item.kind);
            self.gpa.free(item.sql);
        }
        self.sqls.deinit(self.gpa);
    }

    /// 解析模版文本。空行跳过；`-- [方言]` 行结束上一个片段并开启新片段。
    ///
    /// 与 C# 的差别（有意）：C# 用 `AppendLine` 拼行，末尾必然多一个换行再 `Trim`；
    /// 这里用 `\n` 拼接后同样 `Trim`，结果一致（不引入平台相关的 `\r\n`）。
    pub fn parse(self: *SqlTemplate, text: []const u8) !void {
        var current_name: []const u8 = "";
        var current: std.ArrayListUnmanaged(u8) = .empty;
        defer current.deinit(self.gpa);

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, "--")) {
                const p1 = std.mem.indexOfScalar(u8, line, '[');
                const p2 = if (p1) |start| std.mem.indexOfScalarPos(u8, line, start + 1, ']') else null;
                if (p1 != null and p2 != null and p1.? > 0 and p2.? > p1.?) {
                    // 完成上一个片段
                    try self.flushFragment(current_name, current.items);
                    current.clearRetainingCapacity();
                    current_name = line[p1.? + 1 .. p2.?];
                    line = ""; // 分隔行本身不进 SQL
                }
            }

            if (line.len > 0) {
                try current.appendSlice(self.gpa, line);
                try current.append(self.gpa, '\n');
            }
        }
        try self.flushFragment(current_name, current.items);
    }

    fn flushFragment(self: *SqlTemplate, name: []const u8, body: []const u8) !void {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return;

        if (name.len == 0) {
            if (self.sql) |old| self.gpa.free(old);
            self.sql = try self.gpa.dupe(u8, trimmed);
            return;
        }
        // 同名片段后者覆盖前者（与 C# 字典赋值语义一致）
        for (self.sqls.items) |*item| {
            if (std.ascii.eqlIgnoreCase(item.kind, name)) {
                self.gpa.free(item.sql);
                item.sql = try self.gpa.dupe(u8, trimmed);
                return;
            }
        }
        try self.sqls.append(self.gpa, .{
            .kind = try self.gpa.dupe(u8, name),
            .sql = try self.gpa.dupe(u8, trimmed),
        });
    }

    /// 取指定方言的 SQL；没有该方言的专用写法时回落到默认。
    pub fn getSql(self: *const SqlTemplate, kind: DatabaseKind) ?[]const u8 {
        return self.findSqlNamed(kind.name());
    }

    /// 按方言名取（忽略大小写），未命中回落默认。
    pub fn findSqlNamed(self: *const SqlTemplate, name: []const u8) ?[]const u8 {
        for (self.sqls.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.kind, name)) return item.sql;
        }
        return self.sql;
    }

    /// 写法数量（默认片段 + 各方言）。
    pub fn fragmentCount(self: *const SqlTemplate) usize {
        return self.sqls.items.len + @as(usize, if (self.sql != null) 1 else 0);
    }
};

// ============================================================================
// ShowInOption
// ============================================================================

/// 三态（对应 C# `TriState`）。
pub const TriState = enum {
    auto,
    show,
    hide,

    pub fn parse(text: []const u8) ?TriState {
        if (text.len == 0) return .auto;
        if (std.ascii.eqlIgnoreCase(text, "Y") or std.mem.eql(u8, text, "1")) return .show;
        if (std.ascii.eqlIgnoreCase(text, "N") or std.mem.eql(u8, text, "0")) return .hide;
        if (std.ascii.eqlIgnoreCase(text, "A") or std.mem.eql(u8, text, "?")) return .auto;
        return null;
    }

    pub fn name(self: TriState) []const u8 {
        return switch (self) {
            .auto => "Auto",
            .show => "Show",
            .hide => "Hide",
        };
    }
};

/// 显示位置选项：五区三态组合。
pub const ShowInOption = struct {
    list: TriState = .auto,
    detail: TriState = .auto,
    add_form: TriState = .auto,
    edit_form: TriState = .auto,
    search: TriState = .auto,

    /// 全部 Auto（未设置时的口径，等于「系统自动决定」）。
    pub fn autoAll() ShowInOption {
        return .{};
    }

    fn filled(state: TriState) ShowInOption {
        return .{
            .list = state,
            .detail = state,
            .add_form = state,
            .edit_form = state,
            .search = state,
        };
    }

    /// 解析。优先级：空 → 全 Auto；含 `|` → 管道 5 段；5 字符掩码 → 按位解析；否则具名列表 + 宏。
    pub fn parse(text_in: []const u8) ShowInOption {
        const text = std.mem.trim(u8, text_in, " \t\r\n");
        if (text.len == 0) return autoAll();

        if (std.mem.indexOfScalar(u8, text, '|') != null) {
            var segs: [5][]const u8 = .{ "", "", "", "", "" };
            var it = std.mem.splitScalar(u8, text, '|');
            var i: usize = 0;
            while (it.next()) |seg| : (i += 1) {
                if (i >= 5) break;
                segs[i] = std.mem.trim(u8, seg, " \t");
            }
            return .{
                .list = TriState.parse(segs[0]) orelse .auto,
                .detail = TriState.parse(segs[1]) orelse .auto,
                .add_form = TriState.parse(segs[2]) orelse .auto,
                .edit_form = TriState.parse(segs[3]) orelse .auto,
                .search = TriState.parse(segs[4]) orelse .auto,
            };
        }

        if (isMask(text)) {
            return .{
                .list = TriState.parse(text[0..1]) orelse .auto,
                .detail = TriState.parse(text[1..2]) orelse .auto,
                .add_form = TriState.parse(text[2..3]) orelse .auto,
                .edit_form = TriState.parse(text[3..4]) orelse .auto,
                .search = TriState.parse(text[4..5]) orelse .auto,
            };
        }

        // 具名列表 + 宏，顺序覆盖
        var opt = autoAll();
        var tokens = std.mem.splitScalar(u8, text, ',');
        while (tokens.next()) |raw_token| {
            const tk = std.mem.trim(u8, raw_token, " \t");
            if (tk.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(tk, "Auto")) {
                opt = autoAll();
                continue;
            }
            if (std.ascii.eqlIgnoreCase(tk, "All")) {
                opt = filled(.show);
                continue;
            }
            if (std.ascii.eqlIgnoreCase(tk, "None")) {
                opt = filled(.hide);
                continue;
            }

            const hide = tk[0] == '-' or tk[0] == '!';
            const plus = tk[0] == '+';
            const name = if (hide or plus) tk[1..] else tk;
            const state: TriState = if (hide) .hide else .show;

            if (std.ascii.eqlIgnoreCase(name, "list") or std.ascii.eqlIgnoreCase(name, "l")) {
                opt.list = state;
            } else if (std.ascii.eqlIgnoreCase(name, "detail") or std.ascii.eqlIgnoreCase(name, "d")) {
                opt.detail = state;
            } else if (std.ascii.eqlIgnoreCase(name, "add") or std.ascii.eqlIgnoreCase(name, "addform") or
                std.ascii.eqlIgnoreCase(name, "a"))
            {
                opt.add_form = state;
            } else if (std.ascii.eqlIgnoreCase(name, "edit") or std.ascii.eqlIgnoreCase(name, "editform") or
                std.ascii.eqlIgnoreCase(name, "e"))
            {
                opt.edit_form = state;
            } else if (std.ascii.eqlIgnoreCase(name, "form") or std.ascii.eqlIgnoreCase(name, "f")) {
                opt.add_form = state;
                opt.edit_form = state;
            } else if (std.ascii.eqlIgnoreCase(name, "search") or std.ascii.eqlIgnoreCase(name, "s")) {
                opt.search = state;
            }
            // 未识别的名字忽略（C# switch 无 default，同口径）
        }
        return opt;
    }

    /// 是否 5 字符掩码：`[10A?-]{5}`（忽略大小写）。
    fn isMask(text: []const u8) bool {
        if (text.len != 5) return false;
        for (text) |c| {
            switch (c) {
                '1', '0', 'A', 'a', '?', '-', 'Y', 'y', 'N', 'n' => {},
                else => return false,
            }
        }
        return true;
    }

    /// 写回文本（掩码写法，便于存进 `Model.xml` 的 `ShowIn`）。
    pub fn toMask(self: ShowInOption) [5]u8 {
        var out: [5]u8 = undefined;
        const order = [5]TriState{ self.list, self.detail, self.add_form, self.edit_form, self.search };
        for (order, 0..) |state, i| {
            out[i] = switch (state) {
                .show => '1',
                .hide => '0',
                .auto => 'A',
            };
        }
        return out;
    }
};

// ============================================================================
// ModelSortMode
// ============================================================================

/// 模型字段排序模式（对应 C# `ModelSortModes`）。
pub const ModelSortMode = enum {
    /// 基类优先（C# 默认值）
    base_first,
    /// 派生类优先
    derived_first,

    pub fn parse(text: []const u8) ?ModelSortMode {
        if (std.ascii.eqlIgnoreCase(text, "BaseFirst")) return .base_first;
        if (std.ascii.eqlIgnoreCase(text, "DerivedFirst")) return .derived_first;
        return null;
    }

    pub fn name(self: ModelSortMode) []const u8 {
        return switch (self) {
            .base_first => "BaseFirst",
            .derived_first => "DerivedFirst",
        };
    }
};

// ============================ 测试 ============================

const testing = std.testing;

test "SqlTemplate：默认片段 + 方言片段 + 回落" {
    const text =
        \\SELECT * FROM User
        \\-- [MySql]
        \\SELECT * FROM User LIMIT 10
        \\-- [Oracle]
        \\SELECT * FROM (SELECT * FROM User) WHERE ROWNUM <= 10
    ;
    var t = SqlTemplate.init(testing.allocator);
    defer t.deinit();
    try t.parse(text);

    try testing.expectEqualStrings("SELECT * FROM User", t.getSql(.sqlite).?);
    try testing.expectEqualStrings("SELECT * FROM User LIMIT 10", t.getSql(.mysql).?);
    try testing.expectEqualStrings("SELECT * FROM (SELECT * FROM User) WHERE ROWNUM <= 10", t.getSql(.oracle).?);
    // 没写方言的走默认
    try testing.expectEqualStrings("SELECT * FROM User", t.getSql(.sqlserver).?);
    try testing.expectEqual(@as(usize, 3), t.fragmentCount());
}

test "SqlTemplate：多行片段保留换行、空方言名视为默认、重复方言后者覆盖" {
    const text =
        \\SELECT a,
        \\       b
        \\FROM T
        \\-- [MySql]
        \\SELECT a, b FROM T LIMIT 1
        \\-- [MySql]
        \\SELECT a, b FROM T LIMIT 2
    ;
    var t = SqlTemplate.init(testing.allocator);
    defer t.deinit();
    try t.parse(text);

    try testing.expectEqualStrings("SELECT a,\n       b\nFROM T", t.sql.?);
    try testing.expectEqualStrings("SELECT a, b FROM T LIMIT 2", t.getSql(.mysql).?);
    try testing.expectEqual(@as(usize, 2), t.fragmentCount());
}

test "ShowInOption：具名列表 + 宏覆盖" {
    const o1 = ShowInOption.parse("List,Search");
    try testing.expectEqual(TriState.show, o1.list);
    try testing.expectEqual(TriState.show, o1.search);
    try testing.expectEqual(TriState.auto, o1.detail);

    const o2 = ShowInOption.parse("-EditForm,-Detail");
    try testing.expectEqual(TriState.hide, o2.edit_form);
    try testing.expectEqual(TriState.hide, o2.detail);
    try testing.expectEqual(TriState.auto, o2.list);

    const o3 = ShowInOption.parse("All,-Detail");
    try testing.expectEqual(TriState.show, o3.list);
    try testing.expectEqual(TriState.hide, o3.detail);

    const o4 = ShowInOption.parse("None,Search,Add");
    try testing.expectEqual(TriState.hide, o4.list);
    try testing.expectEqual(TriState.show, o4.search);
    try testing.expectEqual(TriState.show, o4.add_form);
    try testing.expectEqual(TriState.hide, o4.edit_form);

    // form 同时作用于添加与编辑
    const o5 = ShowInOption.parse("-Form");
    try testing.expectEqual(TriState.hide, o5.add_form);
    try testing.expectEqual(TriState.hide, o5.edit_form);
    try testing.expectEqual(TriState.auto, o5.search);
}

test "ShowInOption：管道 5 段与 5 字符掩码" {
    const p = ShowInOption.parse("Y|Y|N||A");
    try testing.expectEqual(TriState.show, p.list);
    try testing.expectEqual(TriState.show, p.detail);
    try testing.expectEqual(TriState.hide, p.add_form);
    try testing.expectEqual(TriState.auto, p.edit_form);
    try testing.expectEqual(TriState.auto, p.search);

    const only_edit_hide = ShowInOption.parse("|||N|");
    try testing.expectEqual(TriState.auto, only_edit_hide.list);
    try testing.expectEqual(TriState.hide, only_edit_hide.edit_form);

    // C# 文档写的是 "110A?"，实现按 [10A?-] 掩码解析 → Show,Show,Hide,Auto,Auto
    const m = ShowInOption.parse("110A?");
    try testing.expectEqual(TriState.show, m.list);
    try testing.expectEqual(TriState.show, m.detail);
    try testing.expectEqual(TriState.hide, m.add_form);
    try testing.expectEqual(TriState.auto, m.edit_form);
    try testing.expectEqual(TriState.auto, m.search);

    const all_auto = ShowInOption.parse("-----");
    try testing.expectEqual(TriState.auto, all_auto.list);

    // 掩码写回往返
    try testing.expectEqualStrings("110AA", &m.toMask());
    try testing.expectEqualStrings("AAAAA", &ShowInOption.parse("-----").toMask());
}

test "ShowInOption：空串全 Auto，未识别名字忽略" {
    const o = ShowInOption.parse("  ");
    try testing.expectEqual(TriState.auto, o.list);
    try testing.expectEqual(TriState.auto, o.search);

    const o2 = ShowInOption.parse("List,Whatever");
    try testing.expectEqual(TriState.show, o2.list);
    try testing.expectEqual(TriState.auto, o2.detail);
}

test "ModelSortMode 解析" {
    try testing.expectEqual(ModelSortMode.derived_first, ModelSortMode.parse("DerivedFirst").?);
    try testing.expectEqual(ModelSortMode.base_first, ModelSortMode.parse("basefirst").?);
    try testing.expect(ModelSortMode.parse("nope") == null);
    try testing.expectEqualStrings("BaseFirst", ModelSortMode.base_first.name());
}
