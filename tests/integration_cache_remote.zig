//! 集成测试：多系统共用同一张表时的缓存一致性 + 恒定成本行数判定。
//!
//! 两个能力：
//! 1. **跨进程版本号**（C# `CacheInvalidator`）：写方广播版本，读方定时比对，变了就过期本地缓存；
//! 2. **`countUpTo` / `countTotal`**：亿级表上也能用恒定成本判定「是否超过阈值」，
//!    大表总数走数据库统计（消费 `Setting.full_count_floor`）。

const std = @import("std");
const zcode = @import("zcode");

fn Rec(comptime table: []const u8) type {
    return struct {
        dirty: zcode.entity.DirtyBits = 0,
        Id: i32 = 0,
        Name: []const u8 = "",

        pub const meta = zcode.entity.EntityMeta{
            .name = table,
            .table_name = table,
            .fields = &.{
                .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
                .{ .name = "Name", .data_type = .string },
            },
        };

        pub fn columnValue(self: @This(), i: usize) zcode.Value {
            return switch (i) {
                0 => .{ .int = self.Id },
                1 => .{ .text = self.Name },
                else => .null,
            };
        }

        pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
            switch (i) {
                0 => self.Id = v.asI32() orelse 0,
                1 => self.Name = if (v == .text) v.text else "",
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
    \\  <Table Name="Shared" TableName="BH_Shared" MaxCacheCount="100">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

const Shared = Rec("Shared");

fn openDal(a: std.mem.Allocator, path: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

fn insertName(dal: *zcode.Dal, s: *zcode.Session, name: []const u8) !i64 {
    var e = Shared{};
    e.setName(name);
    return zcode.entity.insert(dal, &e, s);
}

test "跨进程版本：别的进程改了表，本进程整表缓存会过期" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache_remote", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const id = try insertName(&dal, &s, "a");

    // 挂上版本协调器（单进程用内存 provider；多进程换成 Redis 等实现即可）
    var mem = zcode.dbcache.MemoryProvider.init(a);
    defer mem.deinit();
    var inv = zcode.dbcache.CacheInvalidator.init(a, &dal, mem.provider());
    defer inv.deinit();
    inv.attach();

    var c = zcode.cache.Cache(Shared).init(&dal, 600);
    defer c.deinit();
    c.remote_poll_ms = 0; // 测试里每次都拉（生产默认 1s）

    try std.testing.expectEqual(@as(usize, 1), (try c.all(&s)).len);
    try std.testing.expectEqual(@as(usize, 1), c.stats().loads);

    // 模拟「另一个进程」：绕过 TableRef 直接写库（不触发本进程的写通知），并广播版本号
    const pk = (try zcode.entity.findByPk(&dal, Shared, &s, &.{.{ .int = id }})).?;
    try std.testing.expectEqualStrings("a", pk.Name);
    _ = try s.execute("UPDATE \"BH_Shared\" SET \"Name\" = ? WHERE \"Id\" = ?", &.{
        .{ .text = "a2" },
        .{ .int = id },
    });
    {
        const key = try zcode.dbcache.CacheInvalidator.keyOf(a, "BH_Shared");
        defer a.free(key);
        const p = mem.provider();
        p.setFn(p.ctx, key, p.getFn(p.ctx, key) + 1);
    }

    // 本地缓存此刻还是旧的（本进程没收到写通知），但下一次访问会因版本变化而过期重载
    const after = (try c.get(&s, id)).?;
    try std.testing.expectEqualStrings("a2", after.Name);
    try std.testing.expectEqual(@as(usize, 2), c.stats().loads);
}

test "跨进程版本：本进程写入会递增并广播版本号" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "cache_remote_bump", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var mem = zcode.dbcache.MemoryProvider.init(a);
    defer mem.deinit();
    var inv = zcode.dbcache.CacheInvalidator.init(a, &dal, mem.provider());
    defer inv.deinit();
    inv.attach();

    const before = inv.localVersion("BH_Shared");
    _ = try insertName(&dal, &s, "x"); // TableRef 写 → Dal 广播
    try std.testing.expectEqual(before + 1, inv.localVersion("BH_Shared"));
    try std.testing.expectEqual(@as(usize, 1), inv.bumps);
}

test "单对象缓存：跨进程版本变化会整体失效" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "single_remote", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const id = try insertName(&dal, &s, "a");

    var mem = zcode.dbcache.MemoryProvider.init(a);
    defer mem.deinit();
    var inv = zcode.dbcache.CacheInvalidator.init(a, &dal, mem.provider());
    defer inv.deinit();
    inv.attach();

    var sc = zcode.cache.SingleCache(Shared).init(&dal, 600);
    defer sc.deinit();
    sc.remote_poll_ms = 0;

    try std.testing.expectEqualStrings("a", (try sc.get(&s, id)).?.Name);
    try std.testing.expectEqual(@as(usize, 1), sc.cachedCount());

    _ = try s.execute("UPDATE \"BH_Shared\" SET \"Name\" = ? WHERE \"Id\" = ?", &.{
        .{ .text = "a2" },
        .{ .int = id },
    });
    {
        const key = try zcode.dbcache.CacheInvalidator.keyOf(a, "BH_Shared");
        defer a.free(key);
        const p = mem.provider();
        p.setFn(p.ctx, key, p.getFn(p.ctx, key) + 1);
    }

    try std.testing.expectEqualStrings("a2", (try sc.get(&s, id)).?.Name);
}

test "countUpTo：恒定成本判定（min(行数, limit)）" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "count_up_to", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    for (0..3) |i| {
        const name = try std.fmt.allocPrint(s.resultAllocator(), "n{d}", .{i});
        _ = try insertName(&dal, &s, name);
    }

    try std.testing.expectEqual(@as(i64, 2), try dal.countUpTo(&s, "Shared", 2));
    try std.testing.expectEqual(@as(i64, 3), try dal.countUpTo(&s, "Shared", 10));
    try std.testing.expectEqual(@as(i64, 0), try dal.countUpTo(&s, "Shared", 0));
}

test "countTotal：小表精确、大表走统计（消费 full_count_floor）" {
    const a = std.testing.allocator;
    const path = try zcode.File.UniqueTempName(a, "count_total", ".db");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    for (0..3) |i| {
        const name = try std.fmt.allocPrint(s.resultAllocator(), "n{d}", .{i});
        _ = try insertName(&dal, &s, name);
    }

    const old = zcode.setting.snapshot();
    defer zcode.setting.restore(old);

    // floor 很大：当作小表，直接用 countUpTo 的精确值
    zcode.setting.current().full_count_floor = 100;
    try std.testing.expectEqual(@as(i64, 3), try dal.countTotal(&s, "Shared"));

    // floor 很小且表比它大：先试统计 → SQLite 没 ANALYZE 时拿不到 → 退回精确 count（结果仍正确）
    zcode.setting.current().full_count_floor = 1;
    try std.testing.expectEqual(@as(i64, 3), try dal.countTotal(&s, "Shared"));
}
