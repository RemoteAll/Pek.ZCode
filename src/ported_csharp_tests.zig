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

// ── Model/FieldInTests.cs + Model/FieldLikeTests.cs ─────────────────────────
//
// 两处**显式差异**（不是没实现，是口径不同，写下来备查）：
// 1. **标识符引用**：C# 的 `DbBase.FormatName` 只在列名是保留字时才加引号
//    （所以期望值里是 `RoleID In(...)` 这种裸名）；本仓 `DatabaseKind.quoteAlloc` **一律引用**
//    （SQLite `"RoleID"`、MySQL `` `RoleID` ``、SQL Server `[RoleID]`），因此期望值带引号。
// 2. **LIKE 参数化**：C# 参数化分支输出 `'%@Name%'` —— 命名参数被写在引号里，执行时不会被替换；
//    本仓不做这个分支，值一律按 C# `FormatLike` 的转义规则内联（`'`→`''`、`%`→`\%`、`_`→`\_`）。

const Value = @import("zzig").db.Value;
const Buf = @import("zzig").Buf;
const expr = @import("expression.zig");

const expr_table = struct {
    fn user() model.TableMeta {
        return .{
            .name = "User",
            .table_name = "User",
            .columns = &[_]model.ColumnMeta{
                .{ .name = "Id", .data_type = .int32, .identity = true, .primary_key = true },
                .{ .name = "RoleID", .data_type = .int32 },
                .{ .name = "Name", .data_type = .string, .length = 50 },
            },
        };
    }

    fn role() model.TableMeta {
        return .{
            .name = "Role",
            .table_name = "Role",
            .columns = &[_]model.ColumnMeta{
                .{ .name = "Id", .data_type = .int32, .identity = true, .primary_key = true },
                .{ .name = "Name", .data_type = .string, .length = 50 },
            },
        };
    }

    fn log() model.TableMeta {
        return .{
            .name = "Log",
            .table_name = "Log",
            .columns = &[_]model.ColumnMeta{
                .{ .name = "Id", .data_type = .int32, .identity = true, .primary_key = true },
                .{ .name = "Category", .data_type = .string, .length = 50 },
                .{ .name = "Success", .data_type = .boolean },
            },
        };
    }

    fn area() model.TableMeta {
        return .{
            .name = "Area",
            .table_name = "Area",
            .columns = &[_]model.ColumnMeta{
                .{ .name = "Id", .data_type = .int32, .identity = true, .primary_key = true },
                .{ .name = "Level", .data_type = .int32 },
            },
        };
    }
};

/// 按 SQLite 方言渲染（`params == null` = 非参数化，与 C# 用例的 `GetString(db, null)` 对应）。
fn renderAny(a: std.mem.Allocator, e: anytype, params: ?*std.ArrayList(Value)) ![]u8 {
    var b = Buf.init(a);
    defer b.deinit();
    try e.renderInto(a, .sqlite, params, &b);
    return b.toOwnedSlice();
}

fn expectRender(a: std.mem.Allocator, e: anytype, want: []const u8) !void {
    const sql = try renderAny(a, e, null);
    defer a.free(sql);
    try std.testing.expectEqualStrings(want, sql);
}

fn deinitIn(a: std.mem.Allocator, e: expr.InExpression) void {
    switch (e.source) {
        .values => |v| a.free(v),
        else => {},
    }
}

test "C# In：整数数组 → In(1,2,3,4)；空数组抛 ArgumentNullException" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const col = t.column("RoleID").?;

    const e = try expr.inValues(a, col, &[_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 }, .{ .int = 4 } }, false);
    defer deinitIn(a, e);
    try expectRender(a, e, "\"RoleID\" In(1,2,3,4)");

    try std.testing.expectError(expr.InError.EmptyInValues, expr.inValues(a, col, &[_]Value{}, false));
}

