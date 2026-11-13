//! 数据包：表级**导出 / 导入 / 跨库同步**（对应 DH.NCode `DataAccessLayer/DbPackage.cs`）。
//!
//! C# 的 `DbPackage` 是「抽取器 → 双线程 Actor（写文件 / 写库）」的流式管道，支持 `.gz` / `zip` 多表归档。
//! Zig 侧保留**语义**、换掉**管道形态**：
//!
//! | C# | Zig | 说明 |
//! |---|---|---|
//! | `Backup(table, stream)` | `exportAlloc` / `backupToFile` | 按页抽取，边抽边拼文本，不一次性读全表 |
//! | `Restore(stream, table)` | `importAlloc` / `restoreFromFile` | 按批写回，`insert` 模式走多行批量插入 |
//! | `Sync(table, connName)` | `sync` | 源会话抽一页 → 目标会话写一页（可跨连接 / 跨方言） |
//! | `BackupAll` / `RestoreAll`（zip + xml 模型） | **未做** | 本仓与 `zzig` 都没有 zip 实现；多表请逐表调用（模型本来就在 `Model.xml`） |
//! | Actor 并行写 | **不做** | 单线程流水已能打满常见场景的磁盘/网络；并行要引入线程池与背压，收益不明显 |
//!
//! ## 文本格式（`#` 开头是元信息，正文一行一条记录）
//!
//! ```text
//! #zcode-package 1
//! #table User
//! #columns <TAB> Id <TAB> Name <TAB> CreateTime
//! #rows 2
//! 1 <TAB> abc <TAB> 2024-01-01 00:00:00
//! 2 <TAB> \N <TAB> 2024-01-02 00:00:00
//! ```
//!
//! - 转义：`\\` `\t` `\n` `\r`；`\N` 表示 NULL（与 MySQL `LOAD DATA` 文本口径一致，便于互转）；
//! - 二进制列写成 `0x<hex>`；
//! - 值是**文本**，导入时按模型列类型还原（Int32 / Decimal / DateTime / Boolean / Binary 等）；
//! - 列**按名字匹配**（不是按位置），导出列顺序与目标表列顺序不同也能导；
//! - 包里有而目标表没有的列被忽略；目标表有而包里缺的列不写（走默认值 / NULL）。

const std = @import("std");
const Value = @import("zzig").db.Value;
const DateTime = @import("zzig").DateTime;
const Decimal = @import("zzig").Decimal;
const Buf = @import("zzig").Buf;
const File = @import("zzig").File;
const dbtable = @import("dbtable.zig");
const TableRef = dbtable.TableRef;
const Session = @import("session.zig").Session;
const Row = @import("session.zig").Row;
const Query = @import("query.zig").Query;
const Where = @import("query.zig").Where;
const sqlbuild = @import("sqlbuild.zig");
const extract = @import("extract.zig");
const model = @import("model.zig");
const ColumnMeta = model.ColumnMeta;
const SaveModes = @import("setting.zig").SaveModes;
const setting = @import("setting.zig");

/// 导入 / 同步选项。
pub const Options = struct {
    /// 保存模式：`insert` 走多行批量插入；其余按行「先查后写」，慢但语义清楚
    mode: SaveModes = .insert,
    /// 每页行数；0 = 用全局 `Setting.page_size` / `batch_size`
    page_size: usize = 0,
    /// 单行失败是否继续（默认 true，与 C# `IgnoreError` 一致）
    ignore_error: bool = true,
};

/// 导入 / 同步结果。
pub const Result = struct {
    /// 成功写入（插入或更新）的行数
    rows: usize = 0,
    /// 处理过的页数
    pages: usize = 0,
    /// 失败行数（`ignore_error = false` 时在第一个失败处直接返回错误）
    errors: usize = 0,
    /// 被跳过的行数（`insert_ignore` 模式下主键已存在）
    skipped: usize = 0,

    pub fn describeAlloc(self: Result, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "写入 {d} 行 / {d} 页，失败 {d}，跳过 {d}", .{ self.rows, self.pages, self.errors, self.skipped });
    }
};

pub const package_header = "#zcode-package 1";

fn pageSizeOf(opts: Options) usize {
    if (opts.page_size > 0) return opts.page_size;
    return setting.current().effectivePageSize();
}

// ── 导出 ────────────────────────────────────────────────────────────────────

