//! 反向工程：从**现有数据库结构**生成 `Model.xml`（对应 DH.NCode `DbMetaData.GetSchema` + XCodeTool 反查）。
//!
//! 与正向 `Dal.syncSchema`（模型 → 建表）互为逆过程：这里读库 → 模型，方便接管历史库。
//!
//! 支持方言：
//! - **SQLite**：`sqlite_master` + `PRAGMA table_info` / `index_list` / `index_info`
//! - **MySQL**：`information_schema.{tables,columns,statistics}`
//!
//! 约定（与 `EntityModel` 解析口径一致）：
//! - 表名取物理名（`Table Name` 与 `TableName` 都写物理名，避免解析时再猜）；
//! - 主键信息落在列上（`PrimaryKey="True"`），MySQL 的 `PRIMARY` 索引不重复输出；
//! - SQLite 的 `sqlite_autoindex_*` 隐式索引跳过；
//! - 自增：SQLite 看建表语句是否含 `AUTOINCREMENT`；MySQL 看 `extra` 是否含 `auto_increment`；
//! - 注释：MySQL 取 `table_comment` / `column_comment`；SQLite 无注释（留空）。

const std = @import("std");
const Buf = @import("zzig").Buf;
const DataType = @import("types.zig").DataType;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const DatabaseKind = @import("dialect.zig").DatabaseKind;

pub const Options = struct {
    /// `<Option><Namespace>`
    namespace: []const u8 = "Entity",
    /// `<Option><ConnName>`（空则不写）
    conn_name: []const u8 = "",
    /// 是否包含视图
    include_views: bool = false,
    /// 只反查这些表（空 = 全部；忽略大小写）
    only: []const []const u8 = &.{},
};

pub const Column = struct {
    name: []const u8,
    data_type: DataType,
    raw_type: []const u8 = "",
    length: i32 = 0,
    precision: i32 = 0,
    scale: i32 = 0,
    primary_key: bool = false,
    identity: bool = false,
    nullable: bool = false,
    description: []const u8 = "",
};

pub const Index = struct {
    name: []const u8 = "",
    unique: bool = false,
    columns: []const []const u8 = &.{},
};

pub const Table = struct {
    name: []const u8,
    description: []const u8 = "",
    is_view: bool = false,
    columns: []const Column = &.{},
    indexes: []const Index = &.{},
};

/// 直接生成 `Model.xml` 文本（调用方负责 free）。
pub fn modelXmlAlloc(gpa: std.mem.Allocator, s: *Session, opts: Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const tables = try readTables(a, s, opts);

    var b = Buf.init(gpa);
    defer b.deinit();

    try b.add("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<EntityModel xmlns=\"https://newlifex.com/Model202509.xsd\">\n");
    try b.add("  <Option>\n");
    try b.fmt("    <Namespace>{s}</Namespace>\n", .{opts.namespace});
    if (opts.conn_name.len > 0) try b.fmt("    <ConnName>{s}</ConnName>\n", .{opts.conn_name});
    // 反向得到的模型默认不自动迁移（接管历史库时不该反过来改库）
    try b.add("    <Migration>Off</Migration>\n");
    try b.add("  </Option>\n");
    try b.add("  <Tables>\n");

    for (tables) |t| {
        try b.add("    <Table ");
        try attr(&b, "Name", t.name);
        try attr(&b, "TableName", t.name);
        if (t.description.len > 0) try attr(&b, "Description", t.description);
        if (t.is_view) try attr(&b, "IsView", "True");
        try b.add(">\n");

        try b.add("      <Columns>\n");
        for (t.columns) |c| {
            try b.add("        <Column ");
            try attr(&b, "Name", c.name);
            try attr(&b, "ColumnName", c.name);
            try attr(&b, "DataType", c.data_type.name());
            if (c.raw_type.len > 0) try attr(&b, "RawType", c.raw_type);
            if (c.length > 0) try b.fmt(" Length=\"{d}\"", .{c.length});
            if (c.precision > 0) try b.fmt(" Precision=\"{d}\"", .{c.precision});
            if (c.scale > 0) try b.fmt(" Scale=\"{d}\"", .{c.scale});
            if (c.identity) try attr(&b, "Identity", "True");
            if (c.primary_key) try attr(&b, "PrimaryKey", "True");
            if (c.nullable) try attr(&b, "Nullable", "True");
            if (c.description.len > 0) try attr(&b, "Description", c.description);
            try b.add(" />\n");
        }
        try b.add("      </Columns>\n");

        if (t.indexes.len > 0) {
            try b.add("      <Indexes>\n");
            for (t.indexes) |idx| {
                try b.add("        <Index");
                if (idx.name.len > 0) try attr(&b, "Name", idx.name);
                if (idx.columns.len > 0) {
                    try b.add(" Columns=\"");
                    for (idx.columns, 0..) |col, i| {
                        if (i > 0) try b.add(",");
                        try b.add(col);
                    }
                    try b.add("\"");
                }
                if (idx.unique) try attr(&b, "Unique", "True");
                try b.add(" />\n");
            }
            try b.add("      </Indexes>\n");
        }
        try b.add("    </Table>\n");
    }

    try b.add("  </Tables>\n</EntityModel>\n");
    return b.toOwnedSlice();
}