test "C# InForStringArray：字符串数组 → In('登录','注册','同步')" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    const col = t.column("Category").?;

    const e = try expr.inValues(a, col, &[_]Value{
        .{ .text = "登录" },
        .{ .text = "注册" },
        .{ .text = "同步" },
    }, false);
    defer deinitIn(a, e);
    try expectRender(a, e, "\"Category\" In('登录','注册','同步')");

    try std.testing.expectError(expr.InError.EmptyInValues, expr.inValues(a, col, &[_]Value{}, false));
}

test "C# InForString：逗号分隔文本 → In('登录','注册','同步')；空串抛错" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    const col = t.column("Category").?;

    const e = try expr.inText(col, "登录,注册,同步", false);
    try expectRender(a, e, "\"Category\" In('登录','注册','同步')");

    try std.testing.expectError(expr.InError.EmptyInText, expr.inText(col, "", false));
}

test "C# NotIn：整数数组 → Not In(1,2,3,4)" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const col = t.column("RoleID").?;

    const e = try expr.inValues(a, col, &[_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 }, .{ .int = 4 } }, true);
    defer deinitIn(a, e);
    try expectRender(a, e, "\"RoleID\" Not In(1,2,3,4)");
}

test "C# NotInForStringArray：字符串数组 → Not In('登录','注册','同步')" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    const col = t.column("Category").?;

    const e = try expr.inValues(a, col, &[_]Value{
        .{ .text = "登录" },
        .{ .text = "注册" },
        .{ .text = "同步" },
    }, true);
    defer deinitIn(a, e);
    try expectRender(a, e, "\"Category\" Not In('登录','注册','同步')");
}

test "C# NotInForString：逗号分隔文本 → Not In('登录','注册','同步')" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    const col = t.column("Category").?;

    const e = try expr.inText(col, "登录,注册,同步", true);
    try expectRender(a, e, "\"Category\" Not In('登录','注册','同步')");
}

test "C# InForSelectBuilder：子查询 → In(Select ID From Role)" {
    const a = std.testing.allocator;
    const ut = expr_table.user();
    const rt = expr_table.role();
    const col = ut.column("RoleID").?;

    // C# 的 `Role.FindSQLWithKey()` 等价物：`sqlbuild` 只选主键列
    var q = @import("query.zig").Query.init(a);
    defer q.deinit();
    try q.select.append(a, "Id");
    const sel = try sqlbuild.select(a, .sqlite, &rt, "Role", &q);
    defer sel.deinit(a);

    const e = try expr.inSubquery(col, sel.text, false);
    try expectRender(a, e, "\"RoleID\" In(SELECT \"Id\" FROM \"Role\")");
}

test "C# NotInForSelectBuilder：子查询 → Not In(Select ID From Role)" {
    const a = std.testing.allocator;
    const ut = expr_table.user();
    const rt = expr_table.role();
    const col = ut.column("RoleID").?;

    var q = @import("query.zig").Query.init(a);
    defer q.deinit();
    try q.select.append(a, "Id");
    const sel = try sqlbuild.select(a, .sqlite, &rt, "Role", &q);
    defer sel.deinit(a);

    const e = try expr.inSubquery(col, sel.text, true);
    try expectRender(a, e, "\"RoleID\" Not In(SELECT \"Id\" FROM \"Role\")");
}

test "C# In：单项退化成等于（C# _In 的行为）；重复项去重" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const col = t.column("RoleID").?;

    const one = try expr.inValues(a, col, &[_]Value{.{ .int = 7 }}, false);
    defer deinitIn(a, one);
    try expectRender(a, one, "\"RoleID\" = 7");

    const one_not = try expr.inValues(a, col, &[_]Value{.{ .int = 7 }}, true);
    defer deinitIn(a, one_not);
    try expectRender(a, one_not, "\"RoleID\" <> 7");

    const dup = try expr.inValues(a, col, &[_]Value{ .{ .int = 3 }, .{ .int = 3 }, .{ .int = 3 } }, false);
    defer deinitIn(a, dup);
    try expectRender(a, dup, "\"RoleID\" = 3");

    const dup2 = try expr.inValues(a, col, &[_]Value{ .{ .int = 3 }, .{ .int = 5 }, .{ .int = 3 } }, false);
    defer deinitIn(a, dup2);
    try expectRender(a, dup2, "\"RoleID\" In(3,5)");
}

