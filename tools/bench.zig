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

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
    \\  <Option><Namespace>Bench.Entity</Namespace><ConnName>DH</ConnName></Option>
    \\  <Tables>
    \\    <Table Name="Article" TableName="Bench_Article">
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

    // 4) 整表缓存命中
    {
        var c = zcode.cache.Cache(Article).init(&dal, 60);
        defer c.deinit();
        _ = try c.all(&s);

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
