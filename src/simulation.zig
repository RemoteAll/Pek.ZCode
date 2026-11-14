//! 测试数据生成（对应 C# `Common/DataSimulation.cs`）。
//!
//! ## 它解决什么问题
//!
//! 压测 / 联调需要「按模型长出一批形状正确的行」，字段类型、长度、可空性都要对得上，
//! 否则插不进去或者撑爆列。C# 侧的做法很简单：遍历非自增字段，
//! **整数 → 随机整数、字符串 → 8 位随机串、时间 → 现在 ±10000 秒**，然后批量写。
//!
//! 这里把「造数」这一段独立出来（写库交给 `dtable.insertBatch`），并补了 C# 没管的两处：
//! - **尊重列长度**：`String(N)` 生成不超过 N 个字符的串（C# 固定 8 位，遇到 `String(4)` 会插失败）；
//! - **可复现**：给定种子，同一次运行内序列确定，用例可断言具体值。
//!
//! ## 与 C# 的差异（写清楚，别指望 1:1）
//! - 不做多线程并行（C# 的 `Parallel.For` 是压测手段，Zig 侧由调用方决定并发度）；
//! - 不内置「按批提交 + 吞吐日志」，只产出值；批量写走 `dbtable.insertBatch`。

const std = @import("std");
const model = @import("model.zig");
const types = @import("types.zig");
const Value = @import("zzig").db.Value;

pub const Options = struct {
    /// 随机种子（同一种子 → 同一批数据，用例可断言）
    seed: u64 = 0x5EED_1234,
    /// 时间字段的基准时刻（毫秒）；0 = 用 `clock.nowMs()`
    now_ms: i64 = 0,
    /// 时间抖动幅度（秒，正负各一半）——与 C# 的 ±10000 秒一致
    time_jitter_s: i64 = 10_000,
    /// 字符串缺省长度（列没写长度时用它）
    default_string_len: usize = 8,
};

pub const Error = error{
    /// 列是二进制/JSON 等无法简单造值的类型（调用方要么跳过，要么自己给值）
    UnsupportedColumn,
};

/// 造数器：持有随机状态与基准时间。
pub const Simulator = struct {
    rng: std.Random.DefaultPrng,
    opts: Options,
    now_ms: i64,

    pub fn init(opts: Options) Simulator {
        var s = Simulator{
            .rng = std.Random.DefaultPrng.init(opts.seed),
            .opts = opts,
            .now_ms = opts.now_ms,
        };
        if (s.now_ms == 0) s.now_ms = @import("clock.zig").nowMs();
        return s;
    }

    /// 造一行的值（顺序与 `table.columns` 一致）。
    ///
    /// - **自增列**填 `.null`：由数据库生成（调用方按 `dbtable` 的规则跳过自增列，这里给 null 只是占位）；
    /// - 其它列按类型给值：整数族随机、浮点随机、`decimal` 两位小数、`string` ≤ 列长度、`datetime` 在基准附近、
    ///   `boolean` 随机、`binary`/`json` 返回 `error.UnsupportedColumn`（让调用方显式决定）。
    pub fn fillRow(self: *Simulator, arena: std.mem.Allocator, table: *const model.TableMeta) ![]Value {
        const values = try arena.alloc(Value, table.columns.len);
        for (table.columns, 0..) |*col, i| {
            values[i] = try self.valueFor(arena, col);
        }
        return values;
    }

    fn valueFor(self: *Simulator, arena: std.mem.Allocator, col: *const model.ColumnMeta) !Value {
        if (col.identity) return .null;

        const r = self.rng.random();
        return switch (col.data_type) {
            .boolean => .{ .boolean = r.boolean() },
            .byte => .{ .int = @intCast(r.intRangeAtMost(u8, 0, 255)) },
            .int16 => .{ .int = r.intRangeAtMost(i16, 0, std.math.maxInt(i16)) },
            .int32 => .{ .int = r.intRangeAtMost(i32, 0, std.math.maxInt(i32)) },
            .int64 => .{ .int = r.intRangeAtMost(i64, 0, std.math.maxInt(i32)) },
            .single => .{ .float = r.float(f32) },
            .double => .{ .float = r.float(f64) },
            .decimal => .{
                .decimal = @import("zzig").Decimal.init(r.intRangeAtMost(i64, 0, 9_999_999), 2) catch .zero(),
            },
            .string => .{ .text = try self.randomStringAlloc(arena, r, col.length) },
            .datetime => .{ .datetime = self.randomDatetime() },
            // GUID 列造真 GUID（不是随机字符串）：造数、导入、对拍都需要能被当成 GUID 校验
            .guid => .{ .text = try @import("zzig").Guid.guidAlloc(arena) },
            .binary, .json => Error.UnsupportedColumn,
        };
    }

    /// 随机时间：基准时刻 ± jitter（C# 是 `Now.AddSeconds(Rand.Next(-10000, 10000))`）。
    fn randomDatetime(self: *Simulator) @import("zzig").DateTime {
        const jitter = self.opts.time_jitter_s;
        const delta_s = if (jitter <= 0) 0 else self.rng.random().intRangeAtMost(i64, -jitter, jitter);
        const secs = @divFloor(self.now_ms, 1000) + delta_s;
        return @import("zzig").DateTime.fromUnixSeconds(secs);
    }

    /// 随机字符串：长度 = min(列长度, 默认长度)（列长度 <= 0 时取默认）。
    /// 只出小写字母与数字，避免方言/字符集差异带来的意外。
    fn randomStringAlloc(self: *Simulator, arena: std.mem.Allocator, r: std.Random, col_len: i32) ![]const u8 {
        const max_len: usize = if (col_len > 0) @intCast(col_len) else self.opts.default_string_len;
        const len = @min(max_len, self.opts.default_string_len);
        if (len == 0) return arena.dupe(u8, "");

        const charset = "abcdefghijklmnopqrstuvwxyz0123456789";
        const buf = try arena.alloc(u8, len);
        for (buf) |*c| c.* = charset[r.intRangeLessThan(usize, 0, charset.len)];
        return buf;
    }
};

