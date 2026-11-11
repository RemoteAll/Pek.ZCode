//! 分表 / 分库（对应 DH.NCode `XCode.Shards` 与 Rust `Pek.RCode/src/shards.rs`）。
//!
//! ## 语义对齐
//!
//! - **`ShardModel`**（C# `record ShardModel(String ConnName, String TableName)`）：一次路由的结果，
//!   同时给出「连接名」与「物理表名」。
//! - **`TimePolicy`**（C# `TimeShardPolicy`）：按时间列分表。`TablePolicy="{0}_{1:yyyyMM}"`
//!   即「基础表名_年月」；`ConnPolicy` 同理用于分库。
//! - **`Step` 与 `Level`**：默认步进 1 天；`Level` 未显式指定时按 `Step` 反推
//!   （≥360 天 = 年、28~31 天 = 月、1 天 = 日、1 小时 = 时），与 C# `GetLevel` 一致。
//! - **区间扫描**：`shardsInRange(start, end)` 按步进枚举区间内**去重**的分片；
//!   `start > end` 时按反序返回（C# 同样支持倒序）。
//! - **条件推导**：`shardsForWhere` 从查询条件里找时间列，`=` 定位单表，
//!   `>`/`>=` 与 `<`/`<=` 组合出区间；条件不足时报 `error.InsufficientShardCondition`
//!   （C# 抛「分表策略因条件不足无法执行分表查询操作」）。
//! - **雪花 Id**：时间列是 `Int64` 时按雪花解析（41 位毫秒时间戳 + 10 位机器 + 12 位序列，
//!   纪元 1970-01-01，与 `DH.NCore` 的 `Snowflake` 一致）。
//!
//! ## 与 C# 的差异（有意为之）
//!
//! - **不做 `Trim`**：C# 在「只命中一个分片且区间正好覆盖整片」时会**删掉** Where 里的时间条件
//!   （优化掉冗余谓词）。Zig 侧不改调用方的 `Where`——`Where` 是调用方持有的可变对象，
//!   静默删除条件属于**副作用**，排查困难；性能收益仅限「多一个恒真谓词」，代价不值。
//! - **格式串只支持子集**：`{0}`（基础名）与 `{1:<pattern>}`，`pattern` 支持
//!   `yyyy` / `yy` / `MM` / `dd` / `HH` / `mm` / `ss` 与字面量。.NET 的 `String.Format`
//!   支持任意格式（含中文、时区），那些用法在分表场景里没有必要。

const std = @import("std");
const Value = @import("zzig").db.Value;
const query = @import("query.zig");
const Where = query.Where;
const clock = @import("clock.zig");

/// 一次分片路由结果（连接名 + 物理表名）。
pub const ShardModel = struct {
    conn_name: []const u8,
    table_name: []const u8,

    pub fn deinit(self: ShardModel, gpa: std.mem.Allocator) void {
        if (self.conn_name.len > 0) gpa.free(self.conn_name);
        if (self.table_name.len > 0) gpa.free(self.table_name);
    }

    pub fn eql(a: ShardModel, b: ShardModel) bool {
        return std.mem.eql(u8, a.conn_name, b.conn_name) and std.mem.eql(u8, a.table_name, b.table_name);
    }

    pub fn describeAlloc(self: ShardModel, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}#{s}", .{ self.conn_name, self.table_name });
    }
};

/// 时间级别（决定步进方式；对应 C# `StatLevels` 的年/月/日/时）。
pub const Level = enum {
    year,
    month,
    day,
    hour,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .year => "Year",
            .month => "Month",
            .day => "Day",
            .hour => "Hour",
        };
    }
};

/// 一天 / 一小时的毫秒数。
pub const day_ms: i64 = 86_400_000;
pub const hour_ms: i64 = 3_600_000;

/// 按步进反推级别（对齐 C# `TimeShardPolicy.GetLevel`）。
pub fn levelOfStep(step_ms: i64) Level {
    const days = @divTrunc(step_ms, day_ms);
    if (days >= 360) return .year;
    if (days >= 28 and days <= 31) return .month;
    if (days == 1) return .day;
    if (step_ms == hour_ms) return .hour;
    // 其它步进：按小时级枚举（最细粒度），保证不漏片
    return .hour;
}