/// 读取表结构（返回的字符串都分配在 `a` 上）。
pub fn readTables(a: std.mem.Allocator, s: *Session, opts: Options) ![]Table {
    return switch (s.kind) {
        .sqlite => readSqlite(a, s, opts),
        .mysql => readMySql(a, s, opts),
        .postgresql => readPostgres(a, s, opts),
        .sqlserver => readSqlServer(a, s, opts),
        else => error.Unsupported,
    };
}

fn wanted(opts: Options, name: []const u8) bool {
    if (opts.only.len == 0) return true;
    for (opts.only) |o| {
        if (std.ascii.eqlIgnoreCase(o, name)) return true;
    }
    return false;
}

// ── SQLite ──────────────────────────────────────────────────────────────────

fn readSqlite(a: std.mem.Allocator, s: *Session, opts: Options) ![]Table {
    var list: std.ArrayList(Table) = .empty;
    errdefer list.deinit(a);

    const q = "SELECT type, name, COALESCE(sql, '') FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name";
    const objs = try s.queryRows(q, &.{});
    for (objs) |row| {
        const kind = row.values[0].asText() orelse "";
        const name = row.values[1].asText() orelse continue;
        const sql = row.values[2].asText() orelse "";
        const is_view = std.ascii.eqlIgnoreCase(kind, "view");
        if (is_view and !opts.include_views) continue;
        if (!wanted(opts, name)) continue;

        // SQLite 的自增写在建表语句里（INTEGER PRIMARY KEY AUTOINCREMENT）
        const has_autoinc = containsIgnoreCase(sql, "AUTOINCREMENT");
        const cols = try sqliteColumns(a, s, name, has_autoinc);
        var indexes: []Index = &.{};
        if (!is_view) indexes = try sqliteIndexes(a, s, name);

        try list.append(a, .{
            .name = try a.dupe(u8, name),
            .is_view = is_view,
            .columns = cols,
            .indexes = indexes,
        });
    }
    return list.toOwnedSlice(a);
}

fn sqliteColumns(a: std.mem.Allocator, s: *Session, table: []const u8, has_autoinc: bool) ![]Column {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "PRAGMA table_info(");
    try quoteInto(a, &buf, .sqlite, table);
    try buf.append(a, ')');
    const sql = try buf.toOwnedSlice(a);

    const rows = try s.queryRows(sql, &.{});
    var cols: std.ArrayList(Column) = .empty;
    errdefer cols.deinit(a);
    for (rows) |row| {
        const name = row.values[1].asText() orelse continue;
        const declared = row.values[2].asText() orelse "";
        const notnull = row.values[3].asI64() orelse 0;
        const pk = row.values[5].asI64() orelse 0;

        const dt = sqliteDataType(declared);
        var col = Column{
            .name = try a.dupe(u8, name),
            .data_type = dt,
            .raw_type = try a.dupe(u8, declared),
            .primary_key = pk > 0,
            // 只有声明了 AUTOINCREMENT（或 INTEGER PRIMARY KEY）才算自增
            .identity = pk > 0 and has_autoinc,
            .nullable = notnull == 0 and pk == 0,
        };
        if (dt == .string) {
            if (extractParenInt(declared, "VARCHAR")) |n| col.length = n;
        }
        if (dt == .decimal) {
            if (extractParenInts(declared)) |pair| {
                col.precision = pair[0];
                col.scale = pair[1];
            }
        }
        try cols.append(a, col);
    }
    return cols.toOwnedSlice(a);
}

fn sqliteIndexes(a: std.mem.Allocator, s: *Session, table: []const u8) ![]Index {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "PRAGMA index_list(");
    try quoteInto(a, &buf, .sqlite, table);
    try buf.append(a, ')');
    const sql = try buf.toOwnedSlice(a);

    const rows = try s.queryRows(sql, &.{});
    var list: std.ArrayList(Index) = .empty;
    errdefer list.deinit(a);
    for (rows) |row| {
        const name = row.values[1].asText() orelse continue;
        // sqlite_autoindex_* 是主键/唯一约束的隐式索引，不写进模型
        if (std.ascii.startsWithIgnoreCase(name, "sqlite_autoindex")) continue;
        const unique = (row.values[2].asI64() orelse 0) != 0;

        const cols = try sqliteIndexColumns(a, s, name);
        if (cols.len == 0) continue;
        try list.append(a, .{ .name = try a.dupe(u8, name), .unique = unique, .columns = cols });
    }
    return list.toOwnedSlice(a);
}

fn sqliteIndexColumns(a: std.mem.Allocator, s: *Session, index_name: []const u8) ![]const []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "PRAGMA index_info(");
    try quoteInto(a, &buf, .sqlite, index_name);
    try buf.append(a, ')');
    const sql = try buf.toOwnedSlice(a);

    const rows = try s.queryRows(sql, &.{});
    var cols: std.ArrayList([]const u8) = .empty;
    errdefer cols.deinit(a);
    for (rows) |row| {
        const n = row.values[2].asText() orelse continue;
        try cols.append(a, try a.dupe(u8, n));
    }
    return cols.toOwnedSlice(a);
}

