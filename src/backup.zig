//! 数据库备份（对应 DH.NCode `DAL_Backup` / Rust `Pek.RCode/src/backup.rs`）。
//!
//! 两种形态，用途不同：
//!
//! 1. **原生快照**（`vacuumInto`，仅 SQLite）：`VACUUM INTO '<文件>'` 产出**完整可用**的库文件，
//!    可直接 `Data Source=<文件>` 打开；速度快、体积小、事务一致。
//! 2. **SQL 脚本**（`dumpSqlAlloc` / `dumpToFile`，SQLite + MySQL）：按模型生成
//!    「建表 DDL + INSERT」，可跨库/跨版本搬运、可人工审阅、可进版本库。
//!    文本可读但要逐行执行，只适合中小数据量（大表请用原生快照或数据库自带工具）。
//!
//! ## 语义细节（容易踩的地方）
//!
//! - **只导出模型里声明的表**（跳过视图与外部表）：备份是「给这个 ORM 用」的，
//!   把库里的杂物一起导出会带来无关依赖。
//! - **DDL 用方言生成器产出**（与 `syncSchema` 建表同源），所以「备份 → 恢复」后结构一致。
//! - **值一律转字面量**：数值/布尔原样；字符串单引号包裹并把 `'` 写成 `''`；二进制用 `X'..'`；
//!   时间用 `'YYYY-MM-DD HH:MM:SS'`；`NULL` 直接写 `NULL`。
//! - **不导出自增列的显式值**需要保留（否则恢复后 ID 会变），所以自增列也照常写值。
//! - **不自动 `DROP TABLE`**：默认在文件头写注释说明，恢复脚本里 `drop_existing` 为 true 时才输出
//!   `DROP TABLE IF EXISTS`（SQLite/MySQL 均支持）——默认 true，便于「覆盖恢复」。
//!
//! ## 明确不支持（显式报错，不静默降级）
//!
//! - MySQL 的原生快照（`mysqldump` 是外部工具）；需要请用 SQL 脚本形态。
//! - 增量备份 / binlog 位点：属于运维层，不在 ORM 范围。

const std = @import("std");
const model = @import("model.zig");
const TableMeta = model.TableMeta;
const dialect = @import("dialect.zig");
const DatabaseKind = dialect.DatabaseKind;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Value = @import("zzig").db.Value;

pub const Options = struct {
    /// 是否导出数据（false = 只导结构）
    include_data: bool = true,
    /// 只导出这些表（空 = 模型里全部表）；按实体名或物理表名匹配，忽略大小写
    only: []const []const u8 = &.{},
    /// 是否输出 `DROP TABLE IF EXISTS`（覆盖恢复）
    drop_existing: bool = true,
};

pub const Report = struct {
    /// 导出的表数
    tables: usize = 0,
    /// 导出的数据行数
    rows: usize = 0,
    /// 写出的字节数（SQL 脚本形态）
    bytes: usize = 0,
    /// SQLite 原生快照产出的文件大小
    snapshot_bytes: u64 = 0,

    pub fn describeAlloc(self: Report, gpa: std.mem.Allocator) ![]u8 {
        if (self.snapshot_bytes > 0) {
            return std.fmt.allocPrint(gpa, "原生快照：{d} 字节", .{self.snapshot_bytes});
        }
        return std.fmt.allocPrint(gpa, "SQL 脚本：{d} 表 / {d} 行 / {d} 字节", .{ self.tables, self.rows, self.bytes });
    }
};

/// SQLite 原生快照：`VACUUM INTO`，产出的文件可直接当库打开。
///
/// 仅 SQLite 支持（MySQL 请用 `dumpToFile`）；`kind` 不是 SQLite 时返回 `error.Unsupported`。
pub fn vacuumInto(s: *Session, kind: DatabaseKind, path: []const u8) !u64 {
    if (kind != .sqlite) {
        std.debug.print("[zcode] 备份：原生快照只支持 SQLite（当前 {s}），请改用 SQL 脚本形态\n", .{@tagName(kind)});
        return error.Unsupported;
    }

    // 目标文件必须不存在（SQLite 要求），已存在时先删掉，避免「备份到旧文件」的假成功
    @import("zzig").File.DeleteQuiet(path);

    const sql = blk: {
        const quoted_path = try sqlQuoteAlloc(s.gpa, path);
        defer s.gpa.free(quoted_path);
        break :blk try std.fmt.allocPrint(s.gpa, "VACUUM INTO '{s}'", .{quoted_path});
    };
    defer s.gpa.free(sql);
    _ = try s.execute(sql, &.{});

    // 校验：文件真的存在且非空，否则报错（不返回「成功但 0 字节」）
    const content = @import("zzig").File.ReadAllAlloc(s.gpa, path, 1 << 30) catch |e| {
        std.debug.print("[zcode] 备份：快照文件未生成或不可读（{s}）：{s}\n", .{ path, @errorName(e) });
        return e;
    };
    const size = content.len;
    s.gpa.free(content);
    if (size == 0) {
        std.debug.print("[zcode] 备份：快照文件为 0 字节（{s}）\n", .{path});
        return error.BackupEmpty;
    }
    return size;
}