// ───────────────────── 公历换算（无时区，纯数值） ─────────────────────

/// 公历时间片（毫秒 → 年月日时分秒）。
pub const Civil = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// 从 Unix 毫秒得到公历字段（Howard Hinnant `civil_from_days` 算法，1970-01-01 起算）。
pub fn civilFromMs(ms: i64) Civil {
    var days = @divFloor(ms, day_ms);
    var rem = @mod(ms, day_ms);
    if (rem < 0) {
        rem += day_ms;
        days -= 1;
    }

    const secs = @divTrunc(rem, 1000);
    const hour: u8 = @intCast(@divTrunc(secs, 3600));
    const minute: u8 = @intCast(@divTrunc(@mod(secs, 3600), 60));
    const second: u8 = @intCast(@mod(secs, 60));

    // days → y/m/d
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe: i64 = z - era * 146_097; // [0, 146096]
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = mp + (if (mp < 10) @as(i64, 3) else -9);

    return .{
        .year = @intCast(y + (if (m <= 2) @as(i64, 1) else 0)),
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

/// 公历字段 → Unix 毫秒（秒级精度）。
pub fn msFromCivil(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    var y: i64 = year;
    const m: i64 = month;
    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146_097 + doe - 719_468;
    return days * day_ms + @as(i64, hour) * hour_ms + @as(i64, minute) * 60_000 + @as(i64, second) * 1000;
}

/// 雪花 Id 的时间部分（毫秒时间戳，纪元 1970-01-01）。
/// 位宽对齐 `DH.NCore/Snowflake`：时间 41 位 | 机器 10 位 | 序列 12 位 → 时间左移 22 位。
pub fn snowflakeTimeMs(id: i64) i64 {
    if (id <= 0) return 0;
    return id >> 22;
}

// ───────────────────────── 时间分表策略 ─────────────────────────

pub const TimePolicy = struct {
    gpa: std.mem.Allocator,
    /// 时间列（实体字段名或物理列名，比较时忽略大小写）
    field: []const u8,
    /// 基础连接名（`{0}` 的取值为它）
    base_conn: []const u8,
    /// 基础表名（`{0}` 的取值为它）
    base_table: []const u8,
    /// 连接名模板，如 `{0}_{1:yyyy}`
    conn_policy: ?[]const u8 = null,
    /// 表名模板，如 `{0}_{1:yyyyMM}`
    table_policy: ?[]const u8 = null,
    /// 区间枚举步进（毫秒），默认 1 天
    step_ms: i64 = day_ms,
    /// 显式级别（为空则按 `step_ms` 反推）
    level: ?Level = null,

    pub fn init(
        gpa: std.mem.Allocator,
        field: []const u8,
        base_conn: []const u8,
        base_table: []const u8,
        table_policy: ?[]const u8,
    ) TimePolicy {
        return .{
            .gpa = gpa,
            .field = field,
            .base_conn = base_conn,
            .base_table = base_table,
            .table_policy = table_policy,
        };
    }

    pub fn levelOf(self: *const TimePolicy) Level {
        if (self.level) |l| return l;
        return levelOfStep(self.step_ms);
    }

    /// 该时刻属于哪个分片；两个策略都没配时返回 null（不分片）。
    pub fn shardAt(self: *const TimePolicy, ms: i64) !?ShardModel {
        if (self.conn_policy == null and self.table_policy == null) return null;

        const c = civilFromMs(ms);
        const conn = if (self.conn_policy) |tpl|
            try renderPolicy(self.gpa, tpl, self.base_conn, c)
        else
            try self.gpa.dupe(u8, self.base_conn);
        errdefer self.gpa.free(conn);

        const table = if (self.table_policy) |tpl|
            try renderPolicy(self.gpa, tpl, self.base_table, c)
        else
            try self.gpa.dupe(u8, self.base_table);

        return ShardModel{ .conn_name = conn, .table_name = table };
    }

    /// 由字段值（时间 / 雪花 Id）定位分片。
    pub fn shardOf(self: *const TimePolicy, value: Value) !?ShardModel {
        const ms = try self.timeOf(value);
        return self.shardAt(ms);
    }

    fn timeOf(self: *const TimePolicy, value: Value) !i64 {
        return switch (value) {
            .datetime => |dt| msFromCivil(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second),
            .int => |n| blk: {
                const ms = snowflakeTimeMs(n);
                if (ms <= 0) {
                    std.debug.print("[zcode] 分表：雪花 Id 解析时间失败（id={d}，字段 {s}）\n", .{ n, self.field });
                    return error.InvalidShardValue;
                }
                break :blk ms;
            },
            .text => |t| blk: {
                const dt = @import("zzig").DateTime.parse(t) catch {
                    std.debug.print("[zcode] 分表：时间列文本无法解析（值 {s}，字段 {s}）\n", .{ t, self.field });
                    return error.InvalidShardValue;
                };
                break :blk msFromCivil(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second);
            },
            else => {
                std.debug.print("[zcode] 分表：无法识别的时间值类型（字段 {s}）\n", .{self.field});
                return error.InvalidShardValue;
            },
        };
    }

    /// 区间内（含 start，不含 end）的去重分片；`start > end` 时反序返回。
    pub fn shardsInRange(self: *const TimePolicy, start_ms: i64, end_ms: i64, out: *std.ArrayList(ShardModel)) !void {
        if (start_ms == end_ms) {
            if (try self.shardAt(start_ms)) |m| try appendUnique(self.gpa, out, m);
            return;
        }
        if (start_ms < end_ms) return self.walk(start_ms, end_ms, out, false);
        return self.walk(end_ms, start_ms, out, true);
    }

    fn walk(self: *const TimePolicy, start_ms: i64, end_ms: i64, out: *std.ArrayList(ShardModel), reverse: bool) !void {
        const level = self.levelOf();
        var cursor = start_ms;
        var guard: usize = 0;
        while (cursor < end_ms) {
            if (try self.shardAt(cursor)) |m| {
                if (!containsModel(out.items, m)) {
                    if (reverse) {
                        // 反序：插到最前面（分片数量很少，线性插入即可）
                        try out.insert(self.gpa, 0, m);
                    } else {
                        try out.append(self.gpa, m);
                    }
                } else {
                    m.deinit(self.gpa);
                }
            }
            cursor = nextByLevel(level, cursor);
            guard += 1;
            if (guard > 1_000_000) {
                std.debug.print("[zcode] 分表：区间枚举超过上限（可能是 step 配置过小）\n", .{});
                return error.ShardRangeTooLarge;
            }
        }
    }

    /// 从 Where 推导分片。`=` 定位单表；`>`/`>=` 与 `<`/`<=` 组合出区间。
    /// 条件不足返回 `error.InsufficientShardCondition`（**不猜**）。
    pub fn shardsForWhere(self: *const TimePolicy, w: *const Where, out: *std.ArrayList(ShardModel)) !void {
        var eq_ms: ?i64 = null;
        var min_ms: ?i64 = null;
        var max_ms: ?i64 = null;

        for (w.conds.items) |cond| {
            if (!std.ascii.eqlIgnoreCase(cond.column, self.field)) continue;
            if (cond.values.len == 0) continue;
            const raw = cond.values[0];
            switch (cond.op) {
                .eq => eq_ms = try self.timeOf(raw),
                .gt, .ge => {
                    var ms = try self.timeOf(raw);
                    // C#：`>` 时加 1 秒，把边界排除在外
                    if (cond.op == .gt) ms += 1000;
                    min_ms = ms;
                },
                .lt, .le => max_ms = try self.timeOf(raw),
                else => {},
            }
        }

        if (eq_ms) |ms| {
            if (try self.shardAt(ms)) |m| try appendUnique(self.gpa, out, m);
            return;
        }
        if (min_ms) |lo| {
            const hi = max_ms orelse clock.nowMs();
            try self.shardsInRange(lo, hi, out);
            return;
        }

        std.debug.print(
            "[zcode] 分表：查询条件缺少时间列 [{s}] 的等值或区间条件，无法确定分片\n",
            .{self.field},
        );
        return error.InsufficientShardCondition;
    }
};

/// 释放一批分片模型。
pub fn freeModels(gpa: std.mem.Allocator, models: []ShardModel) void {
    for (models) |m| m.deinit(gpa);
    gpa.free(models);
}

fn containsModel(items: []const ShardModel, m: ShardModel) bool {
    for (items) |it| {
        if (it.eql(m)) return true;
    }
    return false;
}

fn appendUnique(gpa: std.mem.Allocator, out: *std.ArrayList(ShardModel), m: ShardModel) !void {
    if (containsModel(out.items, m)) {
        m.deinit(gpa);
        return;
    }
    try out.append(gpa, m);
}

/// 按级别推进到下一个整点（解决「每月/每年天数不固定」的问题，对齐 C# `GetNext`）。
pub fn nextByLevel(level: Level, ms: i64) i64 {
    const c = civilFromMs(ms);
    return switch (level) {
        .year => msFromCivil(c.year + 1, 1, 1, 0, 0, 0),
        .month => blk: {
            const y: i32 = if (c.month == 12) c.year + 1 else c.year;
            const m: u8 = if (c.month == 12) 1 else c.month + 1;
            break :blk msFromCivil(y, m, 1, 0, 0, 0);
        },
        .day => msFromCivil(c.year, c.month, c.day, 0, 0, 0) + day_ms,
        .hour => msFromCivil(c.year, c.month, c.day, c.hour, 0, 0) + hour_ms,
    };
}

/// 渲染策略模板：`{0}` = 基础名，`{1:<pattern>}` = 时间，其余字符原样输出。
pub fn renderPolicy(gpa: std.mem.Allocator, tpl: []const u8, base: []const u8, c: Civil) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < tpl.len) {
        if (tpl[i] != '{') {
            try out.append(gpa, tpl[i]);
            i += 1;
            continue;
        }
        const close = std.mem.indexOfPos(u8, tpl, i, "}") orelse {
            std.debug.print("[zcode] 分表：策略模板缺少 '}}'（{s}）\n", .{tpl});
            return error.Model;
        };
        const inner = tpl[i + 1 .. close];
        if (std.mem.eql(u8, inner, "0")) {
            try out.appendSlice(gpa, base);
        } else if (std.mem.eql(u8, inner, "1")) {
            try appendDatePattern(gpa, &out, "yyyyMMdd", c);
        } else if (std.mem.startsWith(u8, inner, "1:")) {
            try appendDatePattern(gpa, &out, inner[2..], c);
        } else {
            std.debug.print("[zcode] 分表：不支持的模板占位 {{{s}}}（只支持 {{0}} 与 {{1:pattern}}）\n", .{inner});
            return error.Model;
        }
        i = close + 1;
    }
    return out.toOwnedSlice(gpa);
}

