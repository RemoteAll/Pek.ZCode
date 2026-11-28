//! `CronJob` 表适配器：把 Membership 库的作业行接到 `zzig.threading.jobs` 上。
//!
//! **分层口径**（避免「调度器塞进 ORM」）：
//! - 调度、任务注册表、执行线程、Cron 解析、结果回调 —— 全在 **zzig**（`zzig.threading.jobs` /
//!   `zzig.threading.timer`，对齐 DH.NCore `TimerX`）；
//! - 本文件**只做存储相关的事**：读 `CronJob` 行 → 转成 `JobSpec` 交给 zzig；执行后回写
//!   `LastTime` / `NextTime`；`EnableLog` 时写一条 `Log`。
//!
//! 表归属：`CronJob` 在 `src/membership/Member.xml`（Membership 连接）；`Log` 表级
//! `ConnName="Log"`，因此 `Dal` 必须已 `attachConnection("Log", …)`（与 `membership/log.zig` 一致）。
//!
//! ```zig
//! var cron = try CronScheduler.create(gpa, io, &dal, .{ .cron_offset_seconds = 8 * 3600 });
//! defer cron.deinit();
//! try cron.registerTask(.{ .name = "MyApp.Jobs.Ping", .run = ping, .ctx = state });
//! cron.start();          // 读表并装载
//! cron.scheduleNow(1);   // 立即执行（对齐 C# JobService.Wake(id, -1)）
//! ```

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("../root.zig");
const entities = @import("entities/mod.zig");

const jobs_mod = zzig.threading.jobs;
const Cron = zzig.threading.cron.Cron;

pub const Options = struct {
    /// Cron 时区偏移（秒）：`0` = UTC，东八区传 `8 * 3600`
    cron_offset_seconds: i64 = 0,
    /// 操作日志类别（`Log.Category`）；空串 = 不写日志
    log_category: []const u8 = "定时作业",
};

pub const TaskFn = jobs_mod.TaskFn;
pub const Task = jobs_mod.Task;

/// 一行作业在内存里的状态（回写 LastTime/NextTime 与写日志要用）。
const RowState = struct {
    gpa: std.mem.Allocator,
    id: i32,
    /// 与 `JobSpec.key` 相同（`CronJob.Name`，表上有唯一索引）
    name: []const u8,
    crons: []Cron,
    enable_log: bool,
    /// 表里 1 + 正在回写的回调各 1
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
};