/// 便捷入口：造 `count` 行（每行都是完整值数组，内存归 `arena`）。
pub fn rowsAlloc(
    arena: std.mem.Allocator,
    table: *const model.TableMeta,
    count: usize,
    opts: Options,
) ![]const []Value {
    var sim = Simulator.init(opts);
    const rows = try arena.alloc([]Value, count);
    for (rows) |*row| row.* = try sim.fillRow(arena, table);
    return rows;
}

// ── 用例 ────────────────────────────────────────────────────────────────────

fn testTable(a: std.mem.Allocator) !model.TableMeta {
    const xml =
        \\<EntityModel><Tables><Table Name="SimUser" TableName="Sim_User">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Name" DataType="String" Length="4" />
        \\    <Column Name="Age" DataType="Int32" />
        \\    <Column Name="Score" DataType="Double" />
        \\    <Column Name="CreateTime" DataType="DateTime" />
        \\    <Column Name="Enable" DataType="Boolean" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m = try model.EntityModel.parse(a, xml);
    return m.tables[0];
}

test "造数 - 自增列留空、类型/长度都对得上" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try testTable(a);
    const rows = try rowsAlloc(a, &t, 20, .{ .seed = 42 });
    try std.testing.expectEqual(@as(usize, 20), rows.len);

    for (rows) |row| {
        try std.testing.expectEqual(@as(usize, 6), row.len);
        // 自增列：不造值（数据库生成）
        try std.testing.expect(row[0].isNull());
        // String(4)：长度不能超过 4（C# 固定 8 位，遇到 String(4) 会插失败）
        const name = row[1].text;
        try std.testing.expect(name.len <= 4 and name.len > 0);
        // 整数 / 浮点 / 时间 / 布尔
        try std.testing.expect(row[2].int >= 0);
        try std.testing.expect(row[3].float == row[3].float); // 非 NaN
        _ = row[4].datetime;
        try std.testing.expect(row[5] == .boolean);
    }
}

test "造数 - 同种子可复现，不同种子结果不同" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try testTable(a);

    const r1 = try rowsAlloc(a, &t, 3, .{ .seed = 7, .now_ms = 1_700_000_000_000 });
    const r2 = try rowsAlloc(a, &t, 3, .{ .seed = 7, .now_ms = 1_700_000_000_000 });
    try std.testing.expectEqualStrings(r1[0][1].text, r2[0][1].text);
    try std.testing.expectEqual(r1[0][2].int, r2[0][2].int);

    const r3 = try rowsAlloc(a, &t, 3, .{ .seed = 8, .now_ms = 1_700_000_000_000 });
    // 极大数据下仍可能相同，但 3 行 32 位随机整数全撞上的概率可以忽略
    var same = true;
    for (r1, r3) |x, y| {
        if (x[2].int != y[2].int) same = false;
    }
    try std.testing.expect(!same);
}

test "造数 - 时间字段围绕基准时刻抖动" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try testTable(a);

    const base: i64 = 1_700_000_000_000;
    const r = try rowsAlloc(a, &t, 10, .{ .seed = 99, .now_ms = base, .time_jitter_s = 60 });
    const lo = @divFloor(base, 1000) - 60;
    const hi = @divFloor(base, 1000) + 60;
    for (r) |row| {
        const secs = row[4].datetime.toUnixSeconds();
        try std.testing.expect(secs >= lo and secs <= hi);
    }
}

test "造数 - 二进制/JSON 列明确报 UnsupportedColumn（不静默给空值）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const xml =
        \\<EntityModel><Tables><Table Name="SimBlob" TableName="Sim_Blob">
        \\  <Columns><Column Name="Data" DataType="Binary" /></Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m = try model.EntityModel.parse(a, xml);
    const t = m.tables[0];
    try std.testing.expectError(Error.UnsupportedColumn, rowsAlloc(a, &t, 1, .{}));
    _ = types.DataType.binary;
}
