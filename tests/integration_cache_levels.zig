//! 集成测试：两级缓存的对抗性口径（真实 SQLite）。
//!
//! 对齐 DH.NCode `Cache/` 目录，逐条守住这几件事：
//!
//! 1. **绝不整表装载大表**：`MaxCacheCount` 就是内存上限，超了一行都不留（亿级表也不怕）；
//! 2. **读路径不枷锁**：快照不可变 + 原子发布，命中不触库；
//! 3. **单对象缓存按主键精确失效**：写一行只丢那一行，不清整表（写多读多场景的关键）；
//! 4. **手动/自动失效**：整表缓存只能整体失效，`invalidate()` / `invalidateForced()` 语义分明；
//! 5. **作用域 = 连接名 + 物理表名**：分库同名表互不串缓存；
//! 6. **单飞装载**：并发首次访问只装载一次（不会把库打爆）；
//! 7. **快照深拷贝**：会话后续查询重置结果集，不会让缓存里的字符串变脏。

const std = @import("std");
const zcode = @import("zcode");

fn Rec(comptime table: []const u8) type {
    return struct {
        dirty: zcode.entity.DirtyBits = 0,
        Id: i32 = 0,
        Name: []const u8 = "",
        Score: i32 = 0,

        pub const meta = zcode.entity.EntityMeta{
            .name = table,
            .table_name = table,
            .fields = &.{
                .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
                .{ .name = "Name", .data_type = .string },
                .{ .name = "Score", .data_type = .int32 },
            },
        };

        pub fn columnValue(self: @This(), i: usize) zcode.Value {
            return switch (i) {
                0 => .{ .int = self.Id },
                1 => .{ .text = self.Name },
                2 => .{ .int = self.Score },
                else => .null,
            };
        }

        pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
            switch (i) {
                0 => self.Id = v.asI32() orelse 0,
                1 => self.Name = if (v == .text) v.text else "",
                2 => self.Score = @intCast(v.asI64() orelse 0),
                else => {},
            }
        }

        pub fn setName(self: *@This(), v: []const u8) void {
            if (zcode.entity.valueEql(self.Name, v)) return;
            self.Name = v;
            zcode.entity.markDirty(&self.dirty, 1);
        }
    };
}

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="Small" TableName="BH_Small" MaxCacheCount="100">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\      <Column Name="Score" DataType="Int32" />
    \\    </Columns>
    \\  </Table>
    \\  <Table Name="Big" TableName="BH_Big" MaxCacheCount="5">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\      <Column Name="Score" DataType="Int32" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

const Small = Rec("Small");
const Big = Rec("Big");

fn openDal(a: std.mem.Allocator, path: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

fn insertRec(comptime T: type, dal: *zcode.Dal, s: *zcode.Session, name: []const u8, score: i32) !i64 {
    var e = T{};
    e.setName(name);
    e.Score = score;
    return zcode.entity.insert(dal, &e, s);
}

// ───────────────────── 1. 大表不整表缓存 ─────────────────────

test "整表缓存：超过 MaxCacheCount 一行都不留（内存上限与表大小无关）" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache_big", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var ids: [8]i64 = undefined;
    for (0..8) |i| {
        const name = try std.fmt.allocPrint(s.resultAllocator(), "n-{d}", .{i});
        ids[i] = try insertRec(Big, &dal, &s, name, @intCast(i));
    }

    var c = zcode.cache.Cache(Big).init(&dal, 60);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 5), c.max_rows);

    // 走库拿到全部 8 行，但**不进缓存**（上限 5）
    const all = try c.all(&s);
    try std.testing.expectEqual(@as(usize, 8), all.len);
    try std.testing.expect(!c.usingCache());
    try std.testing.expectEqual(@as(usize, 0), c.cachedRows());
    try std.testing.expectEqual(@as(usize, 1), c.stats().over_limit);

    // 之后照常查库，结果正确
    const got = (try c.get(&s, ids[3])).?;
    try std.testing.expectEqualStrings("n-3", got.Name);
    try std.testing.expectEqual(@as(i32, 3), got.Score);
    try std.testing.expectEqual(@as(usize, 0), c.cachedRows());
}

// ───────────────────── 2. 小表常驻 + 谓词 + 统计 ─────────────────────

fn predNameA(e: *const Small) bool {
    return std.mem.startsWith(u8, e.Name, "a-");
}