fn sqliteDataType(declared: []const u8) DataType {
    const t = std.mem.trim(u8, declared, " \t\r\n");
    if (t.len == 0) return .string;
    // 顺序有讲究：TINYINT 先于 INT、BIGINT 先于 INT
    if (std.ascii.startsWithIgnoreCase(t, "TINYINT")) return .byte;
    if (std.ascii.startsWithIgnoreCase(t, "SMALLINT")) return .int16;
    if (std.ascii.startsWithIgnoreCase(t, "BIGINT")) return .int64;
    if (std.ascii.startsWithIgnoreCase(t, "INT")) return .int32;
    if (std.ascii.startsWithIgnoreCase(t, "BOOL")) return .boolean;
    if (std.ascii.startsWithIgnoreCase(t, "DECIMAL") or std.ascii.startsWithIgnoreCase(t, "NUMERIC")) return .decimal;
    if (std.ascii.startsWithIgnoreCase(t, "DOUBLE")) return .double;
    if (std.ascii.startsWithIgnoreCase(t, "REAL") or std.ascii.startsWithIgnoreCase(t, "FLOAT")) return .single;
    if (std.ascii.startsWithIgnoreCase(t, "DATETIME") or std.ascii.startsWithIgnoreCase(t, "TIMESTAMP") or std.ascii.startsWithIgnoreCase(t, "DATE")) return .datetime;
    if (std.ascii.startsWithIgnoreCase(t, "BLOB") or std.ascii.startsWithIgnoreCase(t, "BINARY")) return .binary;
    if (std.ascii.startsWithIgnoreCase(t, "JSON")) return .json;
    // SQLite 的官方 Guid 写法（C# `SQLite.cs` 的 _DataTypes）：uniqueidentifier / guid
    if (std.ascii.eqlIgnoreCase(t, "uniqueidentifier") or std.ascii.startsWithIgnoreCase(t, "guid")) return .guid;
    return .string;
}

// ── MySQL ───────────────────────────────────────────────────────────────────

fn readMySql(a: std.mem.Allocator, s: *Session, opts: Options) ![]Table {
    var list: std.ArrayList(Table) = .empty;
    errdefer list.deinit(a);

    const q =
        "SELECT table_name, table_type, COALESCE(table_comment, '') FROM information_schema.tables " ++
        "WHERE table_schema = DATABASE() ORDER BY table_name";
    const objs = try s.queryRows(q, &.{});
    for (objs) |row| {
        const name = row.values[0].asText() orelse continue;
        const table_type = row.values[1].asText() orelse "";
        const comment = row.values[2].asText() orelse "";
        const is_view = std.ascii.eqlIgnoreCase(table_type, "VIEW");
        if (is_view and !opts.include_views) continue;
        if (!wanted(opts, name)) continue;

        const cols = try mysqlColumns(a, s, name);
        var indexes: []Index = &.{};
        if (!is_view) indexes = try mysqlIndexes(a, s, name);

        try list.append(a, .{
            .name = try a.dupe(u8, name),
            .description = try a.dupe(u8, comment),
            .is_view = is_view,
            .columns = cols,
            .indexes = indexes,
        });
    }
    return list.toOwnedSlice(a);
}

fn mysqlColumns(a: std.mem.Allocator, s: *Session, table: []const u8) ![]Column {
    const q =
        "SELECT column_name, data_type, column_type, is_nullable, column_key, extra, " ++
        "COALESCE(column_comment, ''), character_maximum_length, numeric_precision, numeric_scale " ++
        "FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? " ++
        "ORDER BY ordinal_position";
    const rows = try s.queryRows(q, &.{.{ .text = table }});

    var cols: std.ArrayList(Column) = .empty;
    errdefer cols.deinit(a);
    for (rows) |row| {
        const name = row.values[0].asText() orelse continue;
        const data_type = row.values[1].asText() orelse "";
        const column_type = row.values[2].asText() orelse "";
        const is_nullable = row.values[3].asText() orelse "";
        const column_key = row.values[4].asText() orelse "";
        const extra = row.values[5].asText() orelse "";
        const comment = row.values[6].asText() orelse "";

        var col = Column{
            .name = try a.dupe(u8, name),
            .data_type = mysqlDataType(data_type, column_type),
            .raw_type = try a.dupe(u8, column_type),
            .primary_key = std.ascii.eqlIgnoreCase(column_key, "PRI"),
            .identity = containsIgnoreCase(extra, "auto_increment"),
            .nullable = std.ascii.eqlIgnoreCase(is_nullable, "YES"),
            .description = try a.dupe(u8, comment),
        };
        col.length = intOrZero(row.values[7]);
        col.precision = intOrZero(row.values[8]);
        col.scale = intOrZero(row.values[9]);
        try cols.append(a, col);
    }
    return cols.toOwnedSlice(a);
}

fn mysqlIndexes(a: std.mem.Allocator, s: *Session, table: []const u8) ![]Index {
    const q =
        "SELECT index_name, non_unique, column_name FROM information_schema.statistics " ++
        "WHERE table_schema = DATABASE() AND table_name = ? ORDER BY index_name, seq_in_index";
    const rows = try s.queryRows(q, &.{.{ .text = table }});

    var list: std.ArrayList(Index) = .empty;
    errdefer {
        for (list.items) |it| a.free(it.columns);
        list.deinit(a);
    }

    var current_name: []const u8 = "";
    var current_cols: std.ArrayList([]const u8) = .empty;
    var current_unique = false;

    // 结果按 index_name 排序，逐行收敛；遇到新名字就落盘上一组
    for (rows) |row| {
        const name = row.values[0].asText() orelse continue;
        const non_unique = row.values[1].asI64() orelse 1;
        const col = row.values[2].asText() orelse continue;

        if (current_name.len > 0 and !std.mem.eql(u8, current_name, name)) {
            try pushIndex(a, &list, current_name, current_unique, &current_cols);
        }
        if (current_name.len == 0 or !std.mem.eql(u8, current_name, name)) {
            current_name = try a.dupe(u8, name);
            current_unique = non_unique == 0;
            current_cols = .empty;
        }
        try current_cols.append(a, try a.dupe(u8, col));
    }
    if (current_name.len > 0) try pushIndex(a, &list, current_name, current_unique, &current_cols);
    return list.toOwnedSlice(a);
}