pub const CronScheduler = struct {
    gpa: std.mem.Allocator,
    dal: *zcode.Dal,
    options: Options,
    /// 调度本身（Timer 线程、任务注册、执行、计数）都在 zzig
    reg: *jobs_mod.Registry,
    mutex: std.Io.Mutex = .init,
    rows: std.ArrayListUnmanaged(*RowState) = .empty,
    /// 上次装载的配置签名（`id|name|method|argument|cron|enableLog` 拼接）。
    ///
    /// 管理端每次保存都会 `reload`：签名不变就**不重建定时器**——既省掉一次全表重建，
    /// 也避免 zzig 的「退役作业」在频繁保存时增长（那里的内存要等 deinit 才回收）。
    last_signature: []const u8 = "",

    pub fn create(
        gpa: std.mem.Allocator,
        io_handle: std.Io,
        dal: *zcode.Dal,
        options: Options,
    ) !*CronScheduler {
        const reg = try jobs_mod.Registry.create(gpa, io_handle, "CronJob");
        errdefer reg.deinit();

        const self = try gpa.create(CronScheduler);
        self.* = .{ .gpa = gpa, .dal = dal, .options = options, .reg = reg };
        reg.setAfterRun(.{ .ctx = self, .call = onJobRan });
        return self;
    }

    pub fn deinit(self: *CronScheduler) void {
        // 先让 zzig 停调度线程（join），再释放行状态：回写回调不会再进来
        self.reg.deinit();
        self.clearRows();
        self.lock();
        self.rows.deinit(self.gpa);
        const signature = self.last_signature;
        self.last_signature = "";
        self.unlock();
        if (signature.len > 0) self.gpa.free(signature);
        self.gpa.destroy(self);
    }

    fn io(self: *CronScheduler) std.Io {
        return self.reg.io();
    }

    fn lock(self: *CronScheduler) void {
        self.mutex.lockUncancelable(self.io());
    }

    fn unlock(self: *CronScheduler) void {
        self.mutex.unlock(self.io());
    }

    /// 热更新 Cron 时区偏移（下一次 `reload` 生效）。
    pub fn setCronOffset(self: *CronScheduler, offset_seconds: i64) void {
        self.lock();
        self.options.cron_offset_seconds = offset_seconds;
        self.unlock();
    }

    pub fn cronOffset(self: *CronScheduler) i64 {
        self.lock();
        defer self.unlock();
        return self.options.cron_offset_seconds;
    }

    /// 当前装载的作业数。
    pub fn count(self: *CronScheduler) usize {
        return self.reg.count();
    }

    /// 已执行 / 已跳过（未注册方法、执行失败）次数。
    pub fn executed(self: *CronScheduler) u64 {
        return self.reg.executed.load(.monotonic);
    }

    pub fn skipped(self: *CronScheduler) u64 {
        return self.reg.skipped.load(.monotonic);
    }

    /// 注册内置任务（转发给 zzig 的注册表）。
    pub fn registerTask(self: *CronScheduler, task: Task) !void {
        return self.reg.registerTask(task);
    }

    /// 启动 = 读表并装载一次。之后由 zzig 按 Cron 触发，没有轮询。
    pub fn start(self: *CronScheduler) void {
        self.reload() catch |err| {
            zzig.Logger.warn(
                "[zcode.cron] 定时作业加载失败（{s}）：本次不调度作业，配置变更后可再 reload",
                .{@errorName(err)},
            );
        };
    }

    /// 按库里的启用作业重建（管理端 add/update/del/ModifyState 之后调用）。
    ///
    /// 读表的字符串只在本函数内有效：`zzig.threading.jobs.Registry.sync` 会自己复制。
    pub fn reload(self: *CronScheduler) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var session = try self.dal.openSessionForTable("CronJob");
        defer session.deinit();
        const table = try self.dal.table("CronJob");

        var where = zcode.Where.init(a);
        _ = try where.eq("Enable", .{ .boolean = true });
        var query = zcode.Query.init(a);
        _ = query.filterWhere(&where);
        _ = try query.orderBy("ID", false);
        const raws = try table.queryRows(&session, &query);

        const offset = self.cronOffset();

        // 配置签名：内容没变就不重建（管理端频繁保存也不会有额外开销）。
        // **时区偏移也要进签名**：它被写进每个 `Timer`，光刷 NextTime 不会让已装载的定时器改时间。
        var sig: std.Io.Writer.Allocating = .init(a);
        defer sig.deinit();
        try sig.writer.print("offset={d}\n", .{offset});
        for (raws) |raw| {
            const id = rowInt(raw, "ID");
            try sig.writer.print("{d}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{d}\n", .{
                id,
                rowText(raw, "Name"),
                rowText(raw, "Method"),
                rowText(raw, "Argument"),
                rowText(raw, "Cron"),
                @intFromBool(rowBool(raw, "EnableLog")),
            });
        }
        const signature = sig.written();
        self.lock();
        const unchanged = std.mem.eql(u8, self.last_signature, signature);
        self.unlock();
        if (unchanged) {
            // 定时器不用重建；只把 NextTime 按当前时区偏移刷一遍即可
            self.syncNextTimes(offset);
            return;
        }

        var states: std.ArrayListUnmanaged(*RowState) = .empty;
        errdefer {
            for (states.items) |state| releaseRow(state);
            states.deinit(self.gpa);
        }
        var specs: std.ArrayListUnmanaged(jobs_mod.JobSpec) = .empty;
        defer specs.deinit(a);

        for (raws) |raw| {
            const id: i32 = @intCast(if (raw.get("ID")) |v| v.asI64() orelse 0 else 0);
            const name = try copyRowText(a, raw, "Name");
            const method = try copyRowText(a, raw, "Method");
            const argument = try copyRowText(a, raw, "Argument");
            const cron_text = try copyRowText(a, raw, "Cron");
            const enable_log = if (raw.get("EnableLog")) |v| v.asBool() orelse false else false;

            if (try zzig.threading.cron.validateAlloc(a, cron_text)) |message| {
                zzig.Logger.warn("[zcode.cron] 定时作业「{s}」（ID={d}）不调度：{s}", .{ name, id, message });
                continue;
            }
            const crons = try a.alloc(Cron, 1);
            crons[0] = try Cron.parse(cron_text);

            const state = try self.gpa.create(RowState);
            state.* = .{
                .gpa = self.gpa,
                .id = id,
                .name = try self.gpa.dupe(u8, name),
                .crons = try self.gpa.dupe(Cron, crons),
                .enable_log = enable_log,
            };
            try states.append(self.gpa, state);
            try specs.append(a, .{
                .key = name,
                .method = method,
                .argument = argument,
                .crons = crons,
                .cron_offset_seconds = offset,
            });
        }

        // 先换行状态（回写要用新的），再让 zzig 换定时器
        // 注意：`states` 的所有权在 replaceRows 里转移给了 self.rows，这里**不要**再 deinit
        self.replaceRows(states);

        try self.reg.sync(specs.items);
        self.syncNextTimes(offset);
        self.storeSignature(signature);
        zzig.Logger.info(
            "[zcode.cron] 定时作业已装载：{d} 个启用（Cron 按本地时间，偏移 {d} 分钟）",
            .{ self.reg.count(), @divTrunc(offset, 60) },
        );
    }

    /// 记录本次配置签名（gpa 持有，覆盖旧值）。
    fn storeSignature(self: *CronScheduler, signature: []const u8) void {
        const copy = self.gpa.dupe(u8, signature) catch |err| {
            zzig.Logger.warn("[zcode.cron] 配置签名保存失败（{s}）：下次 reload 会重建定时器", .{@errorName(err)});
            return;
        };
        self.lock();
        const old = self.last_signature;
        self.last_signature = copy;
        self.unlock();
        if (old.len > 0) self.gpa.free(old);
    }

    fn replaceRows(self: *CronScheduler, fresh: std.ArrayListUnmanaged(*RowState)) void {
        self.lock();
        const old = self.rows;
        self.rows = fresh;
        self.unlock();

        for (old.items) |state| releaseRow(state);
        var copy = old;
        copy.deinit(self.gpa);
    }

    fn clearRows(self: *CronScheduler) void {
        self.replaceRows(.empty);
    }

    /// 找到 id 对应的行状态**并加一个引用**（调用方负责 `releaseRow`）。
    ///
    /// 为什么必须在锁内加引用：`reload` 换表时会 `releaseRow` 旧行，
    /// 先拿到裸指针再解锁去用，就是 use-after-free。
    fn acquireRowById(self: *CronScheduler, id: i32) ?*RowState {
        self.lock();
        defer self.unlock();
        for (self.rows.items) |state| {
            if (state.id == id) {
                _ = state.refs.fetchAdd(1, .monotonic);
                return state;
            }
        }
        return null;
    }

    fn acquireRowByName(self: *CronScheduler, name: []const u8) ?*RowState {
        self.lock();
        defer self.unlock();
        for (self.rows.items) |state| {
            if (std.mem.eql(u8, state.name, name)) {
                _ = state.refs.fetchAdd(1, .monotonic);
                return state;
            }
        }
        return null;
    }

    /// 立刻触发一次（对齐 C# `JobService.Wake(job.Id, -1)`）。
    /// 返回 true = 找到并已安排；false = 不存在或未启用（与 C# 一致，不报错）。
    pub fn scheduleNow(self: *CronScheduler, id: i32) bool {
        const state = self.acquireRowById(id) orelse return false;
        defer releaseRow(state);
        return self.reg.trigger(state.name);
    }

    /// 把内存里算出的「下次时间」写回库（管理端要展示 `NextTime`）。
    ///
    /// 先在锁内把行状态快照出来（各自 +1 引用），解锁后再做数据库 IO——
    /// 不要在持锁期间访问库，否则 reload/回写会互相等。
    fn syncNextTimes(self: *CronScheduler, offset: i64) void {
        var snapshot: std.ArrayListUnmanaged(*RowState) = .empty;
        defer {
            for (snapshot.items) |state| releaseRow(state);
            snapshot.deinit(self.gpa);
        }
        {
            self.lock();
            defer self.unlock();
            for (self.rows.items) |state| {
                _ = state.refs.fetchAdd(1, .monotonic);
                snapshot.append(self.gpa, state) catch |err| {
                    _ = state.refs.fetchSub(1, .acq_rel);
                    zzig.Logger.warn("[zcode.cron] NextTime 快照登记失败（{s}）：剩余行跳过", .{@errorName(err)});
                    break;
                };
            }
        }
        if (snapshot.items.len == 0) return;

        var session = self.dal.openSessionForTable("CronJob") catch |err| {
            zzig.Logger.warn("[zcode.cron] 下次时间回写失败（开会话 {s}）：管理端 NextTime 可能为空", .{@errorName(err)});
            return;
        };
        defer session.deinit();
        const table = self.dal.table("CronJob") catch |err| {
            zzig.Logger.warn("[zcode.cron] 下次时间回写失败（取表 {s}）", .{@errorName(err)});
            return;
        };

        const now_unix = zzig.DateTime.nowUnix();
        for (snapshot.items) |state| {
            const next_ms = nextUnixMs(state.crons, now_unix, offset);
            _ = table.updateOne(&session, &[_]zcode.sqlbuild.Field{
                .{ .name = "NextTime", .value = .{ .datetime = fromUnixMs(next_ms, offset) } },
            }, null, state.id) catch |err| {
                zzig.Logger.warn(
                    "[zcode.cron] 定时作业「{s}」（ID={d}）NextTime 回写失败：{s}",
                    .{ state.name, state.id, @errorName(err) },
                );
                continue;
            };
        }
    }

    /// 执行后回写 `LastTime` / `NextTime`（由 zzig 的 `after_run` 回调驱动）。
    fn saveTimes(self: *CronScheduler, state: *RowState, last_unix: i64, offset: i64) void {
        var session = self.dal.openSessionForTable("CronJob") catch |err| {
            zzig.Logger.warn(
                "[zcode.cron] 定时作业「{s}」（ID={d}）执行时间回写失败（开会话 {s}）：下次可能被重复触发",
                .{ state.name, state.id, @errorName(err) },
            );
            return;
        };
        defer session.deinit();
        const table = self.dal.table("CronJob") catch |err| {
            zzig.Logger.warn("[zcode.cron] 定时作业「{s}」（ID={d}）执行时间回写失败（取表 {s}）", .{ state.name, state.id, @errorName(err) });
            return;
        };
        const next_ms = nextUnixMs(state.crons, last_unix, offset);
        _ = table.updateOne(&session, &[_]zcode.sqlbuild.Field{
            .{ .name = "LastTime", .value = .{ .datetime = fromUnixMs(last_unix * 1000, offset) } },
            .{ .name = "NextTime", .value = .{ .datetime = fromUnixMs(next_ms, offset) } },
        }, null, state.id) catch |err| {
            zzig.Logger.warn(
                "[zcode.cron] 定时作业「{s}」（ID={d}）执行时间回写失败：{s}",
                .{ state.name, state.id, @errorName(err) },
            );
        };
    }

    fn writeJobLog(self: *CronScheduler, name: []const u8, ok: bool, remark: []const u8) void {
        self.lock();
        const category = self.options.log_category;
        self.unlock();
        if (category.len == 0) return;

        var session = self.dal.openSessionForTable("Log") catch |err| {
            zzig.Logger.warn("[zcode.cron] 定时作业「{s}」日志写入失败（开会话 {s}）", .{ name, @errorName(err) });
            return;
        };
        defer session.deinit();

        // 复用 `LogProvider`：它负责时间型主键（`Log.ID`）、LinkID 解析与默认用户/IP，
        // 不要在这里手拼实体（手拼会漏 ID，第二条就 UNIQUE 冲突）。
        const provider = zcode.membership.LogProvider{ .enable = true, .host = "" };
        var entry = provider.createLog(category, name, ok, remark, 0, "system", "") catch |err| {
            zzig.Logger.warn("[zcode.cron] 定时作业「{s}」日志构造失败：{s}", .{ name, @errorName(err) });
            return;
        };
        _ = zcode.entity.insert(self.dal, &entry, &session) catch |err| {
            zzig.Logger.warn("[zcode.cron] 定时作业「{s}」日志写入失败：{s}", .{ name, @errorName(err) });
            return;
        };
    }
};