/// 日期模式渲染：支持 `yyyy` / `yy` / `MM` / `dd` / `HH` / `mm` / `ss`，其余字符原样输出。
pub fn appendDatePattern(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pattern: []const u8, c: Civil) !void {
    var i: usize = 0;
    while (i < pattern.len) {
        if (std.mem.startsWith(u8, pattern[i..], "yyyy")) {
            try appendZeroPadded(gpa, out, c.year, 4);
            i += 4;
        } else if (std.mem.startsWith(u8, pattern[i..], "yy")) {
            try appendZeroPadded(gpa, out, @mod(c.year, 100), 2);
            i += 2;
        } else if (std.mem.startsWith(u8, pattern[i..], "MM")) {
            try appendZeroPadded(gpa, out, c.month, 2);
            i += 2;
        } else if (std.mem.startsWith(u8, pattern[i..], "dd")) {
            try appendZeroPadded(gpa, out, c.day, 2);
            i += 2;
        } else if (std.mem.startsWith(u8, pattern[i..], "HH")) {
            try appendZeroPadded(gpa, out, c.hour, 2);
            i += 2;
        } else if (std.mem.startsWith(u8, pattern[i..], "mm")) {
            try appendZeroPadded(gpa, out, c.minute, 2);
            i += 2;
        } else if (std.mem.startsWith(u8, pattern[i..], "ss")) {
            try appendZeroPadded(gpa, out, c.second, 2);
            i += 2;
        } else {
            try out.append(gpa, pattern[i]);
            i += 1;
        }
    }
}