/// 把一张表的数据导出成包文本（调用方 free）。
///
/// 用分页抽取器一页一页取，每页用完 `resetResults()`，内存占用只与**单页行数**有关。
pub fn exportAlloc(gpa: std.mem.Allocator, s: *Session, table: TableRef, opts: Options) ![]u8 {
    const page_size = pageSizeOf(opts);

    var b = Buf.init(gpa);
    defer b.deinit();

    try b.add(package_header);
    try b.add("\n");
    try b.fmt("#table {s}\n", .{table.table_name});

    // 列清单
    try b.add("#columns");
    for (table.table.columns) |col| {
        try b.add("\t");
        try b.add(table.table.effectiveColumnName(&col));
    }
    try b.add("\n");

    // 总行数（取不到写 -1，不阻断导出）
    const total = table.count(s, null) catch -1;
    try b.fmt("#rows {d}\n", .{total});

    const order_by = try pickOrderColumn(gpa, table);
    defer if (order_by) |o| gpa.free(o);

    var extractor = extract.PagingExtractor.init(table, order_by);
    extractor.batch_size = page_size;

    while (true) {
        const page = try extractor.next(s);
        defer s.resetResults();
        const rows = page orelse break;
        if (rows.len == 0) break;

        for (rows) |row| {
            for (table.table.columns, 0..) |col, i| {
                if (i > 0) try b.add("\t");
                const name = table.table.effectiveColumnName(&col);
                try pushEscapedValue(gpa, &b, row.get(name) orelse .null);
            }
            try b.add("\n");
        }
    }

    return b.toOwnedSlice();
}

/// 导出到文件（覆盖写），返回行数。
pub fn backupToFile(gpa: std.mem.Allocator, s: *Session, table: TableRef, path: []const u8, opts: Options) !Result {
    const text = try exportAlloc(gpa, s, table, opts);
    defer gpa.free(text);

    try File.WriteAll(path, text);

    var result = Result{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        result.rows += 1;
    }
    result.pages = 1;
    return result;
}

// ── 导入 ────────────────────────────────────────────────────────────────────

/// 把包文本导入一张表。
pub fn importAlloc(gpa: std.mem.Allocator, s: *Session, table: TableRef, text: []const u8, opts: Options) !Result {
    const page_size = pageSizeOf(opts);
    var result = Result{};

    // 列名用 gpa（整轮有效）；行的文本值用 arena（每写一批整体回收）
    var columns: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (columns.items) |c| gpa.free(c);
        columns.deinit(gpa);
    }
    var saw_columns = false;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var pending: std.ArrayListUnmanaged([]sqlbuild.Field) = .empty;
    defer {
        for (pending.items) |fields| gpa.free(fields);
        pending.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;

        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, "#columns")) {
                var it = std.mem.splitScalar(u8, line["#columns".len..], '\t');
                while (it.next()) |name| {
                    if (name.len == 0) continue;
                    try columns.append(gpa, try gpa.dupe(u8, name));
                }
                saw_columns = columns.items.len > 0;
            }
            continue;
        }
        if (!saw_columns) return error.MissingColumns;

        const fields = try parseRow(gpa, arena.allocator(), table, columns.items, line);
        try pending.append(gpa, fields);

        if (pending.items.len >= page_size) {
            try flushPending(gpa, s, table, &pending, opts, &result);
            result.pages += 1;
            // 本批的值已写进库，整块回收（列名不在 arena 里，安全）
            _ = arena.reset(.retain_capacity);
        }
    }
    if (pending.items.len > 0) {
        try flushPending(gpa, s, table, &pending, opts, &result);
        result.pages += 1;
    }
    return result;
}

/// 从文件恢复。
pub fn restoreFromFile(gpa: std.mem.Allocator, s: *Session, table: TableRef, path: []const u8, opts: Options) !Result {
    const text = try File.ReadAllAlloc(gpa, path, 512 * 1024 * 1024);
    defer gpa.free(text);
    return importAlloc(gpa, s, table, text, opts);
}

// ── 跨库同步 ────────────────────────────────────────────────────────────────

