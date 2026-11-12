//! 统计模型与累加（对应 DH.NCode `Statistics/`）。
//!
//! XCode 的统计套路：业务表按「层级 + 时间」切片各存一行（如某个设备某小时的收发计数），
//! 写入时**不是覆盖**而是**累加**（`Total = Total + 1`），读的时候按层级拼装。
//!
//! 本模块给出三件事：
//! 1. `Levels` / `StatModel`：层级与时间截断（`2024-03-15 10:37:22` 的 `day` 层级 = `2024-03-15 00:00:00`）
//!    —— 与 C# `StatModel.GetDate` 逐分支对齐；
//! 2. `Mode` / `Field`：累加方式（求和 / 计数 / 最大值 / 最小值）；
//! 3. `Repository`：绑定一张统计表，`getOrAdd` 找行（没有就插）+ `accumulate` 原子累加。
//!
//! 与 C# 的差异（有意）：
//! - C# 的 `Avg` 靠业务层「先读再算」，本模块不提供 `avg` 累加（会给出 `error.Unsupported` 而不是算个错的）；
//!   需要均值请自己维护 `Sum` + `Count` 两个累加字段，读时相除。
//! - C# `GetDate` 对 `Quarter` 不做截断（落回原值），这里保持一致；季度字段名用 `Quarter`。

const std = @import("std");
const Buf = @import("zzig").Buf;
const DateTime = @import("zzig").DateTime;
const Value = @import("zzig").db.Value;
const sqlbuild = @import("sqlbuild.zig");
const dbtable = @import("dbtable.zig");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Row = session_mod.Row;
const Query = @import("query.zig").Query;
const Where = @import("query.zig").Where;

/// 统计层级（数值与 C# `StatLevels` 一致，可直读其落库值）。
pub const Levels = enum(u8) {
    all = 0,
    year = 1,
    month = 2,
    day = 3,
    hour = 4,
    minute = 5,
    quarter = 11,

    pub fn fromInt(v: i64) ?Levels {
        return switch (v) {
            0 => .all,
            1 => .year,
            2 => .month,
            3 => .day,
            4 => .hour,
            5 => .minute,
            11 => .quarter,
            else => null,
        };
    }

    /// 中文名（面板/日志用，与 C# `[Description]` 一致）。
    pub fn description(self: Levels) []const u8 {
        return switch (self) {
            .all => "全局",
            .year => "年",
            .month => "月",
            .day => "日",
            .hour => "小时",
            .minute => "分钟",
            .quarter => "季度",
        };
    }
};