test "C# Contains：Name Like '%dmi%'" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const e = try expr.like(t.column("Name").?, .contains, "dmi");
    try expectRender(a, e, "\"Name\" Like '%dmi%'");
}

test "C# ContainsWithParameter：C# 输出 '%@Name%'（引号内不会被替换），本仓改为内联且不动参数表" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const e = try expr.like(t.column("Name").?, .contains, "dmi");

    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);
    const sql = try renderAny(a, e, &params);
    defer a.free(sql);

    try std.testing.expectEqualStrings("\"Name\" Like '%dmi%'", sql);
    try std.testing.expectEqual(@as(usize, 0), params.items.len);
}

test "C# NotContains：Name Not Like '%dmi%'" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const e = try expr.like(t.column("Name").?, .not_contains, "dmi");
    try expectRender(a, e, "\"Name\" Not Like '%dmi%'");
}

test "C# NotContainsWithParameter：口径同 ContainsWithParameter" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const e = try expr.like(t.column("Name").?, .not_contains, "dmi");

    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);
    const sql = try renderAny(a, e, &params);
    defer a.free(sql);

    try std.testing.expectEqualStrings("\"Name\" Not Like '%dmi%'", sql);
    try std.testing.expectEqual(@as(usize, 0), params.items.len);
}

test "C# StartsWith：Name Like 'dmi%'" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const e = try expr.like(t.column("Name").?, .starts_with, "dmi");
    try expectRender(a, e, "\"Name\" Like 'dmi%'");
}

test "C# StartsWithWithParameter：口径同 ContainsWithParameter" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const e = try expr.like(t.column("Name").?, .starts_with, "dmi");

    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);
    const sql = try renderAny(a, e, &params);
    defer a.free(sql);

    try std.testing.expectEqualStrings("\"Name\" Like 'dmi%'", sql);
    try std.testing.expectEqual(@as(usize, 0), params.items.len);
}

test "C# StartsWithEscape：' → ''、% → \\%、_ → \\_（C# FormatLike 的转义）" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    // C# 原文：fi.StartsWith("dmi/'[]()%&_end")
    // 期望：  Name Like 'dmi/''[]()\%&\_end%'
    const e = try expr.like(t.column("Name").?, .starts_with, "dmi/'[]()%&_end");
    try expectRender(a, e, "\"Name\" Like 'dmi/''[]()\\%&\\_end%'");
}

test "C# EndsWith：Name Like '%dmi'" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const e = try expr.like(t.column("Name").?, .ends_with, "dmi");
    try expectRender(a, e, "\"Name\" Like '%dmi'");
}

test "C# EndsWithWithParameter：口径同 ContainsWithParameter" {
    const a = std.testing.allocator;
    const t = expr_table.user();
    const e = try expr.like(t.column("Name").?, .ends_with, "dmi");

    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);
    const sql = try renderAny(a, e, &params);
    defer a.free(sql);

    try std.testing.expectEqualStrings("\"Name\" Like '%dmi'", sql);
    try std.testing.expectEqual(@as(usize, 0), params.items.len);
}

test "C# Like：空值与非字符串列的异常口径（C# 抛 ArgumentNullException / NotSupportedException）" {
    const t = expr_table.user();
    try std.testing.expectError(expr.LikeError.EmptyLikeValue, expr.like(t.column("Name").?, .contains, ""));
    try std.testing.expectError(expr.LikeError.LikeOnNonStringColumn, expr.like(t.column("RoleID").?, .contains, "dmi"));
}

// ── Model/FieldNormalTests.cs ──────────────────────────────────────────────
//
// 期望值照抄 C#，只有标识符引用不同（C# `FormatName` 只在保留字时加引号，本仓一律引用）。