fn pushIndex(a: std.mem.Allocator, list: *std.ArrayList(Index), name: []const u8, unique: bool, cols: *std.ArrayList([]const u8)) !void {
    const owned = try cols.toOwnedSlice(a);
    cols.* = .empty;
    // 主键索引不重复输出（已由列的 PrimaryKey 表达）
    if (std.ascii.eqlIgnoreCase(name, "PRIMARY")) {
        a.free(owned);
        return;
    }
    try list.append(a, .{ .name = name, .unique = unique, .columns = owned });
}

fn mysqlDataType(data_type: []const u8, column_type: []const u8) DataType {
    const t = std.mem.trim(u8, data_type, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "tinyint")) {
        // tinyint(1) 在 MySQL 里就是布尔（XCode 的 Boolean 也落成 tinyint(1)）
        if (std.mem.startsWith(u8, column_type, "tinyint(1)")) return .boolean;
        return .byte;
    }
    if (std.ascii.eqlIgnoreCase(t, "smallint")) return .int16;
    if (std.ascii.eqlIgnoreCase(t, "mediumint") or std.ascii.eqlIgnoreCase(t, "int") or std.ascii.eqlIgnoreCase(t, "integer")) return .int32;
    if (std.ascii.eqlIgnoreCase(t, "bigint")) return .int64;
    if (std.ascii.eqlIgnoreCase(t, "decimal") or std.ascii.eqlIgnoreCase(t, "numeric")) return .decimal;
    if (std.ascii.eqlIgnoreCase(t, "float")) return .single;
    if (std.ascii.eqlIgnoreCase(t, "double") or std.ascii.eqlIgnoreCase(t, "real")) return .double;
    if (std.ascii.eqlIgnoreCase(t, "datetime") or std.ascii.eqlIgnoreCase(t, "timestamp") or std.ascii.eqlIgnoreCase(t, "date")) return .datetime;
    if (std.ascii.eqlIgnoreCase(t, "year")) return .int16;
    if (std.ascii.eqlIgnoreCase(t, "blob") or std.ascii.eqlIgnoreCase(t, "tinyblob") or
        std.ascii.eqlIgnoreCase(t, "mediumblob") or std.ascii.eqlIgnoreCase(t, "longblob") or
        std.ascii.eqlIgnoreCase(t, "binary") or std.ascii.eqlIgnoreCase(t, "varbinary")) return .binary;
    if (std.ascii.eqlIgnoreCase(t, "json")) return .json;
    if (std.ascii.eqlIgnoreCase(t, "bit")) return .int64;
    return .string;
}

// ── PostgreSQL ──────────────────────────────────────────────────────────────

/// PostgreSQL 取结构用的是 `information_schema` + 少量 `pg_catalog`（列注释、索引列顺序）。
///
/// 约定：表名以**字符串字面量**内联（不用参数占位符）——MySQL 走 `?`、PG 走 `$n`，
/// 内联可以让三种方言共用同一套「按表取列」的写法；标识符本身已由 `quoteInto` 处理。
fn readPostgres(a: std.mem.Allocator, s: *Session, opts: Options) ![]Table {
    var list: std.ArrayList(Table) = .empty;
    errdefer list.deinit(a);

    const q =
        "SELECT c.relname, CASE WHEN c.relkind = 'v' THEN 'VIEW' ELSE 'BASE TABLE' END " ++
        "FROM pg_catalog.pg_class c " ++
        "JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace " ++
        "WHERE n.nspname = current_schema() AND c.relkind IN ('r','p','v') " ++
        "ORDER BY c.relname";
    const objs = try s.queryRows(q, &.{});
    for (objs) |row| {
        const name = row.values[0].asText() orelse continue;
        const table_type = row.values[1].asText() orelse "";
        const is_view = std.ascii.eqlIgnoreCase(table_type, "VIEW");
        if (is_view and !opts.include_views) continue;
        if (!wanted(opts, name)) continue;

        const cols = try pgColumns(a, s, name);
        var indexes: []Index = &.{};
        if (!is_view) indexes = try pgIndexes(a, s, name);

        try list.append(a, .{
            .name = try a.dupe(u8, name),
            .is_view = is_view,
            .columns = cols,
            .indexes = indexes,
        });
    }
    return list.toOwnedSlice(a);
}