/// 生成 SQL 脚本（结构 + 数据），返回由调用方释放的文本。
pub fn dumpSqlAlloc(gpa: std.mem.Allocator, s: *Session, m: *const model.EntityModel, kind: DatabaseKind, opts: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var report = Report{};

    const w = struct {
        fn line(list: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
            try list.appendSlice(a, text);
            try list.append(a, '\n');
        }
    };

    try w.line(&out, gpa, "-- Pek.ZCode 备份脚本");
    try w.line(&out, gpa, "-- 由 zcode.backup 生成：建表 DDL 来自方言生成器，结构与 sync_schema 一致");

    for (m.tables) |*t| {
        if (t.is_view) continue;
        if (!isSelected(t, opts.only)) continue;

        if (opts.drop_existing) {
            const quoted_table = try kind.quoteAlloc(gpa, t.effectiveTableName());
            defer gpa.free(quoted_table);
            const drop = try std.fmt.allocPrint(gpa, "DROP TABLE IF EXISTS {s};", .{quoted_table});
            defer gpa.free(drop);
            try w.line(&out, gpa, drop);
        }

        // 结构：与 syncSchema 同源
        const stmts = try kind.createTableAlloc(gpa, t);
        defer {
            for (stmts) |stmt| gpa.free(stmt);
            gpa.free(stmts);
        }
        for (stmts) |stmt| {
            try out.appendSlice(gpa, stmt);
            try out.append(gpa, ';');
            try out.append(gpa, '\n');
        }
        report.tables += 1;

        if (!opts.include_data) continue;

        // 数据
        const quoted_select_table = try kind.quoteAlloc(gpa, t.effectiveTableName());
        defer gpa.free(quoted_select_table);
        const sql = try std.fmt.allocPrint(gpa, "SELECT * FROM {s}", .{quoted_select_table});
        defer gpa.free(sql);
        const rows = try s.queryRows(sql, &.{});
        for (rows) |row| {
            try appendInsert(&out, gpa, t, kind, row.names, row.values);
            report.rows += 1;
        }
    }

    report.bytes = out.items.len;
    return out.toOwnedSlice(gpa);
}

/// 生成 SQL 脚本并写文件（返回报告，含字节数）。
pub fn dumpToFile(gpa: std.mem.Allocator, s: *Session, m: *const model.EntityModel, kind: DatabaseKind, path: []const u8, opts: Options) !Report {
    const text = try dumpSqlAlloc(gpa, s, m, kind, opts);
    defer gpa.free(text);

    try @import("zzig").File.WriteAll(path, text);

    // 统计口径以实际写出的字节为准（避免「以为写了」）
    var report = Report{ .bytes = text.len };
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "INSERT INTO")) report.rows += 1;
        if (std.mem.startsWith(u8, line, "CREATE TABLE")) report.tables += 1;
    }
    return report;
}

fn isSelected(t: *const TableMeta, only: []const []const u8) bool {
    if (only.len == 0) return true;
    for (only) |name| {
        if (std.ascii.eqlIgnoreCase(name, t.name) or std.ascii.eqlIgnoreCase(name, t.effectiveTableName())) return true;
    }
    return false;
}

fn appendInsert(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    t: *const TableMeta,
    kind: DatabaseKind,
    names: []const []const u8,
    values: []const Value,
) !void {
    const table_name = try kind.quoteAlloc(gpa, t.effectiveTableName());
    defer gpa.free(table_name);

    try out.appendSlice(gpa, "INSERT INTO ");
    try out.appendSlice(gpa, table_name);
    try out.appendSlice(gpa, " (");

    for (names, 0..) |name, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        const q = try kind.quoteAlloc(gpa, name);
        defer gpa.free(q);
        try out.appendSlice(gpa, q);
    }
    try out.appendSlice(gpa, ") VALUES (");

    for (values, 0..) |v, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try appendLiteral(out, gpa, v);
    }
    try out.appendSlice(gpa, ");\n");
}

