//! 集成测试：地区（Area）算法 —— 合并三级/四级、直辖镇特例、层级修正、CSV 往返。
//!
//! 用真 `Model.xml`（`tests/fixtures/dh-ncode-model.xml`）+ 真 SQLite。

const std = @import("std");
const zcode = @import("zcode");
const zzig = @import("zzig");

const Area = zcode.membership.entities.Area;
const area = zcode.membership.area;

const Env = struct {
    gpa: std.mem.Allocator,
    dal: zcode.Dal,
    db: []u8,
    log_db: []u8,

    fn open(gpa: std.mem.Allocator) !Env {
        const db = try zcode.File.UniqueTempName(gpa, "area", ".db");
        errdefer gpa.free(db);
        const log_db = try zcode.File.UniqueTempName(gpa, "area-log", ".db");
        errdefer gpa.free(log_db);

        const m = try zcode.EntityModel.load(gpa, "tests/fixtures/dh-ncode-model.xml");
        const conn = try std.fmt.allocPrint(gpa, "Data Source={s};Provider=SQLite", .{db});
        defer gpa.free(conn);
        var dal = try zcode.Dal.initWithModel(gpa, conn, m);
        errdefer dal.deinit();

        const log_conn = try std.fmt.allocPrint(gpa, "Data Source={s};Provider=SQLite", .{log_db});
        defer gpa.free(log_conn);
        try dal.attachConnection("Log", log_conn);

        return .{ .gpa = gpa, .dal = dal, .db = db, .log_db = log_db };
    }

    fn deinit(self: *Env) void {
        self.dal.deinit();
        zcode.File.DeleteQuiet(self.db);
        zcode.File.DeleteQuiet(self.log_db);
        self.gpa.free(self.db);
        self.gpa.free(self.log_db);
    }

    fn ready(self: *Env) !void {
        var s = try self.dal.openSession();
        defer s.deinit();
        _ = try self.dal.syncSchema(&s);
    }
};

fn mk(id: i32, name: []const u8, full: []const u8, parent: i32) Area {
    var r = Area{};
    r.ID = id;
    r.Name = name;
    r.FullName = full;
    r.ParentID = parent;
    // 层级按编码推算（C# `ParseAndSave` 也是先 `FixLevel` 再保存）
    area.fixLevel(&r);
    return r;
}

test "MergeLevel3：新增落库、二次合并不重复、字段合并生效" {
    var env = try Env.open(std.testing.allocator);
    defer env.deinit();
    try env.ready();
    const dal = &env.dal;

    const first = [_]Area{
        mk(110000, "北京", "北京市", 0),
        mk(110101, "东城", "东城区", 110100),
    };
    const r1 = try area.mergeLevel3(dal, &first, true, true);
    try std.testing.expectEqual(@as(usize, 2), r1.count);

    const c1 = try area.countByLevel(dal);
    try std.testing.expectEqual(@as(i64, 1), c1[1]);
    try std.testing.expectEqual(@as(i64, 1), c1[3]);

    // 再跑一次（add_lose=false）：没变化 → count = 0，不会重复插入
    const r2 = try area.mergeLevel3(dal, &first, false, true);
    try std.testing.expectEqual(@as(usize, 0), r2.count);

    // 带字段的输入：合并到已有行
    var upd = mk(110101, "东城", "东城区", 110100);
    upd.TelCode = "010";
    upd.ZipCode = "100010";
    upd.Longitude = 116.4;
    const r3 = try area.mergeLevel3(dal, &.{upd}, false, true);
    try std.testing.expectEqual(@as(usize, 1), r3.count);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = (try area.findByIdAlloc(dal, arena.allocator(), 110101)).?;
    try std.testing.expectEqualStrings("010", got.TelCode);
    try std.testing.expectEqualStrings("100010", got.ZipCode);
    try std.testing.expect(@abs(got.Longitude - 116.4) < 0.001);
}