fn pgColumns(a: std.mem.Allocator, s: *Session, table: []const u8) ![]Column {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(
        a,
        "SELECT c.column_name, c.data_type, c.udt_name, c.is_nullable, c.is_identity, " ++
            "c.character_maximum_length, c.numeric_precision, c.numeric_scale, COALESCE(c.column_default,''), " ++
            "COALESCE(pgd.description,'') " ++
            "FROM information_schema.columns c " ++
            "LEFT JOIN pg_catalog.pg_statio_all_tables st " ++
            "  ON st.schemaname = c.table_schema AND st.relname = c.table_name " ++
            "LEFT JOIN pg_catalog.pg_description pgd " ++
            "  ON pgd.objoid = st.relid AND pgd.objsubid = c.ordinal_position " ++
            "WHERE c.table_schema = current_schema() AND c.table_name = ",
    );
    try pushSqlStringLiteral(a, &buf, table);
    try buf.appendSlice(a, " ORDER BY c.ordinal_position");
    const sql = try buf.toOwnedSlice(a);

    const rows = try s.queryRows(sql, &.{});
    var cols: std.ArrayList(Column) = .empty;
    errdefer cols.deinit(a);
    for (rows) |row| {
        const name = row.values[0].asText() orelse continue;
        const data_type = row.values[1].asText() orelse "";
        const udt_name = row.values[2].asText() orelse "";
        const is_nullable = row.values[3].asText() orelse "";
        const is_identity = row.values[4].asText() orelse "";
        const column_default = row.values[8].asText() orelse "";
        const comment = row.values[9].asText() orelse "";

        var col = Column{
            .name = try a.dupe(u8, name),
            .data_type = pgDataType(data_type, udt_name),
            .raw_type = try a.dupe(u8, udt_name),
            // `IDENTITY` 或 `serial`（默认值 nextval(...)）都算自增
            .identity = std.ascii.eqlIgnoreCase(is_identity, "YES") or containsIgnoreCase(column_default, "nextval"),
            .nullable = std.ascii.eqlIgnoreCase(is_nullable, "YES"),
            .description = try a.dupe(u8, comment),
        };
        col.length = intOrZero(row.values[5]);
        col.precision = intOrZero(row.values[6]);
        col.scale = intOrZero(row.values[7]);
        try cols.append(a, col);
    }

    // 主键：填到列上（与 SQLite / MySQL 一致）
    var kbuf: std.ArrayList(u8) = .empty;
    defer kbuf.deinit(a);
    try kbuf.appendSlice(
        a,
        "SELECT kcu.column_name FROM information_schema.table_constraints tc " ++
            "JOIN information_schema.key_column_usage kcu " ++
            "  ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema " ++
            "WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = current_schema() " ++
            "AND tc.table_name = ",
    );
    try pushSqlStringLiteral(a, &kbuf, table);
    const ksql = try kbuf.toOwnedSlice(a);
    const key_rows = try s.queryRows(ksql, &.{});
    for (key_rows) |row| {
        const key_name = row.values[0].asText() orelse continue;
        for (cols.items) |*col| {
            if (std.ascii.eqlIgnoreCase(col.name, key_name)) col.primary_key = true;
        }
    }
    return cols.toOwnedSlice(a);
}

fn pgIndexes(a: std.mem.Allocator, s: *Session, table: []const u8) ![]Index {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(
        a,
        "SELECT i.relname, ix.indisunique, ix.indisprimary, a.attname " ++
            "FROM pg_catalog.pg_index ix " ++
            "JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid " ++
            "JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid " ++
            "JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace " ++
            "JOIN pg_catalog.pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey) " ++
            "WHERE n.nspname = current_schema() AND t.relname = ",
    );
    try pushSqlStringLiteral(a, &buf, table);
    try buf.appendSlice(a, " ORDER BY i.relname, array_position(ix.indkey, a.attnum)");
    const sql = try buf.toOwnedSlice(a);

    const rows = try s.queryRows(sql, &.{});
    var list: std.ArrayList(Index) = .empty;
    errdefer {
        for (list.items) |it| a.free(it.columns);
        list.deinit(a);
    }

    var current_name: []const u8 = "";
    var current_cols: std.ArrayList([]const u8) = .empty;
    var current_unique = false;
    var current_primary = false;

    for (rows) |row| {
        const name = row.values[0].asText() orelse continue;
        const unique = (row.values[1].asI64() orelse 0) != 0;
        const primary = (row.values[2].asI64() orelse 0) != 0;
        const col = row.values[3].asText() orelse continue;

        if (current_name.len > 0 and !std.mem.eql(u8, current_name, name)) {
            try pushPgIndex(a, &list, current_name, current_unique, current_primary, &current_cols);
        }
        if (current_name.len == 0 or !std.mem.eql(u8, current_name, name)) {
            current_name = try a.dupe(u8, name);
            current_unique = unique;
            current_primary = primary;
            current_cols = .empty;
        }
        try current_cols.append(a, try a.dupe(u8, col));
    }
    if (current_name.len > 0) try pushPgIndex(a, &list, current_name, current_unique, current_primary, &current_cols);
    return list.toOwnedSlice(a);
}

fn pushPgIndex(
    a: std.mem.Allocator,
    list: *std.ArrayList(Index),
    name: []const u8,
    unique: bool,
    primary: bool,
    cols: *std.ArrayList([]const u8),
) !void {
    const owned = try cols.toOwnedSlice(a);
    cols.* = .empty;
    // 主键索引不重复输出（已由列的 PrimaryKey 表达）
    if (primary) {
        a.free(owned);
        return;
    }
    try list.append(a, .{ .name = name, .unique = unique, .columns = owned });
}

