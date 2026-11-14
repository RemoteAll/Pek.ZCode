//! XCode 全局设置（对应 C# `Setting.cs` 的 `XCodeSetting`）。
//!
//! C# 侧是一个挂 `Config("XCode")` 的配置单例，字段决定 ORM 的全局行为：
//! 是否输出 SQL、SQL 超长阈值、批大小、批量间隙、命令超时、迁移档位、索引检查开关、
//! 以及各类缓存的默认过期时间。Zig 侧没有反射式配置框架，这里给三样东西：
//!
//! 1. **同一组字段与同口径默认值**（默认值逐项照抄 C#，改一处就是行为变更）；
//! 2. **文本档案读写**：`Key=Value` 行式（`#` / `;` 注释、键不区分大小写、不认识的键收集到 `unknown`，
//!    不静默丢弃），用于把设置落在项目配置文件里；
//! 3. **全局实例**：`current()` 取可变全局，`setCurrent()` 整体替换，`snapshot()`/`restore()` 供用例隔离。
//!
//! 有意不做：C# 的 `[Category]` / `[Description]` 元数据（面板展示用，Zig 侧不需要），
//! 以及 `NameFormat` 的实际改名能力（由调用方按需在生成 SQL 前处理）。

const std = @import("std");
const Buf = @import("zzig").Buf;
const Migration = @import("model.zig").Migration;

/// 表名 / 字段名大小写格式（对应 C# `NameFormats`）。
pub const NameFormats = enum {
    /// 由数据库决定（默认）
    default,
    /// 与模型保持一致
    none,
    /// 全大写
    upper,
    /// 全小写
    lower,
    /// 下划线分隔
    underline,

    pub fn parse(text: []const u8) ?NameFormats {
        const map = .{
            .{ "Default", NameFormats.default },
            .{ "None", NameFormats.none },
            .{ "Upper", NameFormats.upper },
            .{ "Lower", NameFormats.lower },
            .{ "Underline", NameFormats.underline },
        };
        inline for (map) |item| {
            if (std.ascii.eqlIgnoreCase(text, item[0])) return item[1];
        }
        return null;
    }

    pub fn name(self: NameFormats) []const u8 {
        return switch (self) {
            .default => "Default",
            .none => "None",
            .upper => "Upper",
            .lower => "Lower",
            .underline => "Underline",
        };
    }
};

/// 数据保存模式（对应 C# `DataAccessLayer/SaveModes.cs`）。
pub const SaveModes = enum {
    /// 标准插入
    insert,
    /// 插入或更新（执行插入，主键已存在时更新）
    upsert,
    /// 插入或忽略（执行插入，主键已存在时跳过）
    insert_ignore,
    /// 插入或替换（执行插入，主键已存在时替换）
    replace,

    pub fn parse(text: []const u8) ?SaveModes {
        const map = .{
            .{ "Insert", SaveModes.insert },
            .{ "Upsert", SaveModes.upsert },
            .{ "InsertIgnore", SaveModes.insert_ignore },
            .{ "Replace", SaveModes.replace },
        };
        inline for (map) |item| {
            if (std.ascii.eqlIgnoreCase(text, item[0])) return item[1];
        }
        return null;
    }

    pub fn name(self: SaveModes) []const u8 {
        return switch (self) {
            .insert => "Insert",
            .upsert => "Upsert",
            .insert_ignore => "InsertIgnore",
            .replace => "Replace",
        };
    }
};