fn predScoreGt1(e: *const Small) bool {
    return e.Score > 1;
}

test "整表缓存：小表常驻，谓词查询走内存，装载只发生一次" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache_small", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    _ = try insertRec(Small, &dal, &s, "a-0", 0);
    _ = try insertRec(Small, &dal, &s, "a-1", 1);
    _ = try insertRec(Small, &dal, &s, "b-2", 2);

    var c = zcode.cache.Cache(Small).init(&dal, 60);
    defer c.deinit();

    try std.testing.expectEqual(@as(usize, 3), (try c.all(&s)).len);
    try std.testing.expect(c.usingCache());
    try std.testing.expectEqual(@as(usize, 3), c.cachedRows());
    try std.testing.expectEqual(@as(usize, 1), c.stats().loads);

    // 谓词查询：全在内存里找，不产生新的装载
    const found = (try c.find(&s, predNameA)).?;
    try std.testing.expectEqualStrings("a-0", found.Name);

    const many = try c.findAll(&s, a, predScoreGt1);
    defer a.free(many);
    try std.testing.expectEqual(@as(usize, 1), many.len); // 只有 Score=2 那一行

    try std.testing.expectEqual(@as(usize, 1), c.stats().loads);

    // 多次命中 → 命中率显著
    var i: usize = 0;
    while (i < 100) : (i += 1) _ = try c.all(&s);
    const st = c.stats();
    try std.testing.expect(st.success >= 100);
    try std.testing.expect(st.hitRate() > 0.9);
    try std.testing.expectEqual(@as(usize, 1), st.loads);
}

// ───────────────────── 3. 单对象缓存精确失效 ─────────────────────

test "单对象缓存：写一行只丢那一行（不清整表）" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache_single", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const id0 = try insertRec(Small, &dal, &s, "a", 0);
    const id1 = try insertRec(Small, &dal, &s, "b", 1);

    var sc = zcode.cache.SingleCache(Small).init(&dal, 600);
    defer sc.deinit();

    _ = (try sc.get(&s, id0)).?;
    _ = (try sc.get(&s, id1)).?;
    try std.testing.expectEqual(@as(usize, 2), sc.cachedCount());
    const hit0 = sc.stats().success;

    // 命中不触库
    _ = (try sc.get(&s, id1)).?;
    try std.testing.expectEqual(hit0 + 1, sc.stats().success);

    // 改 id0：只失效这一条
    var e = (try sc.get(&s, id0)).?;
    e.setName("a2");
    try std.testing.expectEqual(@as(usize, 1), try zcode.entity.update(&dal, &e, &s));

    try std.testing.expectEqual(@as(usize, 1), sc.cachedCount()); // 只丢 id0，id1 还在

    const refreshed = (try sc.get(&s, id0)).?;
    try std.testing.expectEqualStrings("a2", refreshed.Name);
    try std.testing.expectEqual(@as(usize, 2), sc.cachedCount()); // 回库后重新装入

    // id1 仍命中（没有被连带清掉）
    const before = sc.stats().success;
    const other = (try sc.get(&s, id1)).?;
    try std.testing.expectEqualStrings("b", other.Name);
    try std.testing.expectEqual(before + 1, sc.stats().success);
}

// ───────────────────── 4. 表级/批量写 → 整体失效 ─────────────────────

test "整表缓存：表级更新（不知道主键）整体失效" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache_wholesale", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    _ = try insertRec(Small, &dal, &s, "a", 0);
    _ = try insertRec(Small, &dal, &s, "b", 1);

    var c = zcode.cache.Cache(Small).init(&dal, 600);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 2), (try c.all(&s)).len);
    try std.testing.expectEqual(@as(usize, 1), c.stats().loads);

    const table = try dal.table("Small");
    const affected = try table.update(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Score", .value = .{ .int = 7 } },
    }, null);
    try std.testing.expectEqual(@as(usize, 2), affected);

    // 整体失效 → 下次访问重新装载
    const after = try c.all(&s);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    for (after) |row| try std.testing.expectEqual(@as(i32, 7), row.Score);
    try std.testing.expectEqual(@as(usize, 2), c.stats().loads);
}

// ───────────────────── 5. 分库隔离 ─────────────────────

