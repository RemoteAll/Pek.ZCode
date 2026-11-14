//! 从 C# 侧**逐条移植**的用例（用户要求：参考 C# 把难测用例一起接过来验证）。
//!
//! 为什么单独放一个文件：这些用例的**期望值是 C# 代码写死的**（不是我按实现反推的），
//! 单独成文件便于对照上游改动——C# 那边改了期望，这里能一眼找到对应条目。
//!
//! 每个用例上方标注来源：`文件 #DisplayName`（C# 的 `XUnitTest.XCode` 工程）。
//! 原则：
//! - **只移植不需要数据库的**（SQL 文本、参数解析、选项解析）——这类才是"难测"的部分；
//!   需要真库的用例仍按 `tests/` 的集成流程走，不在这里假装跑通；
//! - 期望值**逐字照抄 C#**，本仓实现若语义不同则在此显式注明差异，不偷偷改断言。

const std = @import("std");
const sqlbuild = @import("sqlbuild.zig");
const model = @import("model.zig");
const test_table = struct {
    fn get() model.TableMeta {
        return .{
            .name = "User",
            .table_name = "User",
            .columns = &[_]model.ColumnMeta{
                .{ .name = "Id", .data_type = .int32, .identity = true, .primary_key = true },
                .{ .name = "Name", .data_type = .string, .length = 50 },
                .{ .name = "Code", .data_type = .string, .length = 50 },
                .{ .name = "RoleId", .data_type = .int32 },
                .{ .name = "DeptId", .data_type = .int32 },
            },
        };
    }
};

// ── Navigation/SelectBuilderJoinTests.cs ────────────────────────────────────

test "C# Join_Empty_NotInToString：没有 JOIN 时 SQL 里不出现 JOIN" {
    const a = std.testing.allocator;
    const t = test_table.get();

    var q = @import("query.zig").Query.init(a);
    defer q.deinit();

    const sql = try sqlbuild.selectJoined(a, .sqlite, &t, "User", &.{}, &q);
    defer sql.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, sql.text, "FROM \"User\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql.text, "JOIN") == null);
}

test "C# Join_LeftJoin_InToString / Join_MultipleJoins_AllInToString：JOIN 串原样进 SQL" {
    const a = std.testing.allocator;
    const t = test_table.get();

    var q = @import("query.zig").Query.init(a);
    defer q.deinit();

    // C# 的 `Join` 是一个字符串；本仓用 `.raw` 对应（等价于 SelectBuilder.Join = "..."）
    const one = [_]sqlbuild.Join{.{
        .kind = .raw,
        .table = "LEFT JOIN Role ON User.RoleId = Role.Id",
    }};
    const sql1 = try sqlbuild.selectJoined(a, .sqlite, &t, "User", &one, &q);
    defer sql1.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, sql1.text, "FROM \"User\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql1.text, "LEFT JOIN Role ON User.RoleId = Role.Id") != null);

    const many = [_]sqlbuild.Join{.{
        .kind = .raw,
        .table = "LEFT JOIN Role r ON User.RoleId = r.Id LEFT JOIN Dept d ON User.DeptId = d.Id",
    }};
    const sql2 = try sqlbuild.selectJoined(a, .sqlite, &t, "User", &many, &q);
    defer sql2.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, sql2.text, "LEFT JOIN Role r") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql2.text, "LEFT JOIN Dept d") != null);
}

// ── Common/SqlBuilderTests.cs #BuildOrder（Sort 口径，Desc 生效）──────────────

test "C# BuildOrder：Sort 单字段，Desc 决定有无后缀" {
    const a = std.testing.allocator;
    const t = test_table.get();

    const o1 = try sqlbuild.buildOrderAlloc(a, &t, "Name", false, .sort);
    defer a.free(o1);
    try std.testing.expectEqualStrings("Name", o1);

    const o2 = try sqlbuild.buildOrderAlloc(a, &t, "Name", true, .sort);
    defer a.free(o2);
    try std.testing.expectEqualStrings("Name Desc", o2);
}

