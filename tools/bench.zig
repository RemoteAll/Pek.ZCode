//! 性能基准：把 ORM 的几条关键路径跑出**可复现的数字**，防止后续优化/重构悄悄退化。
//!
//! 用法：`zig build bench`（SQLite 内存库，默认 ReleaseFast）。
//!
//! 记录口径（不追求绝对精度，重在**同机对比**）：
//! - 每个用例按固定次数计时，报「总耗时 / 单次」
//! - 计时用 `std.Io.Clock` 的单调时钟（0.17 已移除 `std.time.nanoTimestamp`）
//! - 结果打印成固定列宽的表，便于人工比对与贴进决策记录

const std = @import("std");
const zcode = @import("zcode");
const sqlbuild = zcode.sqlbuild;

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
    \\  <Option><Namespace>Bench.Entity</Namespace><ConnName>DH</ConnName></Option>
    \\  <Tables>
    \\    <Table Name="Article" TableName="Bench_Article" MaxCacheCount="100000">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Title" DataType="String" Length="100" />
    \\        <Column Name="Author" DataType="String" Length="50" />
    \\        <Column Name="Score" DataType="Int32" />
    \\        <Column Name="CreateTime" DataType="DateTime" />
    \\      </Columns>
    \\      <Indexes>
    \\        <Index Columns="Title" Unique="True" />
    \\      </Indexes>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

const Article = struct {
    Id: i32 = 0,
    Title: []const u8 = "",
    Author: []const u8 = "",
    Score: i32 = 0,
    CreateTime: zcode.DateTime = .{},
    dirty: zcode.entity.DirtyBits = 0,

    pub const meta = zcode.entity.EntityMeta{
        .name = "Article",
        .table_name = "Bench_Article",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "Title", .data_type = .string },
            .{ .name = "Author", .data_type = .string },
            .{ .name = "Score", .data_type = .int32 },
            .{ .name = "CreateTime", .data_type = .datetime },
        },
    };

    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = self.Id },
            1 => .{ .text = self.Title },
            2 => .{ .text = self.Author },
            3 => .{ .int = self.Score },
            4 => .{ .datetime = self.CreateTime },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => self.Id = v.asI32() orelse 0,
            1 => self.Title = v.asText() orelse "",
            2 => self.Author = v.asText() orelse "",
            3 => self.Score = v.asI32() orelse 0,
            4 => self.CreateTime = v.asDatetime() orelse .{},
            else => return error.ColumnNotFound,
        }
    }
};

const Sample = struct { name: []const u8, total_ns: i128, iterations: usize };

var io_global: std.Io = undefined;