fn pgDataType(data_type: []const u8, udt_name: []const u8) DataType {
    const t = std.mem.trim(u8, data_type, " \t\r\n");
    const u = std.mem.trim(u8, udt_name, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "boolean") or std.ascii.eqlIgnoreCase(u, "bool")) return .boolean;
    if (std.ascii.eqlIgnoreCase(u, "bpchar") or std.ascii.eqlIgnoreCase(u, "varchar") or
        std.ascii.eqlIgnoreCase(u, "text") or std.ascii.eqlIgnoreCase(t, "character") or
        std.ascii.eqlIgnoreCase(t, "character varying") or std.ascii.eqlIgnoreCase(t, "text")) return .string;
    if (std.ascii.eqlIgnoreCase(u, "int2")) return .int16;
    if (std.ascii.eqlIgnoreCase(u, "int4")) return .int32;
    if (std.ascii.eqlIgnoreCase(u, "int8")) return .int64;
    if (std.ascii.eqlIgnoreCase(u, "numeric") or std.ascii.eqlIgnoreCase(t, "numeric")) return .decimal;
    if (std.ascii.eqlIgnoreCase(u, "float4")) return .single;
    if (std.ascii.eqlIgnoreCase(u, "float8")) return .double;
    if (std.ascii.eqlIgnoreCase(t, "timestamp without time zone") or
        std.ascii.eqlIgnoreCase(t, "timestamp with time zone") or
        std.ascii.eqlIgnoreCase(t, "date") or std.ascii.eqlIgnoreCase(t, "time without time zone") or
        std.ascii.eqlIgnoreCase(u, "timestamp") or std.ascii.eqlIgnoreCase(u, "timestamptz") or
        std.ascii.eqlIgnoreCase(u, "date")) return .datetime;
    if (std.ascii.eqlIgnoreCase(u, "bytea")) return .binary;
    if (std.ascii.eqlIgnoreCase(u, "json") or std.ascii.eqlIgnoreCase(u, "jsonb")) return .json;
    // PG 系的原生 Guid 类型（C# `PostgreSQL.cs` / `KingBase.cs` / `HighGo.cs` 都用 uuid）
    if (std.ascii.eqlIgnoreCase(u, "uuid")) return .guid;
    // serial 系列在 information_schema 里也表现为 integer/bigint，此处已覆盖
    return .string;
}

// ── SQL Server ──────────────────────────────────────────────────────────────

/// SQL Server 取结构：`INFORMATION_SCHEMA` 拿表/列/主键，`sys.*` 拿自增与索引。
fn readSqlServer(a: std.mem.Allocator, s: *Session, opts: Options) ![]Table {
    var list: std.ArrayList(Table) = .empty;
    errdefer list.deinit(a);

    const q =
        "SELECT TABLE_NAME, TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES ORDER BY TABLE_NAME";
    const objs = try s.queryRows(q, &.{});
    for (objs) |row| {
        const name = row.values[0].asText() orelse continue;
        const table_type = row.values[1].asText() orelse "";
        const is_view = std.ascii.eqlIgnoreCase(table_type, "VIEW");
        if (is_view and !opts.include_views) continue;
        if (!wanted(opts, name)) continue;

        const cols = try mssqlColumns(a, s, name);
        var indexes: []Index = &.{};
        if (!is_view) indexes = try mssqlIndexes(a, s, name);

        try list.append(a, .{
            .name = try a.dupe(u8, name),
            .is_view = is_view,
            .columns = cols,
            .indexes = indexes,
        });
    }
    return list.toOwnedSlice(a);
}

fn mssqlColumns(a: std.mem.Allocator, s: *Session, table: []const u8) ![]Column {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(
        a,
        "SELECT c.COLUMN_NAME, c.DATA_TYPE, c.IS_NULLABLE, c.CHARACTER_MAXIMUM_LENGTH, " ++
            "c.NUMERIC_PRECISION, c.NUMERIC_SCALE, " ++
            "COLUMNPROPERTY(OBJECT_ID(c.TABLE_NAME), c.COLUMN_NAME, 'IsIdentity') " ++
            "FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_NAME = ",
    );
    try pushSqlStringLiteral(a, &buf, table);
    try buf.appendSlice(a, " ORDER BY c.ORDINAL_POSITION");
    const sql = try buf.toOwnedSlice(a);

    const rows = try s.queryRows(sql, &.{});
    var cols: std.ArrayList(Column) = .empty;
    errdefer cols.deinit(a);
    for (rows) |row| {
        const name = row.values[0].asText() orelse continue;
        const data_type = row.values[1].asText() orelse "";
        const is_nullable = row.values[2].asText() orelse "";
        const identity = (row.values[6].asI64() orelse 0) != 0;

        var col = Column{
            .name = try a.dupe(u8, name),
            .data_type = mssqlDataType(data_type),
            .raw_type = try a.dupe(u8, data_type),
            .identity = identity,
            .nullable = std.ascii.eqlIgnoreCase(is_nullable, "YES"),
        };
        col.length = intOrZero(row.values[3]);
        col.precision = intOrZero(row.values[4]);
        col.scale = intOrZero(row.values[5]);
        try cols.append(a, col);
    }

    // 主键
    var kbuf: std.ArrayList(u8) = .empty;
    defer kbuf.deinit(a);
    try kbuf.appendSlice(
        a,
        "SELECT kcu.COLUMN_NAME FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc " ++
            "JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu " ++
            "  ON kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME " ++
            "WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY' AND tc.TABLE_NAME = ",
    );
    try pushSqlStringLiteral(a, &kbuf, table);
    const ksql = try kbuf.toOwnedSlice(a);
    const key_rows = try s.queryRows(ksql, &.{});
    for (key_rows) |row| {
        const key_name = row.values[0].asText() orelse continue;
        for (cols.items) |*col| {
            if (std.ascii.eqlIgnoreCase(col.name, key_name)) col.primary_key = true;
        }
    }
    return cols.toOwnedSlice(a);
}

