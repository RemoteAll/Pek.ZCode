//! 高并发验证（用户口径：**「至少上百万甚至上亿物联网设备高并发」**）。
//!
//! 这里验证的不是「能编译」，而是**多线程 + 多连接 + 同一个库文件**时的真实行为：
//! - 并发插入不丢行、不自增冲突（连接池/驱动/事务边界）；
//! - 并发累加不丢更新（`col = col + ?` 的 SQL 侧原子性，这是「多系统共用表 + 统计字段」的地基）。
//!
//! 为什么用**多个 `Dal`（各自独立连接）**而不是一个 Dal 多线程共用：
//! 连接的会话状态（事务、临时表、语句缓存）本来就不是线程安全的，真实部署也是
//! 「一个进程一个连接 / 一个实例一条池化连接」。用多连接才测得到「WAL + busy_timeout
//! 能否扛住并发写」，这才是现场会遇到的问题。
//!
//! 规模刻意压小（4 线程 × 100 次）：并发用例要进回归门禁，必须在秒级完成；
//! 它验证的是**正确性**，吞吐数字看 `zig build bench`。

const std = @import("std");
const zcode = @import("zcode");

const model_xml =
    \\<EntityModel><Tables><Table Name="Counter" TableName="DH_Counter">
    \\  <Columns>
    \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\    <Column Name="Code" DataType="String" Length="64" />
    \\    <Column Name="Total" DataType="Int64" />
    \\  </Columns>
    \\</Table></Tables></EntityModel>
;

const threads = 4;
const per_thread_ops = 100;

/// 打开一个「独立连接」的 Dal（WAL + NORMAL：多连接并发写的前提，见 `dal.zig` 的并发档位说明）。
fn openConn(a: std.mem.Allocator, db_path: []const u8) !zcode.Dal {
    var m = try zcode.EntityModel.parse(a, model_xml);
    errdefer m.deinit();
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite;JournalMode=WAL;Synchronous=NORMAL", .{db_path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

/// 线程体用 page_allocator（线程安全）做 arena，避免跨线程共用测试分配器。
fn workerArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
}

/// 线程里的错误收集：用原子标记，线程结束后由主线程断言。
const Failure = struct {
    hit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    message: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn insertWorker(db_path: []const u8, worker_id: usize, fail: *Failure) void {
    var arena = workerArena();
    defer arena.deinit();
    const a = arena.allocator();

    var dal = openConn(a, db_path) catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发插入] worker {d} 开连接失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer dal.deinit();

    var s = dal.openSession() catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发插入] worker {d} 开会话失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer s.deinit();

    const table = dal.table("Counter") catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发插入] worker {d} 取表失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };

    var i: usize = 0;
    while (i < per_thread_ops) : (i += 1) {
        const code = std.fmt.allocPrint(a, "w{d}-{d}", .{ worker_id, i }) catch return;
        _ = table.insert(&s, &[_]zcode.sqlbuild.Field{
            .{ .name = "Code", .value = .{ .text = code } },
            .{ .name = "Total", .value = .{ .int = 0 } },
        }) catch |e| {
            fail.hit.store(true, .release);
            std.debug.print("[并发插入] worker {d} 第 {d} 条失败：{s}\n", .{ worker_id, i, @errorName(e) });
            return;
        };
    }
}

fn accumulateWorker(db_path: []const u8, worker_id: usize, fail: *Failure) void {
    var arena = workerArena();
    defer arena.deinit();
    const a = arena.allocator();

    var dal = openConn(a, db_path) catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发累加] worker {d} 开连接失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer dal.deinit();

    var s = dal.openSession() catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发累加] worker {d} 开会话失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };
    defer s.deinit();

    const table = dal.table("Counter") catch |e| {
        fail.hit.store(true, .release);
        std.debug.print("[并发累加] worker {d} 取表失败：{s}\n", .{ worker_id, @errorName(e) });
        return;
    };

    // 只打一行（Id=1），四个连接对同一行做 `Total = Total + 1`
    var w = zcode.Where.init(a);
    _ = w.eq("Id", .{ .int = 1 }) catch return;

    var i: usize = 0;
    while (i < per_thread_ops) : (i += 1) {
        _ = table.accumulate(&s, &[_]zcode.sqlbuild.AccumulateField{
            .{ .name = "Total", .value = .{ .int = 1 }, .mode = .add },
        }, &w) catch |e| {
            fail.hit.store(true, .release);
            std.debug.print("[并发累加] worker {d} 第 {d} 次失败：{s}\n", .{ worker_id, i, @errorName(e) });
            return;
        };
    }
}

test "并发插入：4 线程 × 100 行（各自连接，WAL）→ 400 行不丢不重" {
    const a = std.testing.allocator;

    const db_path = try zcode.File.UniqueTempName(a, "concurrency_ins", ".db");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    // 建表（用一条独立连接先 sync）
    {
        var dal = openConn(a, db_path) catch |e| {
            std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
            return;
        };
        defer dal.deinit();
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    var fail = Failure{};
    var handles: [threads]std.Thread = undefined;
    for (&handles, 0..) |*h, id| {
        h.* = try std.Thread.spawn(.{}, insertWorker, .{ db_path, id, &fail });
    }
    for (&handles) |*h| h.join();

    try std.testing.expect(!fail.hit.load(.acquire));

    var dal = try openConn(a, db_path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const table = try dal.table("Counter");
    const n = try table.count(&s, null);
    try std.testing.expectEqual(@as(i64, @intCast(threads * per_thread_ops)), n);

    // 主键唯一 + Code 不重复（并发下最容易出的两类错误）
    const rows = try s.queryRows("SELECT COUNT(DISTINCT Id) AS ids, COUNT(DISTINCT Code) AS codes FROM DH_Counter", &.{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, @intCast(threads * per_thread_ops)), rows[0].get("ids").?.asI64().?);
    try std.testing.expectEqual(@as(i64, @intCast(threads * per_thread_ops)), rows[0].get("codes").?.asI64().?);
}

test "并发累加：4 线程 × 100 次对同一行 Total+1 → 恰好 400（不丢更新）" {
    const a = std.testing.allocator;

    const db_path = try zcode.File.UniqueTempName(a, "concurrency_acc", ".db");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    {
        var dal = openConn(a, db_path) catch |e| {
            std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
            return;
        };
        defer dal.deinit();
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);

        const table = try dal.table("Counter");
        _ = try table.insert(&s, &[_]zcode.sqlbuild.Field{
            .{ .name = "Code", .value = .{ .text = "shared" } },
            .{ .name = "Total", .value = .{ .int = 0 } },
        });
    }

    var fail = Failure{};
    var handles: [threads]std.Thread = undefined;
    for (&handles, 0..) |*h, id| {
        h.* = try std.Thread.spawn(.{}, accumulateWorker, .{ db_path, id, &fail });
    }
    for (&handles) |*h| h.join();

    try std.testing.expect(!fail.hit.load(.acquire));

    var dal = try openConn(a, db_path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const table = try dal.table("Counter");
    const total = try table.maxValue(&s, "Total", null);
    try std.testing.expectEqual(@as(i64, @intCast(threads * per_thread_ops)), total.?.asI64().?);
}
