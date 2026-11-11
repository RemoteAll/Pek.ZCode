//! 绿色版（便携）演示 / 自检程序：不安装、不配置，直接跑通
//! 「Model.xml → 增量建表 → 增删改查 → 脏字段更新」。
//!
//! 实体来自 `zcodegen` 生成（`examples/entities/Article.zig`）——本程序同时充当
//! 生成产物的**编译 + 运行**校验；改了 `demo-model.xml` 后要重新生成：
//! `zig build codegen -Dmodel=examples/demo-model.xml -Dout=examples/entities`
//!
//! 用法（产物：`zig-out/bin/zcode-green.exe`）：
//! ```powershell
//! .\zcode-green.exe                 # 用 .\zcode-green.db，跑完整自检
//! .\zcode-green.exe --db D:\tmp\a.db --reset
//! ```
//!
//! SQLite 来源：exe 同目录 `sqlite3.dll` → 当前目录 → 系统 `sqlite3.dll` → `winsqlite3.dll`；
//! Win10/11 自带 winsqlite3，Win7 把一份 sqlite3.dll 放 exe 同目录即可。

const std = @import("std");
const zcode = @import("zcode");
const Article = @import("entities/Article.zig").Article;

const demo_model_xml = @embedFile("demo-model.xml");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var db_path: []const u8 = "zcode-green.db";
    var reset = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--db")) {
            i += 1;
            if (i >= argv.len) return usage();
            db_path = argv[i];
        } else if (std.mem.eql(u8, a, "--reset")) {
            reset = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage();
            return;
        } else {
            std.debug.print("未知参数：{s}\n", .{a});
            return usage();
        }
    }

    if (reset) zcode.File.DeleteQuiet(db_path);

    const model = try zcode.EntityModel.parse(gpa, demo_model_xml);
    const conn = try std.fmt.allocPrint(arena, "Data Source={s};Provider=SQLite", .{db_path});
    var dal = try zcode.Dal.initWithModel(gpa, conn, model);
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    const report = try dal.syncSchema(&s);
    std.debug.print("[green] 库：{s}\n", .{db_path});
    std.debug.print("[green] 结构同步：建表 {d} / 补列 {d} / 建索引 {d}（幂等）\n", .{
        report.tables_created, report.columns_added, report.indexes_created,
    });

    const t = try dal.table("Article");
    // 重复运行时先清空，保证自检结果稳定
    _ = try t.delete(&s, null);

    // 1) 插入 3 行（自增回写）
    const now = zcode.DateTime.nowLocal();
    var ids: [3]i32 = undefined;
    for (0..3) |k| {
        var a = Article{};
        a.Title = try std.fmt.allocPrint(arena, "标题-{d}", .{k});
        a.Author = "green";
        a.Score = @intCast(k * 10);
        a.Ok = true;
        a.CreateTime = now;
        ids[k] = @intCast(try zcode.entity.insert(&dal, &a, &s));
    }
    std.debug.print("[green] 插入 3 行，自增 ID：{d}/{d}/{d}\n", .{ ids[0], ids[1], ids[2] });

    // 2) 按主键取 + 脏字段更新（只改 Title）
    var a = (try zcode.entity.findByPk(&dal, Article, &s, &.{.{ .int = ids[0] }})).?;
    if (a.getId() != ids[0]) return error.SelfTestFailed;
    a.setTitle("改过的标题");
    if (try zcode.entity.update(&dal, &a, &s) != 1) return error.SelfTestFailed;

    // 3) 无脏列 → 不发 SQL、返回 0
    if (try zcode.entity.update(&dal, &a, &s) != 0) return error.SelfTestFailed;

    // 4) 脏字段更新不得整行覆盖：绕过实体把库里的 Score 改成 999，
    //    再让实体只改 Title 后落库，Score 必须仍是 999
    var w = zcode.Where.init(gpa);
    defer w.deinit();
    _ = try w.eq("Id", .{ .int = ids[0] });
    _ = try t.update(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Score", .value = .{ .int = 999 } },
    }, &w);
    a.setTitle("第二次改");
    _ = try zcode.entity.update(&dal, &a, &s);

    const again = (try zcode.entity.findByPk(&dal, Article, &s, &.{.{ .int = ids[0] }})).?;
    if (again.getScore() != 999) return error.SelfTestFailed;
    if (!std.mem.eql(u8, again.getTitle(), "第二次改")) return error.SelfTestFailed;

    // 5) 条件 + 分页查询与计数
    var w2 = zcode.Where.init(gpa);
    defer w2.deinit();
    _ = try w2.like("Title", "%");
    var q = zcode.Query.init(gpa);
    defer q.deinit();
    _ = q.filterWhere(&w2);
    _ = try q.orderBy("Id", false);
    _ = q.page(1, 10);

    const list = try zcode.entity.queryRows(&dal, Article, &s, &q);
    if (list.len != 3) return error.SelfTestFailed;
    if (try zcode.entity.count(&dal, Article, &s, null) != 3) return error.SelfTestFailed;

    // 6) save：自增列已有值 → 走 update（只写脏列）
    a.setScore(42);
    _ = try zcode.entity.save(&dal, &a, &s);
    const latest = (try zcode.entity.findByPk(&dal, Article, &s, &.{.{ .int = ids[0] }})).?;
    if (latest.getScore() != 42) return error.SelfTestFailed;

    // 7) 删除
    if (try zcode.entity.delete(&dal, &latest, &s) != 1) return error.SelfTestFailed;
    if (try zcode.entity.count(&dal, Article, &s, null) != 2) return error.SelfTestFailed;

    std.debug.print("[green] 全部自检通过：插入 / 按主键取 / 脏字段更新（不整行覆盖）/ 条件分页 / 计数 / save / 删除\n", .{});
}

fn usage() error{MissingArgument} {
    printUsage();
    return error.MissingArgument;
}

fn printUsage() void {
    std.debug.print(
        \\zcode-green —— Pek.ZCode 绿色版自检
        \\
        \\  --db <path>   数据库文件（缺省 .\zcode-green.db）
        \\  --reset       先删除已有库文件再重建
        \\
    , .{});
}