fn mssqlIndexes(a: std.mem.Allocator, s: *Session, table: []const u8) ![]Index {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(
        a,
        "SELECT i.name, i.is_unique, i.is_primary_key, c.name " ++
            "FROM sys.indexes i " ++
            "JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id " ++
            "JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id " ++
            "WHERE i.object_id = OBJECT_ID(",
    );
    try pushSqlStringLiteral(a, &buf, table);
    try buf.appendSlice(a, ") AND i.name IS NOT NULL ORDER BY i.name, ic.key_ordinal");
    const sql = try buf.toOwnedSlice(a);

    const rows = try s.queryRows(sql, &.{});
    var list: std.ArrayList(Index) = .empty;
    errdefer {
        for (list.items) |it| a.free(it.columns);
        list.deinit(a);
    }

    var current_name: []const u8 = "";
    var current_cols: std.ArrayList([]const u8) = .empty;
    var current_unique = false;
    var current_primary = false;

    for (rows) |row| {
        const name = row.values[0].asText() orelse continue;
        const unique = (row.values[1].asI64() orelse 0) != 0;
        const primary = (row.values[2].asI64() orelse 0) != 0;
        const col = row.values[3].asText() orelse continue;

        if (current_name.len > 0 and !std.mem.eql(u8, current_name, name)) {
            try pushPgIndex(a, &list, current_name, current_unique, current_primary, &current_cols);
        }
        if (current_name.len == 0 or !std.mem.eql(u8, current_name, name)) {
            current_name = try a.dupe(u8, name);
            current_unique = unique;
            current_primary = primary;
            current_cols = .empty;
        }
        try current_cols.append(a, try a.dupe(u8, col));
    }
    if (current_name.len > 0) try pushPgIndex(a, &list, current_name, current_unique, current_primary, &current_cols);
    return list.toOwnedSlice(a);
}

fn mssqlDataType(data_type: []const u8) DataType {
    const t = std.mem.trim(u8, data_type, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "bit")) return .boolean;
    if (std.ascii.eqlIgnoreCase(t, "tinyint")) return .byte;
    if (std.ascii.eqlIgnoreCase(t, "smallint")) return .int16;
    if (std.ascii.eqlIgnoreCase(t, "int")) return .int32;
    if (std.ascii.eqlIgnoreCase(t, "bigint")) return .int64;
    if (std.ascii.eqlIgnoreCase(t, "real")) return .single;
    if (std.ascii.eqlIgnoreCase(t, "float")) return .double;
    if (std.ascii.eqlIgnoreCase(t, "decimal") or std.ascii.eqlIgnoreCase(t, "numeric") or
        std.ascii.eqlIgnoreCase(t, "money") or std.ascii.eqlIgnoreCase(t, "smallmoney")) return .decimal;
    if (std.ascii.eqlIgnoreCase(t, "datetime") or std.ascii.eqlIgnoreCase(t, "datetime2") or
        std.ascii.eqlIgnoreCase(t, "smalldatetime") or std.ascii.eqlIgnoreCase(t, "date") or
        std.ascii.eqlIgnoreCase(t, "datetimeoffset") or std.ascii.eqlIgnoreCase(t, "time")) return .datetime;
    if (std.ascii.eqlIgnoreCase(t, "binary") or std.ascii.eqlIgnoreCase(t, "varbinary") or
        std.ascii.eqlIgnoreCase(t, "image") or std.ascii.eqlIgnoreCase(t, "timestamp") or
        std.ascii.eqlIgnoreCase(t, "rowversion")) return .binary;
    // C# `DAL_Mapper` 把 uniqueidentifier 映射成 Guid；本仓同样反查成 guid（值仍是 36 位文本）
    if (std.ascii.eqlIgnoreCase(t, "uniqueidentifier")) return .guid;
    return .string;
}

// ── 小工具 ──────────────────────────────────────────────────────────────────

/// 把字符串写成 SQL 字面量（`'` 双写），用于「内联表名」这类只读场景。
fn pushSqlStringLiteral(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(a, '\'');
    for (text) |c| {
        if (c == '\'') try out.append(a, '\'');
        try out.append(a, c);
    }
    try out.append(a, '\'');
}

fn attr(b: *Buf, name: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try b.fmt(" {s}=\"", .{name});
    for (value) |c| {
        switch (c) {
            '&' => try b.add("&amp;"),
            '<' => try b.add("&lt;"),
            '>' => try b.add("&gt;"),
            '"' => try b.add("&quot;"),
            else => try b.addByte(c),
        }
    }
    try b.add("\"");
}