/// 零填充输出非负整数（**不用** `{d:0>4}`：Zig 0.17 的格式说明会带上多余符号位）。
fn appendZeroPadded(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype, width: usize) !void {
    var num_buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch return error.Model;
    var pad = width;
    if (text.len < width) pad = width - text.len else pad = 0;
    while (pad > 0) : (pad -= 1) try out.append(gpa, '0');
    try out.appendSlice(gpa, text);
}

// ───────────────────────────── 测试 ─────────────────────────────

test "公历换算往返（含闰年与纪元边界）" {
    // 2024-02-29 13:14:15（闰日）
    const ms = msFromCivil(2024, 2, 29, 13, 14, 15);
    const c = civilFromMs(ms);
    try std.testing.expectEqual(@as(i32, 2024), c.year);
    try std.testing.expectEqual(@as(u8, 2), c.month);
    try std.testing.expectEqual(@as(u8, 29), c.day);
    try std.testing.expectEqual(@as(u8, 13), c.hour);
    try std.testing.expectEqual(@as(u8, 14), c.minute);
    try std.testing.expectEqual(@as(u8, 15), c.second);

    // 纪元零点
    try std.testing.expectEqual(@as(i64, 0), msFromCivil(1970, 1, 1, 0, 0, 0));

    // 负时间（1970 之前）
    const neg = msFromCivil(1969, 12, 31, 23, 59, 59);
    try std.testing.expectEqual(@as(i64, -1000), neg);
    const cn = civilFromMs(neg);
    try std.testing.expectEqual(@as(i32, 1969), cn.year);
    try std.testing.expectEqual(@as(u8, 12), cn.month);
    try std.testing.expectEqual(@as(u8, 31), cn.day);
}