fn nowNs() i128 {
    return std.Io.Clock.Timestamp.now(io_global, .awake).raw.nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    io_global = std.Io.Threaded.global_single_threaded.io();

    var results: std.ArrayList(Sample) = .empty;
    defer results.deinit(gpa);

    const m = try zcode.EntityModel.parse(gpa, model_xml);
    var dal = try zcode.Dal.initWithModel(gpa, "Data Source=:memory:;Provider=SQLite", m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("Article");
    _ = try table.delete(&s, null);

    const now = zcode.DateTime.nowLocal();
    // 每行标题必须独立内存：共用一块 bufPrint 缓冲会让所有行指向同一内容（唯一索引直接冲突）
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // 1) 实体单条插入（自增回写）
    {
        const n = 500;
        var i: usize = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            var e = Article{};
            e.Title = try std.fmt.allocPrint(aa, "t-{d}", .{i});
            e.Author = "bench";
            e.Score = @intCast(i);
            e.CreateTime = now;
            _ = try zcode.entity.insert(&dal, &e, &s);
        }
        try results.append(gpa, .{ .name = "实体 insert（含自增回写）", .total_ns = nowNs() - start, .iterations = n });
    }

    // 2) 批量写（多行 VALUES 分批）
    {
        const n = 2000;
        var items: std.ArrayList(Article) = .empty;
        defer items.deinit(gpa);
        try items.ensureTotalCapacity(gpa, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var e = Article{};
            e.Title = try std.fmt.allocPrint(aa, "b-{d}", .{i});
            e.Author = "bench";
            e.Score = @intCast(i);
            e.CreateTime = now;
            try items.append(gpa, e);
        }

        var refs: std.ArrayList(*Article) = .empty;
        defer refs.deinit(gpa);
        try refs.ensureTotalCapacity(gpa, n);
        for (items.items) |*it| try refs.append(gpa, it);

        const start = nowNs();
        const report = try zcode.entity.saveBatch(&dal, Article, refs.items, &s);
        const total = nowNs() - start;
        std.debug.print("[bench] 批量新增 {d} 条（实际插入 {d}）\n", .{ n, report.inserted });
        try results.append(gpa, .{ .name = "批量 saveBatch（新增）", .total_ns = total, .iterations = n });
    }

    // 3) 按主键查（TableRef，不走缓存）
    {
        const n = 2000;
        var i: usize = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            const pk: i64 = @intCast(@mod(i, 500) + 1);
            _ = try table.findByPk(&s, &.{.{ .int = pk }});
        }
        try results.append(gpa, .{ .name = "findByPk（直连库）", .total_ns = nowNs() - start, .iterations = n });
    }

    // 4) 整表缓存命中（不可变快照 + 原子发布：命中路径不加锁）
    {
        var c = zcode.cache.Cache(Article).init(&dal, 60);
        defer c.deinit();
        _ = try c.all(&s);
        // 诊断输出：确认缓存真的装上了（未装载/超限时 get 会退回 SQL，数字会与 findByPk 一致）
        std.debug.print("[bench] 整表缓存：using={} max_rows={d} 装载={d} 行\n", .{ c.usingCache(), c.max_rows, c.cachedRows() });

        const n = 20000;
        var i: usize = 0;
        var sink: i32 = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            const pk: i64 = @intCast(@mod(i, 500) + 1);
            if (try c.get(&s, pk)) |e| sink +%= e.Id;
        }
        const total = nowNs() - start;
        std.mem.doNotOptimizeAway(sink);
        try results.append(gpa, .{ .name = "整表缓存 get（命中）", .total_ns = total, .iterations = n });
    }

    // 4b) 单对象缓存命中（按主键缓存单行；大表场景）
    {
        var sc = zcode.cache.SingleCache(Article).init(&dal, 60);
        defer sc.deinit();
        _ = try sc.get(&s, 1);

        const n = 20000;
        var i: usize = 0;
        var sink: i32 = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            const pk: i64 = @intCast(@mod(i, 500) + 1);
            if (try sc.get(&s, pk)) |e| sink +%= e.Id;
        }
        const total = nowNs() - start;
        std.mem.doNotOptimizeAway(sink);
        try results.append(gpa, .{ .name = "单对象缓存 get（命中）", .total_ns = total, .iterations = n });
    }

    // 5) 条件分页查询（10 行/页）
    {
        const n = 300;
        var w = zcode.Where.init(gpa);
        defer w.deinit();
        _ = try w.eq("Author", .{ .text = "bench" });
        var q = zcode.Query.init(gpa);
        defer q.deinit();
        q.filter = &w;
        q.limit = 10;

        var i: usize = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            _ = try table.queryRows(&s, &q);
        }
        try results.append(gpa, .{ .name = "条件分页查询 10 行", .total_ns = nowNs() - start, .iterations = n });
    }

    // 6) 分表路由（纯计算：时间 → 分片表名）
    {
        const policy = zcode.shards.TimePolicy{
            .gpa = gpa,
            .field = "CreateTime",
            .base_conn = "DH",
            .base_table = "Bench_Article",
            .table_policy = "{0}_{1:yyyyMMdd}",
            .step_ms = zcode.shards.day_ms,
            .level = .day,
        };

        const n = 20000;
        const base_ms = zcode.shards.msFromCivil(2024, 5, 6, 7, 8, 9);
        var i: usize = 0;
        var sink: usize = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            const sm = (try policy.shardAt(base_ms + @as(i64, @intCast(i)) * zcode.shards.day_ms)).?;
            sink +%= sm.table_name.len;
            sm.deinit(gpa);
        }
        const total = nowNs() - start;
        std.mem.doNotOptimizeAway(sink);
        try results.append(gpa, .{ .name = "分表路由（单点 → 表名）", .total_ns = total, .iterations = n });
    }

    // 7) 写入拦截器开销（insert 带 TimeInterceptor 补审计列）
    {
        var ti = zcode.interceptor.TimeInterceptor{};
        var chain = zcode.interceptor.Chain.init(gpa);
        defer chain.deinit();
        try chain.add(ti.interceptor());
        dal.setInterceptorChain(&chain);
        defer dal.setInterceptorChain(null);

        const n = 500;
        var i: usize = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            var e = Article{};
            e.Title = try std.fmt.allocPrint(aa, "ic-{d}", .{i});
            e.Author = "bench";
            e.Score = @intCast(i);
            _ = try zcode.entity.insert(&dal, &e, &s);
        }
        try results.append(gpa, .{ .name = "insert + 时间拦截器", .total_ns = nowNs() - start, .iterations = n });
    }

    // 8) 导航属性：批量填充（一次 IN 查回 + 分组，替代 N+1 逐条查）
    {
        const n = 200;
        var i: usize = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            var g = try zcode.navigation.fillMany(&dal, Article, &s, "Score", &.{ 1, 2, 3, 4, 5 });
            g.deinit();
        }
        try results.append(gpa, .{ .name = "导航批量填充（5 主键）", .total_ns = nowNs() - start, .iterations = n });
    }

    // 9) 脏状态探查（u256 位运算，零分配；对照 Rust `perf_guard` 的 dirty_probe）
    {
        const n = 2_000_000;
        var bits: zcode.entity.DirtyBits = 0;
        zcode.entity.markDirty(&bits, 3);

        var i: usize = 0;
        var sink: usize = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            if (zcode.entity.isDirty(bits, @mod(i, 64))) sink += 1;
        }
        const total = nowNs() - start;
        std.mem.doNotOptimizeAway(sink);
        try results.append(gpa, .{ .name = "脏状态探查（isDirty）", .total_ns = total, .iterations = n });
    }

    // 10) update_by_pk：只写 1 个脏列（对照 Rust `update_by_pk`）
    {
        const n = 20_000;
        var e = Article{ .Id = 1 };
        var i: usize = 0;
        const start = nowNs();
        while (i < n) : (i += 1) {
            e.Score = @intCast(@mod(i, 1000));
            e.dirty = 0;
            zcode.entity.markDirty(&e.dirty, 3);
            _ = try zcode.entity.update(&dal, &e, &s);
        }
        try results.append(gpa, .{ .name = "update_by_pk（只写 1 个脏列）", .total_ns = nowNs() - start, .iterations = n });
    }

    // 11) 批量脏列合并 UPDATE：500 行同脏列 → 一条多行 UPDATE（一次往返）
    {
        const n = 500;
        const items = try aa.alloc(Article, n);
        const ptrs = try aa.alloc(*Article, n);
        for (items, 0..) |*e, i| {
            e.* = .{ .Id = @intCast(i + 1), .Score = @intCast(i) };
            zcode.entity.markDirty(&e.dirty, 3);
            ptrs[i] = e;
        }
        const start = nowNs();
        const rep = try zcode.entity.saveBatchWith(&dal, Article, ptrs, &s, .upsert);
        const total = nowNs() - start;
        std.debug.print("[bench] 批量脏列 UPDATE：影响 {d} 行\n", .{rep.updated});
        try results.append(gpa, .{ .name = "批量脏列 UPDATE（500 行/1 条）", .total_ns = total, .iterations = n });
    }

    // 12) 「先查后写」vs「insert_ignore 判存」：同 2000 行、其中一半已存在
    //     注意：模型里 Score 非空，行必须给全 NOT NULL 列，否则 SQLite 报 NOT NULL constraint failed
    {
        const n = 2000;
        const half = n / 2;

        const rowOf = struct {
            fn make(a: std.mem.Allocator, title: []const u8, score: i32) ![]sqlbuild.Field {
                const f = try a.alloc(sqlbuild.Field, 4);
                f[0] = .{ .name = "Title", .value = .{ .text = title } };
                f[1] = .{ .name = "Author", .value = .{ .text = "bench" } };
                f[2] = .{ .name = "Score", .value = .{ .int = score } };
                f[3] = .{ .name = "CreateTime", .value = .{ .datetime = zcode.DateTime.nowLocal() } };
                return f;
            }
        }.make;

        // 准备两批不重叠的数据（前缀区分），各自预插一半 —— 制造「一半已存在」的场景
        const pre_a = try aa.alloc([]const sqlbuild.Field, half);
        const pre_b = try aa.alloc([]const sqlbuild.Field, half);
        for (0..half) |i| {
            pre_a[i] = try rowOf(aa, try std.fmt.allocPrint(aa, "sq-{d}", .{i}), @intCast(i));
            pre_b[i] = try rowOf(aa, try std.fmt.allocPrint(aa, "ig-{d}", .{i}), @intCast(i));
        }
        _ = try table.insertBatch(&s, pre_a);
        _ = try table.insertBatch(&s, pre_b);

        // A：先查后写（每条 1 次 COUNT + 未命中才 INSERT）
        {
            var inserted_a: usize = 0;
            const start = nowNs();
            for (0..n) |i| {
                const title = try std.fmt.allocPrint(aa, "sq-{d}", .{i});
                var w = zcode.Where.init(aa);
                _ = try w.eq("Title", .{ .text = title });
                if (try table.count(&s, &w) == 0) {
                    const one = try rowOf(aa, title, @intCast(i));
                    _ = try table.insertBatch(&s, &.{one});
                    inserted_a += 1;
                }
            }
            const total = nowNs() - start;
            std.debug.print("[bench] 先查后写：插入 {d} / 跳过 {d}\n", .{ inserted_a, n - inserted_a });
            try results.append(gpa, .{ .name = "先查后写（2000 行，半已存在）", .total_ns = total, .iterations = n });
        }

        // B：insert_ignore 一次批量（冲突由数据库判）
        {
            const rows = try aa.alloc([]const sqlbuild.Field, n);
            for (0..n) |i| rows[i] = try rowOf(aa, try std.fmt.allocPrint(aa, "ig-{d}", .{i}), @intCast(i));
            const start = nowNs();
            const inserted = try table.upsertBatch(&s, rows, .insert_ignore);
            const total = nowNs() - start;
            std.debug.print("[bench] insert_ignore：插入 {d} / 跳过 {d}\n", .{ inserted, n - inserted });
            try results.append(gpa, .{ .name = "insert_ignore（2000 行/1 条）", .total_ns = total, .iterations = n });
        }
    }

    // ── 输出 ────────────────────────────────────────────────────────────────
    std.debug.print("\n=== Pek.ZCode 基准（SQLite 内存库，ReleaseFast）===\n", .{});
    std.debug.print("{s: <32} {s: >8} {s: >12} {s: >12}\n", .{ "用例", "次数", "总耗时(ms)", "单次(µs)" });
    for (results.items) |r| {
        const per_us = @as(f64, @floatFromInt(r.total_ns)) / @as(f64, @floatFromInt(r.iterations)) / 1000.0;
        std.debug.print("{s: <32} {d: >8} {d: >12.2} {d: >12.2}\n", .{
            r.name,
            r.iterations,
            @as(f64, @floatFromInt(r.total_ns)) / 1_000_000.0,
            per_us,
        });
    }
    std.debug.print("\n", .{});
}