/// 统计模型：层级 + 时间（对应 C# `StatModel`）。
pub const StatModel = struct {
    time: DateTime = .{},
    level: Levels = .day,

    pub fn init(time: DateTime, level: Levels) StatModel {
        return .{ .time = time, .level = level };
    }

    /// 按层级截断时间后构造（= C# `StatModel.Fill` / `Split` 落库的那个值）。
    ///
    /// 统计表的主键就是「层级 + 区间起点」，所以**写库前必须截断**，否则同一小时的两次写入
    /// 会因分钟/秒不同而变成两行。
    pub fn at(time: DateTime, level: Levels) StatModel {
        const model = StatModel{ .time = time, .level = level };
        return model.withLevel(level);
    }

    /// 该层级的区间起点（对齐 C# `StatModel.GetDate`）。
    ///
    /// `all` → `0001-01-01 00:00:00`；`quarter` → 原值（C# 未处理季度，保持一致）。
    pub fn getDate(self: StatModel, level: Levels) DateTime {
        const dt = self.time;
        return switch (level) {
            .all => DateTime{ .year = 1, .month = 1, .day = 1 },
            .year => .{ .year = dt.year, .month = 1, .day = 1 },
            .month => .{ .year = dt.year, .month = dt.month, .day = 1 },
            .day => .{ .year = dt.year, .month = dt.month, .day = dt.day },
            .hour => .{ .year = dt.year, .month = dt.month, .day = dt.day, .hour = dt.hour },
            .minute => .{
                .year = dt.year,
                .month = dt.month,
                .day = dt.day,
                .hour = dt.hour,
                .minute = dt.minute,
            },
            .quarter => dt,
        };
    }

    /// 按层级格式化时间（对齐 C# `StatModel.ToString`）。
    pub fn formatAlloc(self: StatModel, gpa: std.mem.Allocator) ![]u8 {
        var b = Buf.init(gpa);
        defer b.deinit();
        const dt = self.time;
        switch (self.level) {
            .all => try b.add("全局"),
            .year => try b.addZeroPadded(dt.year, 4),
            .month => {
                try b.addZeroPadded(dt.year, 4);
                try b.addByte('-');
                try b.addZeroPadded(dt.month, 2);
            },
            .day => {
                try b.addZeroPadded(dt.year, 4);
                try b.addByte('-');
                try b.addZeroPadded(dt.month, 2);
                try b.addByte('-');
                try b.addZeroPadded(dt.day, 2);
            },
            .hour => {
                try b.addZeroPadded(dt.year, 4);
                try b.addByte('-');
                try b.addZeroPadded(dt.month, 2);
                try b.addByte('-');
                try b.addZeroPadded(dt.day, 2);
                try b.addByte(' ');
                try b.addZeroPadded(dt.hour, 2);
            },
            .minute => {
                try b.addZeroPadded(dt.year, 4);
                try b.addByte('-');
                try b.addZeroPadded(dt.month, 2);
                try b.addByte('-');
                try b.addZeroPadded(dt.day, 2);
                try b.addByte(' ');
                try b.addZeroPadded(dt.hour, 2);
                try b.addByte(':');
                try b.addZeroPadded(dt.minute, 2);
            },
            .quarter => try b.add("Quarter"),
        }
        return b.toOwnedSlice();
    }

    /// 克隆并重设层级（时间按新层级截断）。
    pub fn withLevel(self: StatModel, level: Levels) StatModel {
        return .{ .time = self.getDate(level), .level = level };
    }

    /// 一次拆成多个层级（对齐 C# `Split`）。
    pub fn splitAlloc(self: StatModel, gpa: std.mem.Allocator, levels: []const Levels) ![]StatModel {
        const list = try gpa.alloc(StatModel, levels.len);
        for (levels, 0..) |level, i| list[i] = self.withLevel(level);
        return list;
    }

    /// 相等比较：层级与时间都相同（对齐 C# `Equals`）。
    pub fn eql(self: StatModel, other: StatModel) bool {
        return self.level == other.level and self.time.eql(other.time);
    }
};

/// 累加方式（对应 C# `StatModes`）。
pub const Mode = enum {
    max,
    min,
    avg,
    sum,
    count,

    /// 映射到 SQL 累加模式；`avg` 无法用单条 SQL 原子累加 → 明确报错。
    pub fn toAccumulate(self: Mode) error{Unsupported}!sqlbuild.Accumulate {
        return switch (self) {
            .max => .max,
            .min => .min,
            .sum, .count => .add,
            .avg => error.Unsupported,
        };
    }
};

/// 统计字段：列名 + 累加方式（对应 C# `StatField`；C# 的值来自实体赋值，这里由 `Entry` 携带）。
pub const Field = struct {
    column: []const u8,
    mode: Mode,
};

/// 一次累加的一条数据：列 + 增量 + 方式。
pub const Entry = struct {
    column: []const u8,
    /// `sum` / `max` / `min` 用这里的值；`count` 固定 +1（忽略此值）
    value: Value = .{ .int = 1 },
    mode: Mode = .sum,
};