/// 把源表数据同步到目标表（可跨连接 / 跨方言）：源抽一页 → 目标写一页，内存只留一页。
pub fn sync(
    gpa: std.mem.Allocator,
    src_s: *Session,
    src_table: TableRef,
    dst_s: *Session,
    dst_table: TableRef,
    opts: Options,
) !Result {
    const page_size = pageSizeOf(opts);
    var result = Result{};

    const order_by = try pickOrderColumn(gpa, src_table);
    defer if (order_by) |o| gpa.free(o);

    var extractor = extract.PagingExtractor.init(src_table, order_by);
    extractor.batch_size = page_size;

    var pending: std.ArrayListUnmanaged([]sqlbuild.Field) = .empty;
    defer {
        for (pending.items) |fields| gpa.free(fields);
        pending.deinit(gpa);
    }

    while (true) {
        const page = try extractor.next(src_s);
        const rows = page orelse break;
        if (rows.len == 0) {
            src_s.resetResults();
            break;
        }

        for (rows) |row| {
            // 只带目标表认识的列
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            defer names.deinit(gpa);
            for (dst_table.table.columns) |col| {
                const name = dst_table.table.effectiveColumnName(&col);
                if (row.get(name) != null) try names.append(gpa, name);
            }
            try pending.append(gpa, try fieldsFromRow(gpa, row, names.items));
        }

        try flushPending(gpa, dst_s, dst_table, &pending, opts, &result);
        result.pages += 1;
        src_s.resetResults();
    }
    if (pending.items.len > 0) {
        try flushPending(gpa, dst_s, dst_table, &pending, opts, &result);
        result.pages += 1;
    }
    return result;
}

// ── 内部实现 ────────────────────────────────────────────────────────────────

/// 分页排序用的列：优先主键，没有就第一列；无列则 `null`。
fn pickOrderColumn(gpa: std.mem.Allocator, table: TableRef) !?[]u8 {
    for (table.table.columns) |col| {
        if (col.primary_key) return try gpa.dupe(u8, table.table.effectiveColumnName(&col));
    }
    if (table.table.columns.len > 0) {
        return try gpa.dupe(u8, table.table.effectiveColumnName(&table.table.columns[0]));
    }
    return null;
}

fn pushEscapedValue(gpa: std.mem.Allocator, b: *Buf, value: Value) !void {
    switch (value) {
        .null => {
            try b.add("\\N");
            return;
        },
        .blob => |bytes| {
            // 二进制写成 0x<hex>（否则 \t / \n 会污染行分隔）
            try b.add("0x");
            for (bytes) |byte| try b.fmt("{X:0>2}", .{byte});
            return;
        },
        else => {},
    }

    const text = try value.toTextAlloc(gpa);
    defer gpa.free(text);
    for (text) |c| {
        switch (c) {
            '\\' => try b.add("\\\\"),
            '\t' => try b.add("\\t"),
            '\n' => try b.add("\\n"),
            '\r' => try b.add("\\r"),
            else => try b.addByte(c),
        }
    }
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// 把一行的文本按目标列类型还原成 `Value`。带所有权的值（text/blob）分配在 `a`（行 arena）。
fn valueFromText(a: std.mem.Allocator, col: *const ColumnMeta, raw: []const u8) !Value {
    if (std.mem.eql(u8, raw, "\\N")) return .null;

    switch (col.data_type) {
        .boolean => return .{ .boolean = std.ascii.eqlIgnoreCase(raw, "1") or std.ascii.eqlIgnoreCase(raw, "true") },
        .byte, .int16, .int32, .int64 => return .{ .int = try std.fmt.parseInt(i64, raw, 10) },
        .single, .double => return .{ .float = try std.fmt.parseFloat(f64, raw) },
        .decimal => return .{ .decimal = try Decimal.parse(raw) },
        .datetime => return .{ .datetime = try DateTime.parse(raw) },
        .binary => {
            if (std.mem.startsWith(u8, raw, "0x")) {
                const hex = raw[2..];
                if (hex.len % 2 != 0) return error.InvalidHex;
                const bytes = try a.alloc(u8, hex.len / 2);
                for (bytes, 0..) |*byte, i| {
                    const hi = hexNibble(hex[i * 2]) orelse return error.InvalidHex;
                    const lo = hexNibble(hex[i * 2 + 1]) orelse return error.InvalidHex;
                    byte.* = hi * 16 + lo;
                }
                return .{ .blob = bytes };
            }
            return .{ .blob = try a.dupe(u8, raw) };
        },
        else => return .{ .text = try a.dupe(u8, raw) },
    }
}

/// 解析一条数据行（按 `columns` 顺序切分）。`fields` 切片用 `gpa`，值用 `a`。
fn parseRow(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    table: TableRef,
    columns: []const []const u8,
    line: []const u8,
) ![]sqlbuild.Field {
    var fields: std.ArrayList(sqlbuild.Field) = .empty;
    errdefer fields.deinit(gpa);

    var it = std.mem.splitScalar(u8, line, '\t');
    var i: usize = 0;
    while (it.next()) |cell| : (i += 1) {
        if (i >= columns.len) break;
        const col = table.table.column(columns[i]) orelse continue;
        const value = valueFromText(a, col, cell) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return error.InvalidValue,
        };
        try fields.append(gpa, .{ .name = columns[i], .value = value });
    }
    return fields.toOwnedSlice(gpa);
}