test "C# BuildOrder：Sort 多字段，Desc 作用到每个字段" {
    const a = std.testing.allocator;
    const t = test_table.get();

    const o1 = try sqlbuild.buildOrderAlloc(a, &t, "Name,Code", false, .sort);
    defer a.free(o1);
    try std.testing.expectEqualStrings("Name,Code", o1);

    const o2 = try sqlbuild.buildOrderAlloc(a, &t, "Name,Code", true, .sort);
    defer a.free(o2);
    try std.testing.expectEqualStrings("Name Desc,Code Desc", o2);
}

test "C# BuildOrder：字段自带 desc 时优先，换行/逗号混排也能清掉" {
    const a = std.testing.allocator;
    const t = test_table.get();

    const o1 = try sqlbuild.buildOrderAlloc(a, &t, "Name desc\n,\nCode", false, .sort);
    defer a.free(o1);
    try std.testing.expectEqualStrings("Name Desc,Code", o1);

    const o2 = try sqlbuild.buildOrderAlloc(a, &t, "Name desc\n,\nCode", true, .sort);
    defer a.free(o2);
    try std.testing.expectEqualStrings("Name Desc,Code Desc", o2);
}

test "C# BuildOrder：字段自带 asc 时不加后缀，其余字段仍用 default_desc；列名规范成模型大小写" {
    const a = std.testing.allocator;
    const t = test_table.get();

    const o1 = try sqlbuild.buildOrderAlloc(a, &t, "name asc\n,\ncode", true, .sort);
    defer a.free(o1);
    try std.testing.expectEqualStrings("Name,Code Desc", o1);
}

test "C# BuildOrder：未知字段报错（C# 抛 XCodeException，本仓返回 UnknownSortField）" {
    const a = std.testing.allocator;
    const t = test_table.get();

    // C# 期望：抛「实体类[User]不包含排序字段[name2]」；本仓语义等价，错误集 + 日志文案
    try std.testing.expectError(
        error.UnknownSortField,
        sqlbuild.buildOrderAlloc(a, &t, "name2 asc\n,\ncode", true, .sort),
    );
}

// ── Common/SqlBuilderTests.cs #BuildOrder2（OrderBy 口径，Desc 不生效）──────

test "C# BuildOrder2：OrderBy 原样返回，Desc 不生效" {
    const a = std.testing.allocator;
    const t = test_table.get();

    const o1 = try sqlbuild.buildOrderAlloc(a, &t, "Name", true, .order_by);
    defer a.free(o1);
    try std.testing.expectEqualStrings("Name", o1);

    const o2 = try sqlbuild.buildOrderAlloc(a, &t, "Name,Code", true, .order_by);
    defer a.free(o2);
    try std.testing.expectEqualStrings("Name,Code", o2);
}

// ── Configuration/ShowInOptionTests.cs（三态 + 多写法解析）──────────────────

const tmpl = @import("sqltemplate.zig");

test "C# ShowInOption：逗号具名列表 / 管道 5 段 / 5 字符掩码三种写法等价" {
    // 管道 5 段：List|Detail|AddForm|EditForm|Search
    const pipe = tmpl.ShowInOption.parse("Y|N|A|Y|N");
    try std.testing.expectEqual(tmpl.TriState.show, pipe.list);
    try std.testing.expectEqual(tmpl.TriState.hide, pipe.detail);
    try std.testing.expectEqual(tmpl.TriState.auto, pipe.add_form);
    try std.testing.expectEqual(tmpl.TriState.show, pipe.edit_form);
    try std.testing.expectEqual(tmpl.TriState.hide, pipe.search);

    // 5 字符掩码
    const mask = tmpl.ShowInOption.parse("YNAYN");
    try std.testing.expectEqual(pipe.list, mask.list);
    try std.testing.expectEqual(pipe.detail, mask.detail);
    try std.testing.expectEqual(pipe.add_form, mask.add_form);
    try std.testing.expectEqual(pipe.edit_form, mask.edit_form);
    try std.testing.expectEqual(pipe.search, mask.search);

    // 具名列表（只写关心的区）
    const named = tmpl.ShowInOption.parse("Search");
    try std.testing.expectEqual(tmpl.TriState.show, named.search);
    try std.testing.expectEqual(tmpl.TriState.auto, named.list);
}

test "C# ShowInOption：空串 = 全 Auto" {
    const o = tmpl.ShowInOption.parse("");
    try std.testing.expectEqual(tmpl.TriState.auto, o.list);
    try std.testing.expectEqual(tmpl.TriState.auto, o.search);
}