/// zzig 的执行后回调：按 key（= `CronJob.Name`）找到行状态并回写。
fn onJobRan(ctx: ?*anyopaque, outcome: jobs_mod.Outcome) void {
    const owner: *CronScheduler = @ptrCast(@alignCast(ctx orelse return));
    const state = owner.acquireRowByName(outcome.key) orelse {
        // 刚被 reload 摘掉的作业：不再回写（行可能已删除），但要留痕
        zzig.Logger.warn(
            "[zcode.cron] 作业「{s}」执行完成但不在当前快照里（已删除/已停用）：跳过时间回写",
            .{outcome.key},
        );
        return;
    };
    defer releaseRow(state);

    const offset = owner.cronOffset();
    const now_unix = zzig.DateTime.nowUnix();

    if (state.enable_log) {
        var buf: [512]u8 = undefined;
        const remark = if (outcome.ok)
            std.fmt.bufPrint(&buf, "执行成功，耗时 {d} ms", .{outcome.elapsed_ms}) catch "执行成功"
        else
            std.fmt.bufPrint(
                &buf,
                "执行失败：{s}（作业 {s}，方法 {s}）",
                .{ outcome.err_name orelse "未知错误", state.name, outcome.method },
            ) catch "执行失败";
        owner.writeJobLog(state.name, outcome.ok, remark);
    }

    owner.saveTimes(state, now_unix, offset);
}