fn fieldsFromRow(gpa: std.mem.Allocator, row: Row, names: []const []const u8) ![]sqlbuild.Field {
    var fields: std.ArrayList(sqlbuild.Field) = .empty;
    errdefer fields.deinit(gpa);
    for (names) |name| {
        const v = row.get(name) orelse continue;
        try fields.append(gpa, .{ .name = name, .value = v });
    }
    return fields.toOwnedSlice(gpa);
}

/// 把攒好的一批行写进目标表，并清空 `pending`。
fn flushPending(
    gpa: std.mem.Allocator,
    s: *Session,
    table: TableRef,
    pending: *std.ArrayListUnmanaged([]sqlbuild.Field),
    opts: Options,
    result: *Result,
) !void {
    if (pending.items.len == 0) return;
    defer {
        for (pending.items) |fields| gpa.free(fields);
        pending.clearRetainingCapacity();
    }

    switch (opts.mode) {
        .insert => {
            if (!opts.ignore_error) {
                result.rows += try table.insertBatch(s, pending.items);
                return;
            }
            // 允许部分失败：逐行插，失败只计数
            for (pending.items) |fields| {
                _ = table.insert(s, fields) catch |e| {
                    result.errors += 1;
                    std.debug.print("[dbpackage] 插入失败：{s}\n", .{@errorName(e)});
                    continue;
                };
                result.rows += 1;
            }
        },
        .insert_ignore, .upsert, .replace => {
            const pks = table.table.primaryKeys(gpa) catch &.{};
            defer gpa.free(pks);

            for (pending.items) |fields| {
                const existing = findByPkFromFields(s, table, pks, fields) catch |e| {
                    if (!opts.ignore_error) return e;
                    result.errors += 1;
                    continue;
                };

                if (existing) |row| {
                    if (opts.mode == .insert_ignore) {
                        result.skipped += 1;
                        continue;
                    }

                    var w = try pkWhereFromRow(gpa, table, pks, row);
                    defer w.deinit();

                    if (opts.mode == .upsert) {
                        _ = table.update(s, fields, &w) catch |e| {
                            if (!opts.ignore_error) return e;
                            result.errors += 1;
                            continue;
                        };
                        result.rows += 1;
                        continue;
                    }

                    // replace：先删后插
                    _ = table.delete(s, &w) catch |e| {
                        if (!opts.ignore_error) return e;
                        result.errors += 1;
                        continue;
                    };
                }

                _ = table.insert(s, fields) catch |e| {
                    if (!opts.ignore_error) return e;
                    result.errors += 1;
                    continue;
                };
                result.rows += 1;
            }
        },
    }
}

fn findByPkFromFields(
    s: *Session,
    table: TableRef,
    pks: []const *const ColumnMeta,
    fields: []const sqlbuild.Field,
) !?Row {
    if (pks.len == 0) return null;

    var values: [8]Value = undefined;
    if (pks.len > values.len) return error.TooManyPrimaryKeys;

    for (pks, 0..) |pk, i| {
        const name = table.table.effectiveColumnName(pk);
        values[i] = .null;
        for (fields) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, name)) {
                values[i] = f.value;
                break;
            }
        }
        if (values[i] == .null) return null;
    }
    return table.findByPk(s, values[0..pks.len]);
}

fn pkWhereFromRow(
    gpa: std.mem.Allocator,
    table: TableRef,
    pks: []const *const ColumnMeta,
    row: Row,
) !Where {
    var w = Where.init(gpa);
    errdefer w.deinit();
    for (pks) |pk| {
        const name = table.table.effectiveColumnName(pk);
        const v = row.get(name) orelse continue;
        _ = try w.eq(name, v);
    }
    return w;
}

