//! 数据抽取器（对应 DH.NCode `Transform/`）。
//!
//! 三个抽取器都按「一次一批」迭代，用于大表搬迁 / 同步 / 导出——
//! 不用一次性把整表读进内存，也不会因 OFFSET 越翻越慢而卡死：
//!
//! | 抽取器 | 适用场景 | 每次查询 |
//! |---|---|---|
//! | `IdExtractor` | 有自增 / 雪花 Id（单调递增主键） | `WHERE id > 上批末尾 ORDER BY id LIMIT n` |
//! | `TimeExtractor` | 有时间索引字段 | 按时间窗切片 + 窗内分页，空窗自动加大步进 |
//! | `PagingExtractor` | 既无递增 Id 也无时间列（兜底） | `LIMIT n OFFSET m`，**越翻越慢** |
//!
//! 三者共用 `Setting`（起点 / 终点 / 批大小 / 时间偏移），并且都维护 `total`（累计抽取行数），
//! 建议每批在一个事务里写目标库，失败时从 `row` / `start` 断点续跑。
//!
//! 与 C# 的差异（有意，已在 docs/移植对照 记录）：
//! - C# `TimeExtracter` 在「空档超过最大步进（1 天）」时会**原地死循环**（StartTime 不前进、step 已封顶）。
//!   这里空窗时把起点推进到窗口末尾，保证单调前进并能终止。
//! - C# 用 `now` 直读系统时钟；这里允许 `now_override` 注入，便于用例固定时间。

const std = @import("std");
const DateTime = @import("zzig").DateTime;
const Value = @import("zzig").db.Value;
const dbtable = @import("dbtable.zig");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Row = session_mod.Row;
const Query = @import("query.zig").Query;
const Where = @import("query.zig").Where;
const model = @import("model.zig");
const Dal = @import("dal.zig").Dal;

/// 抽取参数（对应 C# `ExtractSetting`）。
pub const Setting = struct {
    /// 开始时间（含）；`null` = 由抽取器自己找第一行的值
    start: ?DateTime = null,
    /// 结束时间（不含）；`null` = 到「当前时间 - offset_seconds」为止
    end: ?DateTime = null,
    /// 时间偏移（秒）：不追实时数据时留一点安全边界（如 60 = 只抽 1 分钟以前的数据）
    offset_seconds: i64 = 0,
    /// 起始游标（分页抽取的偏移行数 / 自增抽取的起始 Id）
    row: i64 = 0,
    /// 时间窗初始步进（秒）；0 = 用默认 60 秒
    step_seconds: i64 = 0,
    /// 批大小（一次查询返回的最大行数）
    batch_size: usize = 5000,

    pub fn effectiveStep(self: Setting) i64 {
        if (self.step_seconds > 0) return self.step_seconds;
        return min_step_seconds;
    }
};

/// 时间窗最小步进（C# `minStep = 60s`）。
pub const min_step_seconds: i64 = 60;
/// 时间窗最大步进（C# `maxStep = 1 天`）。
pub const max_step_seconds: i64 = 24 * 60 * 60;

fn addSeconds(dt: DateTime, seconds: i64) DateTime {
    return DateTime.fromUnixSeconds(dt.toUnixSeconds() + seconds);
}

fn rowColumnI64(row: Row, column: []const u8) ?i64 {
    const v = row.get(column) orelse return null;
    return v.asI64();
}

fn rowColumnTime(row: Row, column: []const u8) ?DateTime {
    const v = row.get(column) orelse return null;
    return switch (v) {
        .datetime => |dt| dt,
        .text => |text| DateTime.parse(text) catch null,
        else => null,
    };
}

/// 自增 / 雪花 Id 抽取器（对应 C# `IdExtractor`）：主键步进，速度最快。
pub const IdExtractor = struct {
    table: dbtable.TableRef,
    column: []const u8,
    row: i64 = 0,
    batch_size: usize = 5000,
    total: usize = 0,
    done: bool = false,

    pub fn init(table: dbtable.TableRef, column: []const u8) IdExtractor {
        return .{ .table = table, .column = column };
    }

    /// 取下一批；`null` 表示抽完。
    ///
    /// **内存契约**：上一批的行会在下一次 `next()` 开头被回收（`Session.resetResults`），
    /// 所以「取一批 → 处理 → 再取」是内存有界的；**不要把多批行攒起来一起用**。
    pub fn next(self: *IdExtractor, s: *Session) !?[]Row {
        if (self.done) return null;
        // 亿级表遍历的关键：不回收的话，每页都累积在会话 arena 里，内存直线上升
        if (self.total > 0) s.resetResults();

        const gpa = self.table.gpa;
        var w = Where.init(gpa);
        defer w.deinit();
        _ = try w.gt(self.column, .{ .int = self.row });

        var q = Query.init(gpa);
        defer q.deinit();
        _ = q.filterWhere(&w);
        _ = try q.orderBy(self.column, false);
        _ = q.take(self.batch_size);

        const rows = try self.table.queryRows(s, &q);
        if (rows.len == 0) {
            self.done = true;
            return null;
        }

        const last = rowColumnI64(rows[rows.len - 1], self.column) orelse {
            std.debug.print(
                "[zcode] IdExtractor：列 {s} 读回的不是整数（表 {s}），无法按主键步进，请改用 TimeExtractor/PagingExtractor\n",
                .{ self.column, self.table.table_name },
            );
            self.done = true;
            return error.Model;
        };

        self.row = last;
        self.total += rows.len;
        if (rows.len < self.batch_size) self.done = true;
        return rows;
    }
};