test "分库隔离：同名表在两条连接上各有一份缓存" {
    const a = std.testing.allocator;
    const main_path = try zcode.File.UniqueTempName(a, "cache_main", ".db");
    defer a.free(main_path);
    defer zcode.File.DeleteQuiet(main_path);
    const sh_path = try zcode.File.UniqueTempName(a, "cache_sh", ".db");
    defer a.free(sh_path);
    defer zcode.File.DeleteQuiet(sh_path);

    var dal = try openDal(a, main_path);
    defer dal.deinit();

    const sh_conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{sh_path});
    defer a.free(sh_conn);
    try dal.attachConnection("SH", sh_conn);

    var s_main = try dal.openSession();
    defer s_main.deinit();
    var s_sh = try dal.sessionForConn("SH");
    defer s_sh.deinit();

    _ = try dal.syncSchema(&s_main);
    _ = try dal.syncSchema(&s_sh);

    _ = try insertRec(Small, &dal, &s_main, "m-1", 1);
    _ = try insertRec(Small, &dal, &s_main, "m-2", 2);
    _ = try insertRec(Small, &dal, &s_sh, "s-1", 1);
    _ = try insertRec(Small, &dal, &s_sh, "s-2", 2);
    _ = try insertRec(Small, &dal, &s_sh, "s-3", 3);

    var c_main = zcode.cache.Cache(Small).initConn(&dal, "DH", 600);
    defer c_main.deinit();
    var c_sh = zcode.cache.Cache(Small).initConn(&dal, "SH", 600);
    defer c_sh.deinit();

    try std.testing.expectEqual(@as(usize, 2), (try c_main.all(&s_main)).len);
    try std.testing.expectEqual(@as(usize, 3), (try c_sh.all(&s_sh)).len);

    // 写主库：SH 的缓存不受影响（作用域按连接名隔离）
    const table_main = try dal.table("Small");
    _ = try table_main.insert(&s_main, &[_]zcode.sqlbuild.Field{
        .{ .name = "Name", .value = .{ .text = "m-3" } },
        .{ .name = "Score", .value = .{ .int = 3 } },
    });
    try std.testing.expectEqual(@as(usize, 3), c_sh.cachedRows());
    try std.testing.expectEqual(@as(usize, 2), c_main.cachedRows()); // 已失效，未重载

    // 主库重载后 3 行，SH 仍是 3 行
    try std.testing.expectEqual(@as(usize, 3), (try c_main.all(&s_main)).len);
    try std.testing.expectEqual(@as(usize, 3), (try c_sh.all(&s_sh)).len);
}

// ───────────────────── 6. 并发首次装载只装一次 ─────────────────────

const Concurrency = struct {
    fn worker(cache: *zcode.cache.Cache(Small), dal: *zcode.Dal, pk: i64) void {
        var s = dal.openSession() catch return;
        defer s.deinit();
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            _ = cache.get(&s, pk) catch return;
        }
    }
};

test "整表缓存：并发首次访问只装载一次（单飞，不打爆库）" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache_race", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const id0 = try insertRec(Small, &dal, &s, "a", 0);
    _ = try insertRec(Small, &dal, &s, "b", 1);

    var c = zcode.cache.Cache(Small).init(&dal, 600);
    defer c.deinit();

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Concurrency.worker, .{ &c, &dal, id0 + @as(i64, @intCast(i % 2)) });
    }
    for (&threads) |*t| t.join();

    const st = c.stats();
    try std.testing.expectEqual(@as(usize, 1), st.loads); // 只装了一次
    try std.testing.expect(st.total >= 100);
    try std.testing.expectEqual(@as(usize, 2), c.cachedRows());
}

// ───────────────────── 7. 快照深拷贝（悬垂修复） ─────────────────────

test "整表缓存：会话后续查询不会破坏缓存内容（深拷贝）" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache_dup", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const id = try insertRec(Small, &dal, &s, "dup-name", 42);

    var c = zcode.cache.Cache(Small).init(&dal, 600);
    defer c.deinit();
    _ = try c.all(&s);

    // 在同一个会话上再跑几轮查询（会重置结果集 arena）
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try zcode.entity.findByPk(&dal, Small, &s, &.{.{ .int = id }});
    }

    const got = (try c.get(&s, id)).?;
    try std.testing.expectEqualStrings("dup-name", got.Name);
    try std.testing.expectEqual(@as(i32, 42), got.Score);
}