/// 绑定一张统计表的仓储（对应 C# `StatHelper` 的用法）。
///
/// 统计表约定（与 XCode 生成的统计实体一致）：
/// - `Level`  `Int32`   —— 层级（存 `Levels` 的整数值）
/// - `Time`   `DateTime` —— 该层级的区间起点
/// - 另需 `CreateTime` / `UpdateTime`（可关掉，见字段默认值）
pub const Repository = struct {
    table: dbtable.TableRef,
    level_column: []const u8 = "Level",
    time_column: []const u8 = "Time",
    create_time_column: ?[]const u8 = "CreateTime",
    update_time_column: ?[]const u8 = "UpdateTime",

    pub fn init(table: dbtable.TableRef) Repository {
        return .{ .table = table };
    }

    fn buildKeyWhere(self: Repository, model: StatModel) !Where {
        var w = Where.init(self.table.gpa);
        errdefer w.deinit();
        _ = try w.eq(self.level_column, .{ .int = @intFromEnum(model.level) });
        _ = try w.eq(self.time_column, .{ .datetime = model.time });
        return w;
    }

    /// 按「层级 + 时间」找一行。
    pub fn find(self: Repository, s: *Session, model: StatModel) !?Row {
        var w = try self.buildKeyWhere(model);
        defer w.deinit();

        var q = Query.init(self.table.gpa);
        defer q.deinit();
        _ = q.filterWhere(&w).take(1);

        const rows = try self.table.queryRows(s, &q);
        return if (rows.len > 0) rows[0] else null;
    }

    /// 找行，没有就插入（对应 C# `StatHelper.GetOrAdd`）。
    ///
    /// `insert_fields` 是插入时的初始列（除 `Level` / `Time` / `CreateTime` 之外的值）；
    /// 插入失败会再查一次——并发下别人先插入的情况按「已存在」处理，不把错误抛给调用方。
    pub fn getOrAdd(
        self: Repository,
        s: *Session,
        model: StatModel,
        insert_fields: []const sqlbuild.Field,
    ) !?Row {
        if (try self.find(s, model)) |row| return row;

        var fields: std.ArrayList(sqlbuild.Field) = .empty;
        defer fields.deinit(self.table.gpa);
        try fields.append(self.table.gpa, .{ .name = self.level_column, .value = .{ .int = @intFromEnum(model.level) } });
        try fields.append(self.table.gpa, .{ .name = self.time_column, .value = .{ .datetime = model.time } });
        if (self.create_time_column) |col| {
            try fields.append(self.table.gpa, .{ .name = col, .value = .{ .datetime = DateTime.nowLocal() } });
        }
        try fields.appendSlice(self.table.gpa, insert_fields);

        _ = self.table.insert(s, fields.items) catch |e| {
            // 唯一键冲突（并发插入）：再查一次，查到就当作已存在
            if (try self.find(s, model)) |row| return row;
            const dt_text = try model.time.formatAlloc(self.table.gpa);
            defer self.table.gpa.free(dt_text);
            std.debug.print(
                "[zcode] 统计行插入失败（表 {s}，层级 {s}，时间 {s}）：{s}\n",
                .{ self.table.table_name, model.level.description(), dt_text, @errorName(e) },
            );
            return e;
        };

        return self.find(s, model);
    }

    /// 原子累加（对应 C# 累加字段 `Additional` 的更新语义）。
    ///
    /// - `sum` / `count` → `col = col + ?`（`count` 固定 +1）
    /// - `max` / `min`   → `col = CASE WHEN col IS NULL OR col < ? THEN ? ELSE col END`
    /// - `avg`           → `error.Unsupported`（请自行维护 Sum + Count）
    ///
    /// 同时刷新 `UpdateTime`（与 C# `StatHelper` 设置 `UpdateTime` 后再 `Update` 等效）。
    pub fn accumulate(self: Repository, s: *Session, model: StatModel, entries: []const Entry) !usize {
        if (entries.len == 0) return 0;

        const gpa = self.table.gpa;
        var list: std.ArrayList(sqlbuild.AccumulateField) = .empty;
        defer list.deinit(gpa);

        for (entries) |entry| {
            const mode = entry.mode.toAccumulate() catch |e| {
                std.debug.print(
                    "[zcode] 统计字段 {s} 使用 avg 累加：单条 SQL 无法原子算均值，请改用 Sum + Count 两个字段\n",
                    .{entry.column},
                );
                return e;
            };
            const value: Value = if (entry.mode == .count) .{ .int = 1 } else entry.value;
            try list.append(gpa, .{ .name = entry.column, .value = value, .mode = mode });
        }
        if (self.update_time_column) |col| {
            try list.append(gpa, .{ .name = col, .value = .{ .datetime = DateTime.nowLocal() }, .mode = .add });
        }

        var w = try self.buildKeyWhere(model);
        defer w.deinit();
        return self.table.accumulate(s, list.items, &w);
    }

    /// 「没有就按 `insert_fields` 建一行，然后累加」——统计写入的常用入口。
    pub fn addValues(
        self: Repository,
        s: *Session,
        model: StatModel,
        insert_fields: []const sqlbuild.Field,
        entries: []const Entry,
    ) !usize {
        _ = try self.getOrAdd(s, model, insert_fields) orelse return error.Model;
        return self.accumulate(s, model, entries);
    }
};