/// XCode 全局设置。字段与默认值逐项对应 C# `XCodeSetting`。
pub const Setting = struct {
    // ---- 诊断 ----
    /// 是否启用调试（默认启用）
    debug: bool = true,
    /// 是否输出 SQL 语句（**默认关**，配置写 `ShowSQL=true` 才开）
    ///
    /// 与 C# `XCodeSetting.ShowSQL = true` 的差异说明：C# 侧 `DbSession.ShowSQL` 的真实默认值
    /// 取自 `XCode.Debug`（`#if DEBUG`，发布版为 false），所以**发布版默认不输出 SQL**。
    /// 本仓没有 DEBUG/RELEASE 之分，直接以「默认关、显式开」对齐发布版行为，
    /// 避免默认把每条 SQL 写进日志（既刷屏又浪费 IO）。
    show_sql: bool = false,
    /// SQL 输出单独目录（空 = 跟着当前日志走）
    sql_path: []const u8 = "",
    /// SQL 执行时间超过该阈值（毫秒）就写日志，默认 1000
    trace_sql_time: i32 = 1000,
    /// 输出日志时 SQL 的最大长度，超长截断；0 = 不截断，默认 4096
    sql_max_length: i32 = 4096,

    // ---- 执行 ----
    /// 参数化添删改查（默认关闭，与 C# 一致）
    use_parameter: bool = false,
    /// 批量操作批大小，默认 5000
    batch_size: i32 = 5_000,
    /// 批量删除时的停顿间隙（毫秒），默认 100
    batch_interval: i32 = 100,
    /// 查询执行超时（秒），0 = 不限制
    command_timeout: i32 = 0,
    /// 执行超时后的重试次数，0 = 不重试
    retry_on_failure: i32 = 0,

    // ---- 迁移 / 反向工程 ----
    /// 迁移档位：Off / ReadOnly / On（只新建）/ Full
    migration: Migration = .on,
    /// 检查表/字段注释
    check_comment: bool = true,
    /// 检查删除多余索引
    check_delete_index: bool = true,
    /// 检查添加缺失索引
    check_add_index: bool = true,
    /// 检查索引重复
    check_duplicate_index: bool = true,
    /// 表名 / 字段名大小写格式
    name_format: NameFormats = .default,
    /// 全表查行数下限：快速统计大于该值就用统计值，否则精确 count(*)
    full_count_floor: i32 = 10_000_000,

    // ---- 缓存 ----
    /// 数据层缓存（按 SQL 缓存）过期秒数，默认 0（不缓存）
    data_cache_expire: i32 = 0,
    /// 整表实体缓存过期秒数，默认 10
    entity_cache_expire: i32 = 10,
    /// 单对象缓存过期秒数，默认 10
    single_cache_expire: i32 = 10,
    /// 扩展属性缓存过期秒数，默认 10
    extend_expire: i32 = 10,
    /// 字段缓存过期秒数，默认 3600
    field_cache_expire: i32 = 3600,
    /// 数据包 / 抽取等大吞吐场景每页行数（0 = 用 `batch_size`）
    page_size: i32 = 0,

    // ---- 大表护栏 ----
    /// 单次查询返回行数的**告警**阈值：超过就打印一条带表名/行数的告警（0 = 不告警），默认 100_000。
    ///
    /// 背景：`queryRows` 是**全量**语义（结果全进会话 arena）。亿级表上一次误用就是 OOM，
    /// 而调用方往往“没意识到自己拿的是全量”。默认只在 10 万行时告警、不改变行为；
    /// 要真正拦住就把 `max_query_rows` 也配上。
    max_query_rows_warn: i32 = 100_000,
    /// 单次查询返回行数的**硬上限**：超限直接报 `error.TooManyRows`（0 = 不限），默认 0。
    max_query_rows: i32 = 0,

    /// 大表护栏：行数超过配的告警阈值就打印一条，超过硬上限直接报 `error.TooManyRows`。
    ///
    /// 用“告警 + 可选硬限”而不是一律报错：现有代码大量在用 `queryRows`，
    /// 直接报错会让存量调用方一启动就炸；默认只告警，要更严格就在配置里把 `MaxQueryRows` 配上。
    pub fn checkRowCount(self: Setting, table_name: []const u8, rows: usize) error{TooManyRows}!void {
        if (self.max_query_rows > 0 and rows > @as(usize, @intCast(self.max_query_rows))) {
            std.debug.print(
                "[zcode] 查询返回 {d} 行，超过配置的硬上限 MaxQueryRows={d}（表 {s}）：\n" ++
                    "        全量取数会直接把结果全进会话 arena，大表请用 extract.* 分页抽取，或给查询加 take()/分页\n",
                .{ rows, self.max_query_rows, table_name },
            );
            return error.TooManyRows;
        }
        if (self.max_query_rows_warn > 0 and rows >= @as(usize, @intCast(self.max_query_rows_warn))) {
            std.debug.print(
                "[zcode] 警告：一次查询返回 {d} 行（表 {s}），已达告警阈值 MaxQueryRowsWarn={d}；\n" ++
                    "        大表遍历请用 extract.IdExtractor / TimeExtractor（游标分页）而不是全量 queryRows\n",
                .{ rows, table_name, self.max_query_rows_warn },
            );
        }
    }
    pub fn effectiveBatchSize(self: Setting) usize {
        if (self.batch_size > 0) return @intCast(self.batch_size);
        return 5_000;
    }

    /// 数据包每页行数：优先 `page_size`，否则 `effectiveBatchSize()`。
    pub fn effectivePageSize(self: Setting) usize {
        if (self.page_size > 0) return @intCast(self.page_size);
        return self.effectiveBatchSize();
    }

    /// 解析 `Key=Value` 文本（`#` / `;` 开头为注释，键不区分大小写）。
    ///
    /// - 返回 `unknown`：本结构没有的键（调用方决定是告警还是忽略），不静默丢弃；
    /// - 值非法（如 `BatchSize=abc`）不抛错，也不改该字段，把该行记进 `unknown` 让调用方看到。
    pub fn parse(self: *Setting, gpa: std.mem.Allocator, text: []const u8) !ParseReport {
        var report = ParseReport{ .unknown = .empty };
        errdefer {
            for (report.unknown.items) |item| gpa.free(item.key);
            report.unknown.deinit(gpa);
        }

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '#' or line[0] == ';') continue;

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                try report.unknown.append(gpa, .{ .key = try gpa.dupe(u8, line), .reason = "缺少 =" });
                continue;
            };
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

            if (self.apply(key, value)) {
                report.applied += 1;
            } else {
                try report.unknown.append(gpa, .{ .key = try gpa.dupe(u8, key), .reason = "未知键或值非法" });
            }
        }
        return report;
    }

    /// 应用一个键值；返回该键是否被识别且值合法。
    pub fn apply(self: *Setting, key: []const u8, value: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(key, "Debug")) return setBool(&self.debug, value);
        if (std.ascii.eqlIgnoreCase(key, "ShowSQL")) return setBool(&self.show_sql, value);
        if (std.ascii.eqlIgnoreCase(key, "SQLPath")) {
            self.sql_path = value;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(key, "TraceSQLTime")) return setI32(&self.trace_sql_time, value);
        if (std.ascii.eqlIgnoreCase(key, "SQLMaxLength")) return setI32(&self.sql_max_length, value);
        if (std.ascii.eqlIgnoreCase(key, "UseParameter")) return setBool(&self.use_parameter, value);
        if (std.ascii.eqlIgnoreCase(key, "BatchSize")) return setI32(&self.batch_size, value);
        if (std.ascii.eqlIgnoreCase(key, "BatchInterval")) return setI32(&self.batch_interval, value);
        if (std.ascii.eqlIgnoreCase(key, "CommandTimeout")) return setI32(&self.command_timeout, value);
        if (std.ascii.eqlIgnoreCase(key, "RetryOnFailure")) return setI32(&self.retry_on_failure, value);
        if (std.ascii.eqlIgnoreCase(key, "Migration")) {
            const m = Migration.parse(value) orelse return false;
            self.migration = m;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(key, "CheckComment")) return setBool(&self.check_comment, value);
        if (std.ascii.eqlIgnoreCase(key, "CheckDeleteIndex")) return setBool(&self.check_delete_index, value);
        if (std.ascii.eqlIgnoreCase(key, "CheckAddIndex")) return setBool(&self.check_add_index, value);
        if (std.ascii.eqlIgnoreCase(key, "CheckDuplicateIndex")) return setBool(&self.check_duplicate_index, value);
        if (std.ascii.eqlIgnoreCase(key, "NameFormat")) {
            const f = NameFormats.parse(value) orelse return false;
            self.name_format = f;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(key, "FullCountFloor")) return setI32(&self.full_count_floor, value);
        if (std.ascii.eqlIgnoreCase(key, "DataCacheExpire")) return setI32(&self.data_cache_expire, value);
        if (std.ascii.eqlIgnoreCase(key, "EntityCacheExpire")) return setI32(&self.entity_cache_expire, value);
        if (std.ascii.eqlIgnoreCase(key, "SingleCacheExpire")) return setI32(&self.single_cache_expire, value);
        if (std.ascii.eqlIgnoreCase(key, "ExtendExpire")) return setI32(&self.extend_expire, value);
        if (std.ascii.eqlIgnoreCase(key, "FieldCacheExpire")) return setI32(&self.field_cache_expire, value);
        if (std.ascii.eqlIgnoreCase(key, "PageSize")) return setI32(&self.page_size, value);
        if (std.ascii.eqlIgnoreCase(key, "MaxQueryRowsWarn")) return setI32(&self.max_query_rows_warn, value);
        if (std.ascii.eqlIgnoreCase(key, "MaxQueryRows")) return setI32(&self.max_query_rows, value);
        return false;
    }

    /// 写出 `Key=Value` 文本（顺序与 C# 面板一致，便于 diff）。
    pub fn writeAlloc(self: Setting, gpa: std.mem.Allocator) ![]u8 {
        var b = Buf.init(gpa);
        defer b.deinit();

        try b.fmt("Debug={}\n", .{self.debug});
        try b.fmt("ShowSQL={}\n", .{self.show_sql});
        try b.fmt("SQLPath={s}\n", .{self.sql_path});
        try b.fmt("TraceSQLTime={d}\n", .{self.trace_sql_time});
        try b.fmt("SQLMaxLength={d}\n", .{self.sql_max_length});
        try b.fmt("UseParameter={}\n", .{self.use_parameter});
        try b.fmt("BatchSize={d}\n", .{self.batch_size});
        try b.fmt("BatchInterval={d}\n", .{self.batch_interval});
        try b.fmt("CommandTimeout={d}\n", .{self.command_timeout});
        try b.fmt("RetryOnFailure={d}\n", .{self.retry_on_failure});
        try b.fmt("Migration={s}\n", .{self.migration.name()});
        try b.fmt("CheckComment={}\n", .{self.check_comment});
        try b.fmt("CheckDeleteIndex={}\n", .{self.check_delete_index});
        try b.fmt("CheckAddIndex={}\n", .{self.check_add_index});
        try b.fmt("CheckDuplicateIndex={}\n", .{self.check_duplicate_index});
        try b.fmt("NameFormat={s}\n", .{self.name_format.name()});
        try b.fmt("FullCountFloor={d}\n", .{self.full_count_floor});
        try b.fmt("DataCacheExpire={d}\n", .{self.data_cache_expire});
        try b.fmt("EntityCacheExpire={d}\n", .{self.entity_cache_expire});
        try b.fmt("SingleCacheExpire={d}\n", .{self.single_cache_expire});
        try b.fmt("ExtendExpire={d}\n", .{self.extend_expire});
        try b.fmt("FieldCacheExpire={d}\n", .{self.field_cache_expire});
        try b.fmt("PageSize={d}\n", .{self.page_size});
        try b.fmt("MaxQueryRowsWarn={d}\n", .{self.max_query_rows_warn});
        try b.fmt("MaxQueryRows={d}\n", .{self.max_query_rows});
        return b.toOwnedSlice();
    }
};