fn appendLiteral(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: Value) !void {
    switch (v) {
        .null => try out.appendSlice(gpa, "NULL"),
        .boolean => |b| try out.appendSlice(gpa, if (b) "1" else "0"),
        .int => |n| {
            var num_buf: [32]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch return error.Model);
        },
        .float => |f| {
            var num_buf: [64]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&num_buf, "{d}", .{f}) catch return error.Model);
        },
        .decimal => |d| {
            const text = try d.formatAlloc(gpa);
            defer gpa.free(text);
            try out.appendSlice(gpa, text);
        },
        .datetime => |dt| {
            const text = try dt.formatAlloc(gpa);
            defer gpa.free(text);
            try out.appendSlice(gpa, "'");
            try out.appendSlice(gpa, text);
            try out.appendSlice(gpa, "'");
        },
        .text => |text| {
            try out.appendSlice(gpa, "'");
            const quoted = try sqlQuoteAlloc(gpa, text);
            defer gpa.free(quoted);
            try out.appendSlice(gpa, quoted);
            try out.appendSlice(gpa, "'");
        },
        .blob => |bytes| {
            // 二进制用 X'..'（SQLite / MySQL 都认）
            try out.appendSlice(gpa, "X'");
            for (bytes) |b| {
                const hex = "0123456789ABCDEF";
                try out.append(gpa, hex[b >> 4]);
                try out.append(gpa, hex[b & 0x0F]);
            }
            try out.appendSlice(gpa, "'");
        },
    }
}

/// 把字符串里的 `'` 双写（SQL 字面量安全），返回新分配文本。
pub fn sqlQuoteAlloc(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (text) |c| {
        if (c == '\'') try out.append(gpa, '\'');
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

// ───────────────────────────── 测试 ─────────────────────────────

test "SQL 字面量转义：单引号双写" {
    const a = std.testing.allocator;
    const q = try sqlQuoteAlloc(a, "O'Brien");
    defer a.free(q);
    try std.testing.expectEqualStrings("O''Brien", q);
}

test "SQLite：原生快照可重新打开且数据完整" {
    const a = std.testing.allocator;
    const sqlite = @import("zzig").sqlite;

    var dal = blk: {
        const xml =
            \\<EntityModel><Tables><Table Name="Bk" TableName="Bk_Item">
            \\  <Columns>
            \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
            \\    <Column Name="Name" DataType="String" Length="50" />
            \\  </Columns>
            \\</Table></Tables></EntityModel>
        ;
        const m = try model.EntityModel.parse(a, xml);
        break :blk try @import("dal.zig").Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
    };
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const t = try dal.table("Bk");
    _ = try t.insert(&s, &.{.{ .name = "Name", .value = .{ .text = "a'b" } }});

    const path = try @import("zzig").File.UniqueTempName(a, "bkvac", ".db");
    defer a.free(path);
    defer @import("zzig").File.DeleteQuiet(path);

    const size = try vacuumInto(&s, .sqlite, path);
    try std.testing.expect(size > 0);

    // 快照能被独立打开并读到数据
    var lib = try sqlite.Lib.load(a);
    defer lib.deinit();
    const db2 = try sqlite.Db.open(&lib, path);
    var s2 = session_mod.Session.init(a, .sqlite, db2);
    defer s2.deinit();
    const rows = try s2.queryRows("SELECT Name FROM Bk_Item", &.{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("a'b", rows[0].values[0].asText().?);
}

test "SQL 脚本：结构 + 数据，字面量安全" {
    const a = std.testing.allocator;
    const xml =
        \\<EntityModel><Tables><Table Name="Dump" TableName="Dump_Item">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Name" DataType="String" Length="50" />
        \\    <Column Name="Flag" DataType="Boolean" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m = try model.EntityModel.parse(a, xml);
    var dal = try @import("dal.zig").Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const t = try dal.table("Dump");
    _ = try t.insert(&s, &.{
        .{ .name = "Name", .value = .{ .text = "O'Brien" } },
        .{ .name = "Flag", .value = .{ .boolean = true } },
    });
    _ = try t.insert(&s, &.{
        .{ .name = "Name", .value = .{ .text = "plain" } },
        .{ .name = "Flag", .value = .{ .boolean = false } },
    });

    const sql = try dumpSqlAlloc(a, &s, &dal.model, .sqlite, .{});
    defer a.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "DROP TABLE IF EXISTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "O''Brien") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT INTO") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "Dump_Item") != null);

    // 结构-only：不应出现 INSERT
    const ddl = try dumpSqlAlloc(a, &s, &dal.model, .sqlite, .{ .include_data = false });
    defer a.free(ddl);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "INSERT INTO") == null);

    // only 过滤：不匹配的表一个都不导
    const empty = try dumpSqlAlloc(a, &s, &dal.model, .sqlite, .{ .only = &.{"NoSuchTable"} });
    defer a.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "CREATE TABLE") == null);
}

test "非 SQLite 不支持原生快照（显式报错）" {
    const a = std.testing.allocator;
    const xml =
        \\<EntityModel><Tables><Table Name="X"><Columns><Column Name="Id" DataType="Int32" PrimaryKey="True" /></Columns></Table></Tables></EntityModel>
    ;
    const m = try model.EntityModel.parse(a, xml);
    var dal = try @import("dal.zig").Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    try std.testing.expectError(error.Unsupported, vacuumInto(&s, .mysql, "x.db"));
}