test "模板渲染：{0} 与日期模式" {
    const a = std.testing.allocator;
    const c = civilFromMs(msFromCivil(2024, 3, 7, 9, 5, 2));

    const t1 = try renderPolicy(a, "{0}_{1:yyyyMM}", "DH_Log", c);
    defer a.free(t1);
    try std.testing.expectEqualStrings("DH_Log_202403", t1);

    const t2 = try renderPolicy(a, "{0}_{1:yyyyMMddHH}", "DH_Log", c);
    defer a.free(t2);
    try std.testing.expectEqualStrings("DH_Log_2024030709", t2);

    const t3 = try renderPolicy(a, "{0}_{1:yy-MM-dd}", "T", c);
    defer a.free(t3);
    try std.testing.expectEqualStrings("T_24-03-07", t3);

    // 不支持的模式 → error.Model（不静默生成错表名）
    try std.testing.expectError(error.Model, renderPolicy(a, "{0}_{2}", "T", c));
}

test "步进反推级别" {
    try std.testing.expectEqual(Level.year, levelOfStep(365 * day_ms));
    try std.testing.expectEqual(Level.month, levelOfStep(30 * day_ms));
    try std.testing.expectEqual(Level.day, levelOfStep(day_ms));
    try std.testing.expectEqual(Level.hour, levelOfStep(hour_ms));
}