fn setBool(target: *bool, value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) {
        target.* = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) {
        target.* = false;
        return true;
    }
    return false;
}

fn setI32(target: *i32, value: []const u8) bool {
    const parsed = std.fmt.parseInt(i32, value, 10) catch return false;
    target.* = parsed;
    return true;
}

/// `parse` 的结果：应用了多少行、哪些行没被识别。
pub const ParseReport = struct {
    applied: usize = 0,
    unknown: std.ArrayListUnmanaged(Unknown) = .empty,

    pub const Unknown = struct {
        key: []u8,
        reason: []const u8,
    };

    pub fn deinit(self: *ParseReport, gpa: std.mem.Allocator) void {
        for (self.unknown.items) |item| gpa.free(item.key);
        self.unknown.deinit(gpa);
    }
};

/// 全局设置实例（C# `XCodeSetting.Current` 的等价物）。
var global_setting: Setting = .{};

/// 取全局设置（可变）。
pub fn current() *Setting {
    return &global_setting;
}

/// 整体替换全局设置。
pub fn setCurrent(value: Setting) void {
    global_setting = value;
}

/// 取快照（用例隔离：`const old = snapshot(); defer restore(old);`）。
pub fn snapshot() Setting {
    return global_setting;
}

/// 恢复快照。
pub fn restore(value: Setting) void {
    global_setting = value;
}