test "C# Equal / Equal2：Category='登录'" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    const col = t.column("Category").?;

    try expectRender(a, expr.field.equal(col, .{ .text = "登录" }), "\"Category\"='登录'");
}

test "C# Equal2WithParameter：参数化 → 列=占位符，值进参数表" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    const col = t.column("Category").?;

    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);
    const sql = try renderAny(a, expr.field.equal(col, .{ .text = "登录" }), &params);
    defer a.free(sql);

    // C# 期望 `Category=@Category`；本仓用方言位置占位符（SQLite `?`）
    try std.testing.expectEqualStrings("\"Category\"=?", sql);
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
    try std.testing.expectEqualStrings("登录", params.items[0].text);
}

test "C# NotEqual / NotEqual2：Category<>'登录'（C# 用 <> 不是 !=）" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    const col = t.column("Category").?;

    try expectRender(a, expr.field.notEqual(col, .{ .text = "登录" }), "\"Category\"<>'登录'");
}

test "C# NotEqual2WithParameter：参数化 → Category<>占位符" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    const col = t.column("Category").?;

    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);
    const sql = try renderAny(a, expr.field.notEqual(col, .{ .text = "登录" }), &params);
    defer a.free(sql);

    try std.testing.expectEqualStrings("\"Category\"<>?", sql);
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
}

test "C# IsNull：Category Is Null" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    try expectRender(a, expr.field.isNull(t.column("Category").?), "\"Category\" Is Null");
}

test "C# NotIsNull：Not Category Is Null" {
    const a = std.testing.allocator;
    const t = expr_table.log();
    try expectRender(a, expr.field.notIsNull(t.column("Category").?), "Not \"Category\" Is Null");
}

test "C# IsNullOrEmpty：Category Is Null Or Category=''" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = expr_table.log();
    const e = try expr.field.isNullOrEmpty(a, t.column("Category").?);
    try expectRender(a, e, "\"Category\" Is Null Or \"Category\"=''");
}

test "C# NotIsNullOrEmpty：Not Category Is Null And Category<>''" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = expr_table.log();
    const e = try expr.field.notIsNullOrEmpty(a, t.column("Category").?);
    try expectRender(a, e, "Not \"Category\" Is Null And \"Category\"<>''");
}

test "C# IsTrue：true → =1；false → <>1 Or Is Null；null → 不生成条件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = expr_table.log();
    const col = t.column("Success").?;

    const yes = (try expr.field.isTrue(a, col, true)).?;
    try expectRender(a, yes, "\"Success\"=1");

    const no = (try expr.field.isTrue(a, col, false)).?;
    try expectRender(a, no, "\"Success\"<>1 Or \"Success\" Is Null");

    try std.testing.expect((try expr.field.isTrue(a, col, null)) == null);
}

test "C# IsFalse：false → =0；true → <>0 Or Is Null；null → 不生成条件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = expr_table.log();
    const col = t.column("Success").?;

    const no = (try expr.field.isFalse(a, col, false)).?;
    try expectRender(a, no, "\"Success\"=0");

    const yes = (try expr.field.isFalse(a, col, true)).?;
    try expectRender(a, yes, "\"Success\"<>0 Or \"Success\" Is Null");

    try std.testing.expect((try expr.field.isFalse(a, col, null)) == null);
}

test "C# LargerThen / LargerOrEqual / LessThen / LessOrEqual：> >= < <=" {
    const a = std.testing.allocator;
    const t = expr_table.area();
    const col = t.column("Level").?;

    try expectRender(a, expr.field.gt(col, .{ .int = 1 }), "\"Level\">1");
    try expectRender(a, expr.field.gte(col, .{ .int = 2 }), "\"Level\">=2");
    try expectRender(a, expr.field.lt(col, .{ .int = 3 }), "\"Level\"<3");
    try expectRender(a, expr.field.lte(col, .{ .int = 2 }), "\"Level\"<=2");
}