// ── 多表归档（对应 C# `DbPackage.BackupAll` / `RestoreAll`）──────────────────
//
// C# 的 `BackupAll` 写一个 zip：里面一份 `Model.xml` + 每表一个数据文件。
// Zig 侧口径一致，但**归档实现下沉在 `zzig`**（`zzig.zip` 负责多条目 zip，
// `zzig.http.gzipCompressAlloc` 负责单流 gzip），本文件只负责「哪些表、怎么命名」。
//
// | 扩展名 | 形态 | 说明 |
// |---|---|---|
// | `.zip` | 多条目 | `<表名>.zcode` + 可选 `Model.xml`；**推荐**（可单独取出某张表） |
// | `.gz` | 单流 | 多个包文本顺序拼接后整体 gzip；解压后按 `#zcode-package 1` 切块 |
// | 其它 | 纯文本 | 多表时同样是拼接，便于人工查看 |

pub const ArchiveKind = enum { text, gz, zip };

/// 模型文件在归档里的固定名（与 C# `BackupAll` 一致）
pub const model_entry_name = "Model.xml";
/// 每张表的数据条目后缀
pub const entry_suffix = ".zcode";

pub fn archiveKindOfPath(path: []const u8) ArchiveKind {
    if (std.ascii.endsWithIgnoreCase(path, ".zip")) return .zip;
    if (std.ascii.endsWithIgnoreCase(path, ".gz") or std.ascii.endsWithIgnoreCase(path, ".gzip")) return .gz;
    return .text;
}

/// 多表导出成**一个文本**（`#zcode-package 1` 块顺序拼接，gz / 纯文本都用它）。
pub fn exportAllAlloc(gpa: std.mem.Allocator, s: *Session, tables: []const TableRef, opts: Options) ![]u8 {
    var b = Buf.init(gpa);
    defer b.deinit();
    for (tables) |t| {
        const text = try exportAlloc(gpa, s, t, opts);
        defer gpa.free(text);
        try b.add(text);
        // 块之间留一个空行，便于人工阅读；解析端按 `#zcode-package` 切块，不依赖空行
        if (text.len > 0 and text[text.len - 1] != '\n') try b.add("\n");
        try b.add("\n");
    }
    return b.toOwnedSlice();
}

/// 多表导出到归档文件（按扩展名决定 zip / gz / 纯文本），返回写入行数。
pub fn backupAllToFile(
    gpa: std.mem.Allocator,
    s: *Session,
    tables: []const TableRef,
    model_xml: ?[]const u8,
    path: []const u8,
    opts: Options,
) !Result {
    switch (archiveKindOfPath(path)) {
        .zip => {
            var w = @import("zzig").zip.Writer.init(gpa);
            defer w.deinit();
            if (model_xml) |xml| try w.addEntry(model_entry_name, xml, .deflate);

            var result = Result{};
            for (tables) |t| {
                const text = try exportAlloc(gpa, s, t, opts);
                defer gpa.free(text);
                const name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ t.table_name, entry_suffix });
                defer gpa.free(name);
                try w.addEntry(name, text, .deflate);
                result.rows += countDataRows(text);
            }
            const bytes = try w.finish();
            defer gpa.free(bytes);
            try File.WriteAll(path, bytes);
            result.pages = 1;
            return result;
        },
        .gz => {
            const text = try exportAllAlloc(gpa, s, tables, opts);
            defer gpa.free(text);
            const zipped = try @import("zzig").Http.gzipCompressAlloc(gpa, text, std.compress.flate.Compress.Options.default);
            defer gpa.free(zipped);
            try File.WriteAll(path, zipped);
            return .{ .rows = countDataRows(text), .pages = 1 };
        },
        .text => {
            const text = try exportAllAlloc(gpa, s, tables, opts);
            defer gpa.free(text);
            try File.WriteAll(path, text);
            return .{ .rows = countDataRows(text), .pages = 1 };
        },
    }
}