test "按月分表：单点定位与跨月区间去重" {
    const a = std.testing.allocator;
    const p = TimePolicy{
        .gpa = a,
        .field = "CreateTime",
        .base_conn = "DH",
        .base_table = "DH_Log",
        .table_policy = "{0}_{1:yyyyMM}",
        .step_ms = 30 * day_ms,
        .level = .month,
    };

    // 单点
    const m = (try p.shardAt(msFromCivil(2024, 3, 15, 10, 0, 0))).?;
    defer m.deinit(a);
    try std.testing.expectEqualStrings("DH", m.conn_name);
    try std.testing.expectEqualStrings("DH_Log_202403", m.table_name);

    // 区间跨越 2024-01-10 → 2024-04-02：4 月 2 日仍落在 4 月分片，故共 4 片
    var out: std.ArrayList(ShardModel) = .empty;
    defer {
        for (out.items) |it| it.deinit(a);
        out.deinit(a);
    }
    try p.shardsInRange(msFromCivil(2024, 1, 10, 0, 0, 0), msFromCivil(2024, 4, 2, 0, 0, 0), &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings("DH_Log_202401", out.items[0].table_name);
    try std.testing.expectEqualStrings("DH_Log_202402", out.items[1].table_name);
    try std.testing.expectEqualStrings("DH_Log_202403", out.items[2].table_name);
    try std.testing.expectEqualStrings("DH_Log_202404", out.items[3].table_name);

    // 倒序区间：结果反序
    var rev: std.ArrayList(ShardModel) = .empty;
    defer {
        for (rev.items) |it| it.deinit(a);
        rev.deinit(a);
    }
    try p.shardsInRange(msFromCivil(2024, 4, 2, 0, 0, 0), msFromCivil(2024, 1, 10, 0, 0, 0), &rev);
    try std.testing.expectEqual(@as(usize, 4), rev.items.len);
    try std.testing.expectEqualStrings("DH_Log_202404", rev.items[0].table_name);
    try std.testing.expectEqualStrings("DH_Log_202401", rev.items[3].table_name);
}

test "分库 + 分表同时生效" {
    const a = std.testing.allocator;
    const p = TimePolicy{
        .gpa = a,
        .field = "Id",
        .base_conn = "DH",
        .base_table = "DH_Order",
        .conn_policy = "{0}_{1:yyyy}",
        .table_policy = "{0}_{1:yyyyMM}",
        .step_ms = 365 * day_ms,
        .level = .year,
    };

    // 雪花 Id：时间部分 = 2024-05-06 07:08:09
    const ms = msFromCivil(2024, 5, 6, 7, 8, 9);
    const id = ms << 22 | 7;
    try std.testing.expectEqual(ms, snowflakeTimeMs(id));

    const m = (try p.shardOf(.{ .int = id })).?;
    defer m.deinit(a);
    try std.testing.expectEqualStrings("DH_2024", m.conn_name);
    try std.testing.expectEqualStrings("DH_Order_202405", m.table_name);
}

test "条件推导：等值定位单表，区间联合，条件不足报错" {
    const a = std.testing.allocator;
    const p = TimePolicy{
        .gpa = a,
        .field = "CreateTime",
        .base_conn = "DH",
        .base_table = "DH_Log",
        .table_policy = "{0}_{1:yyyyMM}",
        .step_ms = 30 * day_ms,
        .level = .month,
    };

    // 等值
    var w = Where.init(a);
    defer w.deinit();
    _ = try w.eq("CreateTime", .{ .datetime = .{ .year = 2024, .month = 7, .day = 2 } });
    var out: std.ArrayList(ShardModel) = .empty;
    defer {
        for (out.items) |it| it.deinit(a);
        out.deinit(a);
    }
    try p.shardsForWhere(&w, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("DH_Log_202407", out.items[0].table_name);

    // 区间：2024-01-15 >= 且 < 2024-03-01 → 2 个分片
    var w2 = Where.init(a);
    defer w2.deinit();
    _ = try w2.ge("CreateTime", .{ .datetime = .{ .year = 2024, .month = 1, .day = 15 } });
    _ = try w2.lt("CreateTime", .{ .datetime = .{ .year = 2024, .month = 3, .day = 1 } });
    var out2: std.ArrayList(ShardModel) = .empty;
    defer {
        for (out2.items) |it| it.deinit(a);
        out2.deinit(a);
    }
    try p.shardsForWhere(&w2, &out2);
    try std.testing.expectEqual(@as(usize, 2), out2.items.len);
    try std.testing.expectEqualStrings("DH_Log_202401", out2.items[0].table_name);
    try std.testing.expectEqualStrings("DH_Log_202402", out2.items[1].table_name);

    // 条件不足：只有无关列
    var w3 = Where.init(a);
    defer w3.deinit();
    _ = try w3.eq("Code", .{ .text = "x" });
    var out3: std.ArrayList(ShardModel) = .empty;
    defer out3.deinit(a);
    try std.testing.expectError(error.InsufficientShardCondition, p.shardsForWhere(&w3, &out3));
}

test "未配置策略时不分片" {
    const a = std.testing.allocator;
    const p = TimePolicy{
        .gpa = a,
        .field = "CreateTime",
        .base_conn = "DH",
        .base_table = "DH_Log",
    };
    try std.testing.expect((try p.shardAt(0)) == null);
}