test "C# WhereExpression：Or 套在 And 下加括号，And 套在 Or 下不加" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = expr_table.area();
    const col = t.column("Level").?;

    // (Level>1 Or Level<9) And Level=5  ← 子节点 Or(1) > 父 And(0) → 加括号
    const or_node = try a.create(expr.Any);
    or_node.* = .{ .where_expr = try expr.orAlloc(
        a,
        try wrapFmt(a, expr.field.gt(col, .{ .int = 1 })),
        try wrapFmt(a, expr.field.lt(col, .{ .int = 9 })),
    ) };
    const both = try a.create(expr.Any);
    both.* = .{ .where_expr = try expr.andAlloc(a, or_node, try wrapFmt(a, expr.field.equal(col, .{ .int = 5 }))) };
    try expectRender(a, both, "(\"Level\">1 Or \"Level\"<9) And \"Level\"=5");

    // (Level>1 And Level<9) Or Level=5  ← 子节点 And(0) 不大于父 Or(1) → 不加括号
    const and_node = try a.create(expr.Any);
    and_node.* = .{ .where_expr = try expr.andAlloc(
        a,
        try wrapFmt(a, expr.field.gt(col, .{ .int = 1 })),
        try wrapFmt(a, expr.field.lt(col, .{ .int = 9 })),
    ) };
    const either = try a.create(expr.Any);
    either.* = .{ .where_expr = try expr.orAlloc(a, and_node, try wrapFmt(a, expr.field.equal(col, .{ .int = 5 }))) };
    try expectRender(a, either, "\"Level\">1 And \"Level\"<9 Or \"Level\"=5");
}

/// 把格式化表达式包成 `Any` 节点（组合条件需要 `*const Any`）。
fn wrapFmt(a: std.mem.Allocator, f: expr.FormatExpression) !*expr.Any {
    const node = try a.create(expr.Any);
    node.* = .{ .format = f };
    return node;
}

// ── DataAccessLayer/WindowFunctionTests.cs ────────────────────────────────
//
// C# 的 `SelectBuilder.Window` 在本仓对应「把 `window.*Alloc` 的片段塞进 `Query.select`」。
// 差异：C# 输出 `Select ... From ...`（首字母大写、标识符不加引号），
// 本仓输出 `SELECT ... FROM "..."`。片段本身（函数名 / OVER 子句 / 缺省别名）逐字一致。

const window = @import("window.zig");

test "C# SelectBuilder_Window_Injected：Window 注入 SELECT → SELECT *, ROW_NUMBER()..." {
    const a = std.testing.allocator;
    const t = expr_table.role();

    var q = @import("query.zig").Query.init(a);
    defer q.deinit();

    const win = try window.rowNumberAlloc(a, "ID", "RowNum");
    defer a.free(win);
    _ = try q.column("*");
    _ = try q.column(win);

    const sql = try sqlbuild.select(a, .sqlite, &t, "Role", &q);
    defer sql.deinit(a);

    try std.testing.expectEqualStrings(
        "SELECT *, ROW_NUMBER() OVER(ORDER BY ID) AS RowNum FROM \"Role\"",
        sql.text,
    );
}

test "C# SelectBuilder_Window_WithColumn：Select ID, Name, RANK() ..." {
    const a = std.testing.allocator;
    const t = expr_table.role();

    var q = @import("query.zig").Query.init(a);
    defer q.deinit();

    const rank = try window.rankAlloc(a, null, "Name", "Rank");
    defer a.free(rank);
    _ = try q.column("Id");
    _ = try q.column("Name");
    _ = try q.column(rank);

    const sql = try sqlbuild.select(a, .sqlite, &t, "Role", &q);
    defer sql.deinit(a);

    try std.testing.expectEqualStrings(
        "SELECT \"Id\", \"Name\", RANK() OVER(ORDER BY Name) AS Rank FROM \"Role\"",
        sql.text,
    );
}