/// 从归档文件恢复多表（表名来自归档内条目名 / 块头 `#table`，通过 `dal.table` 解析）。
pub fn restoreAllFromFile(
    gpa: std.mem.Allocator,
    s: *Session,
    dal: *@import("dal.zig").Dal,
    path: []const u8,
    opts: Options,
) !Result {
    const bytes = try File.ReadAllAlloc(gpa, path, 1024 * 1024 * 1024);
    defer gpa.free(bytes);

    switch (archiveKindOfPath(path)) {
        .zip => {
            var r = try @import("zzig").zip.Reader.init(gpa, bytes);
            defer r.deinit();

            var result = Result{};
            for (r.entries, 0..) |e, i| {
                if (!std.ascii.endsWithIgnoreCase(e.name, entry_suffix)) continue; // 跳过 Model.xml 等
                const table_name = e.name[0 .. e.name.len - entry_suffix.len];
                const table = dal.table(table_name) catch |err| {
                    std.debug.print(
                        "[zcode] 数据包恢复：归档里的表 {s} 在模型中不存在（{s}），跳过该条目\n",
                        .{ table_name, @errorName(err) },
                    );
                    continue;
                };
                const text = r.extractAlloc(i) catch |err| {
                    std.debug.print("[zcode] 数据包恢复：条目 {s} 解压失败（{s}），跳过\n", .{ e.name, @errorName(err) });
                    continue;
                };
                defer gpa.free(text);
                const one = try importAlloc(gpa, s, table, text, opts);
                result.rows += one.rows;
                result.errors += one.errors;
                result.skipped += one.skipped;
                result.pages += one.pages;
            }
            return result;
        },
        .gz => {
            const text = try @import("zzig").Http.gzipDecompressAlloc(gpa, bytes);
            defer gpa.free(text);
            return importAllAlloc(gpa, s, dal, text, opts);
        },
        .text => return importAllAlloc(gpa, s, dal, bytes, opts),
    }
}

/// 把合并后的包文本按 `#zcode-package 1` 切成多块，逐块按 `#table <名>` 落到对应表。
pub fn importAllAlloc(
    gpa: std.mem.Allocator,
    s: *Session,
    dal: *@import("dal.zig").Dal,
    text: []const u8,
    opts: Options,
) !Result {
    var result = Result{};
    var rest = text;
    while (rest.len > 0) {
        // 找到本块起点（没有块头就说明格式不对，明确报错而不是静默导入 0 行）
        const start = std.mem.indexOf(u8, rest, package_header) orelse {
            if (std.mem.trim(u8, rest, " \t\r\n").len == 0) break;
            std.debug.print("[zcode] 数据包恢复：剩余内容没有 `{s}` 块头，无法解析\n", .{package_header});
            return error.MissingPackageHeader;
        };
        const block_start = start;
        // 下一块起点：从块头之后继续找
        const after = rest[block_start + package_header.len ..];
        const next_rel = std.mem.indexOf(u8, after, package_header);
        const block = if (next_rel) |nr| rest[block_start .. block_start + package_header.len + nr] else rest[block_start..];

        const table_name = tableNameOfBlock(block) orelse {
            std.debug.print("[zcode] 数据包恢复：块里缺少 `#table <名>`，无法确定目标表\n", .{});
            return error.MissingTableHeader;
        };
        const table = dal.table(table_name) catch |err| {
            std.debug.print(
                "[zcode] 数据包恢复：块头里的表 {s} 在模型中不存在（{s}）\n",
                .{ table_name, @errorName(err) },
            );
            return err;
        };
        const one = try importAlloc(gpa, s, table, block, opts);
        result.rows += one.rows;
        result.errors += one.errors;
        result.skipped += one.skipped;
        result.pages += one.pages;

        rest = if (next_rel) |nr| rest[block_start + package_header.len + nr ..] else "";
    }
    return result;
}

fn tableNameOfBlock(block: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "#table ")) continue;
        const name = std.mem.trim(u8, line["#table ".len..], " \t");
        if (name.len == 0) return null;
        return name;
    }
    return null;
}

fn countDataRows(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        n += 1;
    }
    return n;
}

// ============================ 测试 ============================

const testing = std.testing;
const Dal = @import("dal.zig").Dal;

const test_model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel>
    \\  <Tables>
    \\    <Table Name="User" TableName="User">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Name" DataType="String" Length="50" Nullable="True" />
    \\        <Column Name="Age" DataType="Int32" Nullable="True" />
    \\        <Column Name="JoinTime" DataType="DateTime" Nullable="True" />
    \\      </Columns>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