/// 分页抽取器（对应 C# `PagingExtractor`）：通用兜底，页数越多越慢。
pub const PagingExtractor = struct {
    table: dbtable.TableRef,
    order_by: ?[]const u8 = null,
    row: usize = 0,
    batch_size: usize = 5000,
    total: usize = 0,
    done: bool = false,

    pub fn init(table: dbtable.TableRef, order_by: ?[]const u8) PagingExtractor {
        return .{ .table = table, .order_by = order_by };
    }

    /// 取下一批；`null` 表示抽完。内存契同 `IdExtractor.next`（上一批在下次调用时回收）。
    pub fn next(self: *PagingExtractor, s: *Session) !?[]Row {
        if (self.done) return null;
        if (self.total > 0) s.resetResults();

        const gpa = self.table.gpa;
        var q = Query.init(gpa);
        defer q.deinit();
        if (self.order_by) |col| _ = try q.orderBy(col, false);
        _ = q.skip(self.row).take(self.batch_size);

        const rows = try self.table.queryRows(s, &q);
        if (rows.len == 0) {
            self.done = true;
            return null;
        }

        self.row += rows.len;
        self.total += rows.len;
        if (rows.len < self.batch_size) self.done = true;
        return rows;
    }
};

/// 时间索引抽取器（对应 C# `TimeExtracter`）：按时间窗切片 + 窗内分页。
pub const TimeExtractor = struct {
    table: dbtable.TableRef,
    column: []const u8,
    setting: Setting = .{},
    batch_size: usize = 5000,
    total: usize = 0,
    done: bool = false,
    /// 下一次抽取的起点（含）；`null` = 尚未确定（首轮会查第一行的时间）
    start: ?DateTime = null,
    /// 用例注入「当前时间」；`null` = 读系统时钟
    now_override: ?DateTime = null,

    window_end: ?DateTime = null,
    step_seconds: i64 = min_step_seconds,

    pub fn init(table: dbtable.TableRef, column: []const u8, setting: Setting) TimeExtractor {
        const batch = if (setting.batch_size > 0) setting.batch_size else 5000;
        return .{
            .table = table,
            .column = column,
            .setting = setting,
            .batch_size = batch,
            .start = setting.start,
            .step_seconds = setting.effectiveStep(),
        };
    }

    fn now(self: *TimeExtractor) DateTime {
        return self.now_override orelse DateTime.nowLocal();
    }

    /// 终点（不含）：`setting.end` 优先，否则「当前时间 - 偏移」。
    fn limit(self: *TimeExtractor) DateTime {
        if (self.setting.end) |e| return e;
        return addSeconds(self.now(), -self.setting.offset_seconds);
    }

    /// 首次抽取：找第一行的时间（对应 C# `StartTime.Year < 1000` 时先查一条）。
    fn findFirst(self: *TimeExtractor, s: *Session) !?DateTime {
        const gpa = self.table.gpa;
        var q = Query.init(gpa);
        defer q.deinit();
        _ = try q.orderBy(self.column, false);
        _ = q.take(1);

        const rows = try self.table.queryRows(s, &q);
        if (rows.len == 0) return null;
        return rowColumnTime(rows[0], self.column);
    }

    /// 取下一批；`null` 表示抽完。内存契同 `IdExtractor.next`（上一批在下次调用时回收）。
    pub fn next(self: *TimeExtractor, s: *Session) !?[]Row {
        if (self.done) return null;
        if (self.total > 0) s.resetResults();

        if (self.start == null) {
            const first = try self.findFirst(s) orelse {
                self.done = true;
                return null;
            };
            self.start = first;
        }

        const gpa = self.table.gpa;
        while (true) {
            const start = self.start.?;
            const boundary = self.limit();

            // 逼近实时：起点 + 最小步进 已到终点 → 收工（C# `StartTime.Add(minStep) >= Now`）
            if (!addSeconds(start, min_step_seconds).before(boundary)) {
                self.done = true;
                return null;
            }

            // 开一个时间窗 [start, end)
            if (self.window_end == null) {
                var end = addSeconds(start, self.step_seconds);
                if (!end.before(boundary)) end = boundary; // 不越过终点
                if (!start.before(end)) {
                    self.done = true;
                    return null;
                }
                self.window_end = end;
            }
            const window_end = self.window_end.?;

            var w = Where.init(gpa);
            defer w.deinit();
            _ = try w.ge(self.column, .{ .datetime = start });
            _ = try w.lt(self.column, .{ .datetime = window_end });

            var q = Query.init(gpa);
            defer q.deinit();
            _ = q.filterWhere(&w);
            _ = try q.orderBy(self.column, false);
            _ = q.take(self.batch_size);

            const rows = try self.table.queryRows(s, &q);
            if (rows.len == 0) {
                // 空窗：起点推进到窗口末尾（C# 在此会原地死循环，见文件头说明），并加大步进
                self.start = window_end;
                self.window_end = null;
                if (self.step_seconds < max_step_seconds) {
                    self.step_seconds = @min(self.step_seconds * 2, max_step_seconds);
                }
                if (!addSeconds(window_end, min_step_seconds).before(boundary)) {
                    self.done = true;
                    return null;
                }
                continue;
            }

            const last_time = rowColumnTime(rows[rows.len - 1], self.column) orelse {
                std.debug.print(
                    "[zcode] TimeExtractor：列 {s} 读回的不是时间（表 {s}），无法按时间步进\n",
                    .{ self.column, self.table.table_name },
                );
                self.done = true;
                return error.Model;
            };

            // 下一批从「本批最后一行的下一行」开始：时间推进 1 秒（与 C# 一致）
            //
            // 注意：**不能**在旧窗口里用 offset 翻页——起点已经前进到「最后一行 +1s」，
            // 再叠 offset 会把窗口内剩下的行整段跳过（实测漏行）。C# 也是每读完一页就重开窗口。
            self.start = addSeconds(last_time, 1);
            self.window_end = null;
            self.total += rows.len;
            return rows;
        }
    }
};