test "C# SelectBuilder_Window_Null_NoComma：没有窗口时不多出逗号" {
    const a = std.testing.allocator;
    const t = expr_table.role();

    var q = @import("query.zig").Query.init(a);
    defer q.deinit();

    const sql = try sqlbuild.select(a, .sqlite, &t, "Role", &q);
    defer sql.deinit(a);

    try std.testing.expectEqualStrings("SELECT * FROM \"Role\"", sql.text);
    try std.testing.expect(std.mem.indexOf(u8, sql.text, ", ") == null);
}

test "C# RowNumber_WithAlias / Aggregate_Count_NoPartition：别名与缺省别名" {
    const a = std.testing.allocator;

    const rn = try window.rowNumberAlloc(a, "CreateTime", "Rn");
    defer a.free(rn);
    try std.testing.expectEqualStrings("ROW_NUMBER() OVER(ORDER BY CreateTime) AS Rn", rn);

    const cnt = try window.aggregateAlloc(a, "COUNT", "*", null, null);
    defer a.free(cnt);
    try std.testing.expectEqualStrings("COUNT(*) OVER() AS COUNT_*", cnt);

    const sum = try window.aggregateAlloc(a, "SUM", "Amount", "DeptID", null);
    defer a.free(sum);
    try std.testing.expectEqualStrings("SUM(Amount) OVER(PARTITION BY DeptID) AS SUM_Amount", sum);

    const avg = try window.aggregateAlloc(a, "AVG", "Score", "ClassID", "AvgScore");
    defer a.free(avg);
    try std.testing.expectEqualStrings("AVG(Score) OVER(PARTITION BY ClassID) AS AvgScore", avg);
}

// ── Statistics/StatLevelsTests.cs + Statistics/StatModelTests.cs ──────────
//
// 这两组用例的语义（枚举落库值、`GetDate` 截断、`ToString` 格式化、`Split`）本仓 `stat.zig`
// 早已实现并有等价用例（`src/stat.zig` 第 325 / 359 / 385 行起），这里只补两处**逐字对齐**
// 的断言：`StatModes` 的数值（本仓原为隐式 0..4，C# 是 1..5 —— 只用于内部 switch，
// 不落库，但既然 C# 用例钉了值，Zig 也钉住，避免以后接入序列化时出错）与 `quarter` 返回值。

test "C# StatLevels：枚举落库值与 C# 完全一致（All=0 … Minute=5，Quarter=11）" {
    const stat = @import("stat.zig");
    try std.testing.expectEqual(@as(u8, 0), @backingInt(stat.Levels.all));
    try std.testing.expectEqual(@as(u8, 1), @backingInt(stat.Levels.year));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(stat.Levels.month));
    try std.testing.expectEqual(@as(u8, 3), @backingInt(stat.Levels.day));
    try std.testing.expectEqual(@as(u8, 4), @backingInt(stat.Levels.hour));
    try std.testing.expectEqual(@as(u8, 5), @backingInt(stat.Levels.minute));
    try std.testing.expectEqual(@as(u8, 11), @backingInt(stat.Levels.quarter));
}

test "C# StatModes：数值与 C# 一致（Max=1 … Count=5）" {
    const stat = @import("stat.zig");
    try std.testing.expectEqual(@as(u8, 1), @backingInt(stat.Mode.max));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(stat.Mode.min));
    try std.testing.expectEqual(@as(u8, 3), @backingInt(stat.Mode.avg));
    try std.testing.expectEqual(@as(u8, 4), @backingInt(stat.Mode.sum));
    try std.testing.expectEqual(@as(u8, 5), @backingInt(stat.Mode.count));
}

test "C# StatModel：GetDate_Unknown 返回原时间（quarter 不截断）与 ToString_Unknown 返回级别名" {
    const stat = @import("stat.zig");
    const dt = @import("zzig").DateTime{ .year = 2025, .month = 6, .day = 15, .hour = 14, .minute = 30, .second = 45 };
    const m = stat.StatModel.init(dt, .quarter);

    try std.testing.expect(m.getDate(.quarter).eql(dt));

    const a = std.testing.allocator;
    const s = try m.formatAlloc(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("Quarter", s);
}