/// 恢复成 C# 的出厂默认值。
pub fn resetToDefaults() void {
    global_setting = .{};
}

// ============================ 测试 ============================

const testing = std.testing;

test "大表护栏：默认只告警不报错；配了 MaxQueryRows 超限报 TooManyRows" {
    // 默认：告警阈值 10 万、硬上限 0（不限）→ 大规模结果也不报错
    const def = Setting{};
    try testing.expectEqual(@as(i32, 100_000), def.max_query_rows_warn);
    try testing.expectEqual(@as(i32, 0), def.max_query_rows);
    try def.checkRowCount("Big", 200_000);

    // 配了硬上限：超一行就报错（用例不关心告警阈值）
    var s = Setting{ .max_query_rows = 5, .max_query_rows_warn = 0 };
    try s.checkRowCount("Big", 5);
    try testing.expectError(error.TooManyRows, s.checkRowCount("Big", 6));

    // 配置解析与回写
    var parsed = Setting{};
    try testing.expect(parsed.apply("MaxQueryRows", "1000"));
    try testing.expect(parsed.apply("MaxQueryRowsWarn", "100"));
    try testing.expectEqual(@as(i32, 1000), parsed.max_query_rows);
    try testing.expectEqual(@as(i32, 100), parsed.max_query_rows_warn);

    const a = testing.allocator;
    const text = try parsed.writeAlloc(a);
    defer a.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "MaxQueryRows=1000") != null);
    try testing.expect(std.mem.indexOf(u8, text, "MaxQueryRowsWarn=100") != null);
}