test "MergeLevel3：四个直辖镇特例（东莞/中山/儋州/嘉峪关）" {
    var env = try Env.open(std.testing.allocator);
    defer env.deinit();
    try env.ready();
    const dal = &env.dal;

    const list = [_]Area{
        mk(441999, "东莞", "东莞市", 441900),
        mk(442099, "中山", "中山市", 442000),
        mk(460499, "儋州", "儋州市", 460400),
        mk(620299, "嘉峪关", "嘉峪关市", 620200),
    };
    const r = try area.mergeLevel3(dal, &list, true, false);
    try std.testing.expectEqual(@as(usize, 4), r.count);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expect_pairs = [_]struct { id: i32, parent: i32 }{
        .{ .id = 441999, .parent = 441900 },
        .{ .id = 442099, .parent = 442000 },
        .{ .id = 460499, .parent = 460400 },
        .{ .id = 620299, .parent = 620200 },
    };
    for (expect_pairs) |p| {
        const got = (try area.findByIdAlloc(dal, a, p.id)).?;
        try std.testing.expectEqualStrings("直辖镇", got.Name);
        try std.testing.expectEqualStrings("直辖镇", got.FullName);
        try std.testing.expectEqual(p.parent, got.ParentID);
        // 特例分支强制启用（与 enable=false 无关）
        try std.testing.expect(got.Enable);
    }
}

test "ScanFixLevel：Level=0 的记录按编码修正为 1/2/3/4" {
    var env = try Env.open(std.testing.allocator);
    defer env.deinit();
    try env.ready();
    const dal = &env.dal;

    const list = [_]Area{
        mk(110000, "北京市", "北京市", 0),
        mk(110100, "市辖区", "市辖区", 110000),
        mk(110101, "东城区", "东城区", 110100),
        mk(110101001, "东华门街道", "东华门街道", 110101),
    };
    _ = try area.mergeLevel3(dal, list[0..3], true, true);
    _ = try area.mergeLevel4(dal, list[3..], true, true);

    // 手动把 Level 归零（模拟历史脏数据）
    {
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.execIn(&s, "Update Area Set Level = 0", &.{});
    }

    const out = try area.scanFixLevel(dal);
    try std.testing.expectEqual(@as(usize, 4), out.scanned);
    try std.testing.expectEqual(@as(usize, 4), out.fixed);

    const counts = try area.countByLevel(dal);
    try std.testing.expectEqual(@as(i64, 1), counts[1]);
    try std.testing.expectEqual(@as(i64, 1), counts[2]);
    try std.testing.expectEqual(@as(i64, 1), counts[3]);
    try std.testing.expectEqual(@as(i64, 1), counts[4]);
}

test "CSV：导出 → 回读 → 导入到新库（行数与层级一致）" {
    var env = try Env.open(std.testing.allocator);
    defer env.deinit();
    try env.ready();
    const dal = &env.dal;

    const list = [_]Area{
        mk(110000, "北京市", "北京市", 0),
        mk(110100, "市辖区", "市辖区", 110000),
        mk(110101, "东城区", "东城区", 110100),
    };
    _ = try area.mergeLevel3(dal, &list, true, true);

    const gpa = std.testing.allocator;
    const csv = try zcode.File.UniqueTempName(gpa, "area", ".csv");
    defer {
        zcode.File.DeleteQuiet(csv);
        gpa.free(csv);
    }

    const exported = try area.exportCsv(dal, csv, 4);
    try std.testing.expectEqual(@as(usize, 3), exported);

    // 导入到另一个空库
    var env2 = try Env.open(gpa);
    defer env2.deinit();
    try env2.ready();

    const imported = try area.importCsv(&env2.dal, csv, true, 3, true);
    try std.testing.expectEqual(@as(usize, 3), imported.count);

    const c2 = try area.countByLevel(&env2.dal);
    try std.testing.expectEqual(@as(i64, 3), c2[1] + c2[2] + c2[3]);
}