// ───────────────────────── 单元测试 ─────────────────────────

test "Setting 默认步进与批大小" {
    const s = Setting{};
    try std.testing.expectEqual(@as(i64, min_step_seconds), s.effectiveStep());
    try std.testing.expectEqual(@as(usize, 5000), s.batch_size);
    try std.testing.expect(s.start == null);

    const s2 = Setting{ .step_seconds = 300, .batch_size = 100 };
    try std.testing.expectEqual(@as(i64, 300), s2.effectiveStep());
}

test "时间加减秒（跨天/跨月）" {
    const dt = try DateTime.parse("2023-02-28 23:30:00");
    const next = addSeconds(dt, 60);
    try std.testing.expectEqual(@as(u8, 28), next.day);
    try std.testing.expectEqual(@as(u8, 23), next.hour);
    try std.testing.expectEqual(@as(u8, 31), next.minute);

    // 2023 不是闰年：+1 天就是 3 月 1 日
    const march = addSeconds(dt, 24 * 60 * 60);
    try std.testing.expectEqual(@as(u8, 3), march.month);
    try std.testing.expectEqual(@as(u8, 1), march.day);
}

test "分页抽取：多页遍历内存有界（每页回收，不随页数增长）" {
    const a = std.testing.allocator;

    const xml =
        \\<EntityModel><Tables><Table Name="Big" TableName="Big_Row">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Name" DataType="String" Length="64" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    // 注意：`Dal` **接管模型所有权**（`Dal.deinit` 会 `model.deinit()`），调用方不能再释放
    const m = try model.EntityModel.parse(a, xml);

    var dal = Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m) catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer dal.deinit();
    var s = dal.openSession() catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const t = try dal.table("Big");

    // 造 400 行（每行 64 字节字符串），批大小 20 → 20 页
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        @memset(&name_buf, 'x');
        _ = try t.insert(&s, &.{
            .{ .name = "Name", .value = .{ .text = name_buf[0..] } },
        });
    }

    var ex = PagingExtractor.init(t, "Id");
    ex.batch_size = 20;

    var pages: usize = 0;
    var total_rows: usize = 0;
    var max_arena: usize = 0;
    while (try ex.next(&s)) |rows| {
        pages += 1;
        total_rows += rows.len;
        // 处理「当前页」：只看本页，不攒行
        for (rows) |r| {
            const name = r.get("Name").?.text;
            std.debug.assert(name.len == 64);
        }
        const now = arenaBytes(&s);
        if (now > max_arena) max_arena = now;
    }

    try std.testing.expectEqual(@as(usize, 400), total_rows);
    try std.testing.expectEqual(@as(usize, 20), pages);
    // 每页约 20 行 × (Row + 64B 字符串 + 列名借用) ≈ 3KB；20 页全攒下会 ≥ 60KB。
    // 有界的话峰值应停在「一两页」的量级——这里给 16KB 的宽松上界，防止回归成累积。
    try std.testing.expect(max_arena < 16 * 1024);
}

/// 会话结果 arena 当前占用（诊断/用例用；正式代码不要依赖具体数值）。
fn arenaBytes(s: *Session) usize {
    return s.resultBytes();
}