// ───────────────────────── 单元测试 ─────────────────────────

test "层级时间截断（对齐 C# StatModel.GetDate）" {
    const dt = try DateTime.parse("2024-03-15 10:37:22");
    const model = StatModel.init(dt, .day);

    const year = model.getDate(.year);
    try std.testing.expectEqual(@as(i32, 2024), year.year);
    try std.testing.expectEqual(@as(u8, 1), year.month);
    try std.testing.expectEqual(@as(u8, 1), year.day);

    const month = model.getDate(.month);
    try std.testing.expectEqual(@as(u8, 3), month.month);
    try std.testing.expectEqual(@as(u8, 1), month.day);

    const day = model.getDate(.day);
    try std.testing.expectEqual(@as(u8, 15), day.day);
    try std.testing.expectEqual(@as(u8, 0), day.hour);

    const hour = model.getDate(.hour);
    try std.testing.expectEqual(@as(u8, 10), hour.hour);
    try std.testing.expectEqual(@as(u8, 0), hour.minute);

    const minute = model.getDate(.minute);
    try std.testing.expectEqual(@as(u8, 37), minute.minute);
    // C# `new DateTime(y,M,d,H,m,0)`：秒归零
    try std.testing.expectEqual(@as(u8, 0), minute.second);

    const all = model.getDate(.all);
    try std.testing.expectEqual(@as(i32, 1), all.year);

    // 季度：C# 不截断，这里保持一致
    const quarter = model.getDate(.quarter);
    try std.testing.expect(quarter.eql(dt));
}

test "层级格式化与拆分" {
    const a = std.testing.allocator;
    const dt = try DateTime.parse("2024-03-15 10:37:22");

    const cases = [_]struct { level: Levels, want: []const u8 }{
        .{ .level = .all, .want = "全局" },
        .{ .level = .year, .want = "2024" },
        .{ .level = .month, .want = "2024-03" },
        .{ .level = .day, .want = "2024-03-15" },
        .{ .level = .hour, .want = "2024-03-15 10" },
        .{ .level = .minute, .want = "2024-03-15 10:37" },
        .{ .level = .quarter, .want = "Quarter" },
    };
    for (cases) |c| {
        const text = try StatModel.init(dt, c.level).formatAlloc(a);
        defer a.free(text);
        try std.testing.expectEqualStrings(c.want, text);
    }

    const split = try StatModel.init(dt, .day).splitAlloc(a, &[_]Levels{ .year, .month, .day });
    defer a.free(split);
    try std.testing.expectEqual(@as(usize, 3), split.len);
    try std.testing.expectEqual(Levels.year, split[0].level);
    try std.testing.expectEqual(@as(u8, 1), split[0].time.month);
}

test "层级整数映射与 C# 落库值一致" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Levels.all));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Levels.minute));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(Levels.quarter));
    try std.testing.expectEqual(Levels.quarter, Levels.fromInt(11).?);
    try std.testing.expect(Levels.fromInt(6) == null);
}

test "avg 累加明确报错" {
    try std.testing.expectError(error.Unsupported, Mode.avg.toAccumulate());
    try std.testing.expectEqual(sqlbuild.Accumulate.max, try Mode.max.toAccumulate());
    try std.testing.expectEqual(sqlbuild.Accumulate.add, try Mode.count.toAccumulate());
}