fn memDal(a: std.mem.Allocator) !Dal {
    const m = try model.EntityModel.parse(a, test_model_xml);
    return Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
}

fn insertOne(s: *Session, table: TableRef, name: ?[]const u8, age: ?i64) !void {
    var fields: [2]sqlbuild.Field = undefined;
    fields[0] = .{ .name = "Name", .value = if (name) |x| .{ .text = x } else .null };
    fields[1] = .{ .name = "Age", .value = if (age) |x| .{ .int = x } else .null };
    _ = try table.insert(s, &fields);
}

test "数据包：导出文本格式（转义 / NULL / 列清单）" {
    const a = testing.allocator;
    var dal = try memDal(a);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("User");
    try insertOne(&s, table, "a\tb", 20);
    try insertOne(&s, table, null, null);

    const text = try exportAlloc(a, &s, table, .{});
    defer a.free(text);

    try testing.expect(std.mem.startsWith(u8, text, "#zcode-package 1\n"));
    try testing.expect(std.mem.indexOf(u8, text, "#columns\tId\tName\tAge\tJoinTime") != null);
    try testing.expect(std.mem.indexOf(u8, text, "#rows 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "a\\tb") != null); // 制表符转义
    try testing.expect(std.mem.indexOf(u8, text, "\\N") != null); // NULL
}

test "数据包：导出后导入回同一张表（清空再导）" {
    const a = testing.allocator;
    var dal = try memDal(a);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("User");
    try insertOne(&s, table, "张三", 30);
    try insertOne(&s, table, "李四", null);

    const text = try exportAlloc(a, &s, table, .{});
    defer a.free(text);

    _ = try table.delete(&s, null);
    try testing.expectEqual(@as(i64, 0), try table.count(&s, null));

    const r = try importAlloc(a, &s, table, text, .{});
    try testing.expectEqual(@as(usize, 2), r.rows);
    try testing.expectEqual(@as(usize, 0), r.errors);
    try testing.expectEqual(@as(i64, 2), try table.count(&s, null));

    // 中文与 NULL 都还原正确
    var w = Where.init(a);
    defer w.deinit();
    _ = try w.eq("Name", .{ .text = "李四" });
    var q = Query.init(a);
    defer q.deinit();
    _ = q.filterWhere(&w);
    const rows = try table.queryRows(&s, &q);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expect(rows[0].get("Age").?.isNull());
}

test "数据包：跨库同步（3 行 / 每页 2 行 → 2 页）" {
    const a = testing.allocator;
    var src_dal = try memDal(a);
    defer src_dal.deinit();
    var src_s = try src_dal.openSession();
    defer src_s.deinit();
    _ = try src_dal.syncSchema(&src_s);
    const src_table = try src_dal.table("User");
    for ([_][]const u8{ "a", "b", "c" }) |n| try insertOne(&src_s, src_table, n, 1);

    var dst_dal = try memDal(a);
    defer dst_dal.deinit();
    var dst_s = try dst_dal.openSession();
    defer dst_s.deinit();
    _ = try dst_dal.syncSchema(&dst_s);
    const dst_table = try dst_dal.table("User");

    const r = try sync(a, &src_s, src_table, &dst_s, dst_table, .{ .page_size = 2 });
    try testing.expectEqual(@as(usize, 3), r.rows);
    try testing.expectEqual(@as(usize, 2), r.pages);
    try testing.expectEqual(@as(i64, 3), try dst_table.count(&dst_s, null));
}

test "数据包：insert_ignore 跳过已有主键，upsert 覆盖" {
    const a = testing.allocator;
    var dal = try memDal(a);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("User");
    try insertOne(&s, table, "old", 10); // Id = 1

    // Id=1 已存在（改成 new/11），Id=2 新增；用真实制表符拼包文本
    const text = try std.mem.concat(a, u8, &.{
        "#zcode-package 1\n#table User\n#columns\tId\tName\tAge\tJoinTime\n#rows 2\n",
        "1\tnew\t11\t\\N\n",
        "2\tfresh\t22\t\\N\n",
    });
    defer a.free(text);

    const r1 = try importAlloc(a, &s, table, text, .{ .mode = .insert_ignore });
    try testing.expectEqual(@as(usize, 1), r1.rows);
    try testing.expectEqual(@as(usize, 1), r1.skipped);
    try testing.expectEqual(@as(i64, 2), try table.count(&s, null));

    const r2 = try importAlloc(a, &s, table, text, .{ .mode = .upsert });
    try testing.expectEqual(@as(usize, 2), r2.rows);
    try testing.expectEqual(@as(i64, 2), try table.count(&s, null));

    const row1 = (try table.findByPk(&s, &.{.{ .int = 1 }})).?;
    try testing.expectEqualStrings("new", row1.get("Name").?.text);
    try testing.expectEqual(@as(i64, 11), row1.get("Age").?.int);
}

// ── 多表归档用例（zip / gz）──────────────────────────────────

const archive_model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel>
    \\  <Tables>
    \\    <Table Name="User" TableName="User">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Name" DataType="String" Length="50" Nullable="True" />
    \\        <Column Name="Age" DataType="Int32" Nullable="True" />
    \\        <Column Name="JoinTime" DataType="DateTime" Nullable="True" />
    \\      </Columns>
    \\    </Table>
    \\    <Table Name="Role" TableName="Role">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Name" DataType="String" Length="50" Nullable="True" />
    \\      </Columns>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

fn archiveDal(a: std.mem.Allocator) !Dal {
    const m = try model.EntityModel.parse(a, archive_model_xml);
    return Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
}

fn seedTwoTables(a: std.mem.Allocator, dal: *Dal, s: *Session) !struct { users: TableRef, roles: TableRef } {
    _ = try dal.syncSchema(s);
    const users = try dal.table("User");
    const roles = try dal.table("Role");

    try insertOne(s, users, "甲", 20);
    try insertOne(s, users, "乙", 30);
    _ = try roles.insert(s, &[_]sqlbuild.Field{
        .{ .name = "Name", .value = .{ .text = "管理员" } },
    });
    _ = a;
    return .{ .users = users, .roles = roles };
}

test "数据包：zip 多表归档（含 Model.xml）往返" {
    const a = testing.allocator;
    var dal = try archiveDal(a);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const refs = try seedTwoTables(a, &dal, &s);
    try testing.expectEqual(@as(i64, 2), try refs.users.count(&s, null));
    try testing.expectEqual(@as(i64, 1), try refs.roles.count(&s, null));

    // 固定路径（`.zig-cache/tmp` 一定存在）：便于用外部工具（python zipfile / 解压软件）复检产物
    const path = ".zig-cache/tmp/dbpackage-archive.zip";

    const out = try backupAllToFile(a, &s, &.{ refs.users, refs.roles }, archive_model_xml, path, .{});
    defer @import("zzig").File.DeleteQuiet(path);

    try testing.expectEqual(@as(usize, 3), out.rows);

    // 清空后从归档恢复
    _ = try s.execute("DELETE FROM \"User\"", &.{});
    _ = try s.execute("DELETE FROM \"Role\"", &.{});
    try testing.expectEqual(@as(i64, 0), try refs.users.count(&s, null));

    const restored = try restoreAllFromFile(a, &s, &dal, path, .{});
    try testing.expectEqual(@as(usize, 3), restored.rows);

    try testing.expectEqual(@as(i64, 2), try refs.users.count(&s, null));
    try testing.expectEqual(@as(i64, 1), try refs.roles.count(&s, null));
    const role = (try refs.roles.findByPk(&s, &.{.{ .int = 1 }})).?;
    try testing.expectEqualStrings("管理员", role.get("Name").?.text);
}

test "数据包：gz 单表流归档往返（多表按块头切分）" {
    const a = testing.allocator;
    var dal = try archiveDal(a);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const refs = try seedTwoTables(a, &dal, &s);

    const path = try @import("zzig").File.UniqueTempName(a, "dbpackage", ".gz");
    defer a.free(path);
    defer @import("zzig").File.DeleteQuiet(path);

    const out = try backupAllToFile(a, &s, &.{ refs.users, refs.roles }, null, path, .{});
    try testing.expectEqual(@as(usize, 3), out.rows);

    _ = try s.execute("DELETE FROM \"User\"", &.{});
    _ = try s.execute("DELETE FROM \"Role\"", &.{});

    const restored = try restoreAllFromFile(a, &s, &dal, path, .{});
    try testing.expectEqual(@as(usize, 3), restored.rows);
    try testing.expectEqual(@as(i64, 2), try refs.users.count(&s, null));
    try testing.expectEqual(@as(i64, 1), try refs.roles.count(&s, null));
}