fn quoteInto(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: DatabaseKind, name: []const u8) !void {
    const q = try kind.quoteAlloc(a, name);
    defer a.free(q);
    try out.appendSlice(a, q);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn intOrZero(v: @import("zzig").db.Value) i32 {
    const n = v.asI64() orelse return 0;
    if (n < 0 or n > std.math.maxInt(i32)) return 0;
    return @intCast(n);
}

/// `VARCHAR(50)` → 50
fn extractParenInt(declared: []const u8, prefix: []const u8) ?i32 {
    if (!std.ascii.startsWithIgnoreCase(declared, prefix)) return null;
    const open = std.mem.indexOfScalar(u8, declared, '(') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, declared, open, ')') orelse return null;
    const text = std.mem.trim(u8, declared[open + 1 .. close], " ");
    return std.fmt.parseInt(i32, text, 10) catch null;
}

/// `DECIMAL(18,4)` → {18, 4}
fn extractParenInts(declared: []const u8) ?[2]i32 {
    const open = std.mem.indexOfScalar(u8, declared, '(') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, declared, open, ')') orelse return null;
    const inner = declared[open + 1 .. close];
    const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return null;
    const p = std.fmt.parseInt(i32, std.mem.trim(u8, inner[0..comma], " "), 10) catch return null;
    const s = std.fmt.parseInt(i32, std.mem.trim(u8, inner[comma + 1 ..], " "), 10) catch return null;
    return .{ p, s };
}

test "反向工程：SQLite 类型映射" {
    try std.testing.expectEqual(DataType.int64, sqliteDataType("BIGINT"));
    try std.testing.expectEqual(DataType.int32, sqliteDataType("INTEGER"));
    try std.testing.expectEqual(DataType.byte, sqliteDataType("TINYINT(1)"));
    try std.testing.expectEqual(DataType.string, sqliteDataType("VARCHAR(50)"));
    try std.testing.expectEqual(DataType.decimal, sqliteDataType("DECIMAL(18,4)"));
    try std.testing.expectEqual(DataType.datetime, sqliteDataType("DATETIME"));
    try std.testing.expectEqual(DataType.binary, sqliteDataType("BLOB"));
    try std.testing.expectEqual(DataType.string, sqliteDataType(""));
}

test "反向工程：MySQL 类型映射（tinyint(1) 视为布尔）" {
    try std.testing.expectEqual(DataType.boolean, mysqlDataType("tinyint", "tinyint(1)"));
    try std.testing.expectEqual(DataType.byte, mysqlDataType("tinyint", "tinyint(4)"));
    try std.testing.expectEqual(DataType.int64, mysqlDataType("bigint", "bigint"));
    try std.testing.expectEqual(DataType.string, mysqlDataType("longtext", "longtext"));
    try std.testing.expectEqual(DataType.binary, mysqlDataType("longblob", "longblob"));
    try std.testing.expectEqual(DataType.decimal, mysqlDataType("decimal", "decimal(18,4)"));
}

test "反向工程：PostgreSQL 类型映射（看 udt_name 为主）" {
    try std.testing.expectEqual(DataType.boolean, pgDataType("boolean", "bool"));
    try std.testing.expectEqual(DataType.int16, pgDataType("smallint", "int2"));
    try std.testing.expectEqual(DataType.int32, pgDataType("integer", "int4"));
    try std.testing.expectEqual(DataType.int64, pgDataType("bigint", "int8"));
    try std.testing.expectEqual(DataType.string, pgDataType("character varying", "varchar"));
    try std.testing.expectEqual(DataType.string, pgDataType("text", "text"));
    try std.testing.expectEqual(DataType.decimal, pgDataType("numeric", "numeric"));
    try std.testing.expectEqual(DataType.single, pgDataType("real", "float4"));
    try std.testing.expectEqual(DataType.double, pgDataType("double precision", "float8"));
    try std.testing.expectEqual(DataType.datetime, pgDataType("timestamp without time zone", "timestamp"));
    try std.testing.expectEqual(DataType.datetime, pgDataType("date", "date"));
    try std.testing.expectEqual(DataType.binary, pgDataType("bytea", "bytea"));
    try std.testing.expectEqual(DataType.json, pgDataType("jsonb", "jsonb"));
}

test "反向工程：SQL Server 类型映射" {
    try std.testing.expectEqual(DataType.boolean, mssqlDataType("bit"));
    try std.testing.expectEqual(DataType.byte, mssqlDataType("tinyint"));
    try std.testing.expectEqual(DataType.int16, mssqlDataType("smallint"));
    try std.testing.expectEqual(DataType.int32, mssqlDataType("int"));
    try std.testing.expectEqual(DataType.int64, mssqlDataType("bigint"));
    try std.testing.expectEqual(DataType.double, mssqlDataType("float"));
    try std.testing.expectEqual(DataType.decimal, mssqlDataType("decimal"));
    try std.testing.expectEqual(DataType.decimal, mssqlDataType("money"));
    try std.testing.expectEqual(DataType.datetime, mssqlDataType("datetime2"));
    try std.testing.expectEqual(DataType.binary, mssqlDataType("varbinary"));
    try std.testing.expectEqual(DataType.binary, mssqlDataType("rowversion"));
    try std.testing.expectEqual(DataType.string, mssqlDataType("nvarchar"));
}

test "反向工程：SQL 字符串字面量转义" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try pushSqlStringLiteral(std.testing.allocator, &buf, "O'Brien");
    try std.testing.expectEqualStrings("'O''Brien'", buf.items);
}