fn releaseRow(state: *RowState) void {
    if (state.refs.fetchSub(1, .acq_rel) != 1) return;
    const gpa = state.gpa;
    gpa.free(state.name);
    gpa.free(state.crons);
    gpa.destroy(state);
}

fn copyRowText(a: std.mem.Allocator, row: zcode.session.Row, name: []const u8) ![]const u8 {
    const text = if (row.get(name)) |value| value.asText() orelse "" else "";
    return try a.dupe(u8, text);
}

fn rowText(row: zcode.session.Row, name: []const u8) []const u8 {
    return if (row.get(name)) |value| value.asText() orelse "" else "";
}

fn rowInt(row: zcode.session.Row, name: []const u8) i64 {
    return if (row.get(name)) |value| value.asI64() orelse 0 else 0;
}

fn rowBool(row: zcode.session.Row, name: []const u8) bool {
    return if (row.get(name)) |value| value.asBool() orelse false else false;
}

/// 严格晚于 `after_unix` 的下一次触发（**毫秒** Unix 时间；按本地时间口径换算）。无命中返回 0。
pub fn nextUnixMs(crons: []const Cron, after_unix: i64, offset_seconds: i64) i64 {
    var best: ?i64 = null;
    for (crons) |*cron| {
        if (cron.nextAfter(after_unix + offset_seconds)) |hit| {
            const local = hit - offset_seconds;
            if (best == null or local < best.?) best = local;
        }
    }
    return (best orelse 0) * 1000;
}

/// Unix 毫秒 → 本地 `DateTime`（非正值给空日期，表示不再触发）。
pub fn fromUnixMs(unix_ms: i64, offset_seconds: i64) zcode.DateTime {
    if (unix_ms <= 0) return .{};
    return zcode.DateTime.fromUnixSecondsOffset(@divFloor(unix_ms, 1000), offset_seconds);
}

test "cron_scheduler：本地时间下一次触发" {
    const cron = try Cron.parse("0 0 0 * * *");
    const offset: i64 = 8 * 3600;
    const midnight_local = zcode.DateTime{ .year = 2026, .month = 11, .day = 28 };
    const midnight_unix = midnight_local.toUnixSeconds() - offset;
    try std.testing.expectEqual((midnight_unix + 86400) * 1000, nextUnixMs(&.{cron}, midnight_unix, offset));
}

test "cron_scheduler：fromUnixMs 空值与非空值" {
    try std.testing.expectEqual(@as(i32, 0), fromUnixMs(0, 0).year);
    const dt = fromUnixMs(1000, 8 * 3600);
    try std.testing.expectEqual(@as(i32, 1970), dt.year);
    try std.testing.expectEqual(@as(u8, 8), dt.hour);
}