test "默认值（SQL 输出默认为关，对齐 C# 发布版行为）" {
    const s = Setting{};
    try testing.expect(s.debug);
    try testing.expect(!s.show_sql);
    try testing.expect(s.trace_sql_time == 1000);
    try testing.expect(s.sql_max_length == 4096);
    try testing.expect(!s.use_parameter);
    try testing.expect(s.batch_size == 5000);
    try testing.expect(s.batch_interval == 100);
    try testing.expect(s.migration == .on);
    try testing.expect(s.name_format == .default);
    try testing.expect(s.full_count_floor == 10_000_000);
    try testing.expect(s.data_cache_expire == 0);
    try testing.expect(s.entity_cache_expire == 10);
    try testing.expect(s.single_cache_expire == 10);
    try testing.expect(s.field_cache_expire == 3600);
}

test "解析 Key=Value：注释 / 大小写 / 未知键 / 非法值" {
    const text =
        \\# 注释行
        \\; 另一种注释
        \\Debug=false
        \\showsql = false
        \\BatchSize = 2000
        \\Migration=Full
        \\NameFormat=Underline
        \\NoSuchKey=1
        \\CommandTimeout=abc
    ;
    var s = Setting{};
    var report = try s.parse(testing.allocator, text);
    defer report.deinit(testing.allocator);

    try testing.expect(!s.debug);
    try testing.expect(!s.show_sql);
    try testing.expect(s.batch_size == 2000);
    try testing.expect(s.migration == .full);
    try testing.expect(s.name_format == .underline);
    try testing.expect(s.command_timeout == 0); // 非法值不改字段
    try testing.expectEqual(@as(usize, 5), report.applied);
    try testing.expectEqual(@as(usize, 2), report.unknown.items.len);
    try testing.expectEqualStrings("NoSuchKey", report.unknown.items[0].key);
    try testing.expectEqualStrings("CommandTimeout", report.unknown.items[1].key);
}

test "写回再解析：往返一致" {
    var s = Setting{};
    s.batch_size = 1234;
    s.migration = .read_only;
    s.name_format = .lower;
    s.show_sql = false;

    const text = try s.writeAlloc(testing.allocator);
    defer testing.allocator.free(text);

    var back = Setting{};
    var report = try back.parse(testing.allocator, text);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), report.unknown.items.len);
    try testing.expectEqual(s.batch_size, back.batch_size);
    try testing.expectEqual(s.migration, back.migration);
    try testing.expectEqual(s.name_format, back.name_format);
    try testing.expectEqual(s.show_sql, back.show_sql);
}

test "批大小 / 页大小回落" {
    var s = Setting{};
    try testing.expectEqual(@as(usize, 5000), s.effectiveBatchSize());
    s.batch_size = 500;
    try testing.expectEqual(@as(usize, 500), s.effectiveBatchSize());
    try testing.expectEqual(@as(usize, 500), s.effectivePageSize());
    s.page_size = 128;
    try testing.expectEqual(@as(usize, 128), s.effectivePageSize());
}

test "全局实例：快照与恢复" {
    const old = snapshot();
    defer restore(old);

    resetToDefaults();
    try testing.expect(!current().show_sql);

    var s = Setting{};
    s.show_sql = false;
    setCurrent(s);
    try testing.expect(!current().show_sql);
}

test "SaveModes 解析与写名" {
    try testing.expectEqual(SaveModes.insert, SaveModes.parse("Insert").?);
    try testing.expectEqual(SaveModes.insert_ignore, SaveModes.parse("insertignore").?);
    try testing.expectEqual(SaveModes.replace, SaveModes.parse("REPLACE").?);
    try testing.expect(SaveModes.parse("bogus") == null);
    try testing.expectEqualStrings("Upsert", SaveModes.upsert.name());
}
