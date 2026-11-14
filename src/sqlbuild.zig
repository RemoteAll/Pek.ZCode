//! SQL 语句组装：INSERT / UPDATE / DELETE / SELECT / COUNT。
//!
//! 生成文本与 Rust `Pek.RCode/src/sqlbuild.rs` 逐字对齐（同一批黄金断言已在单元测试里固化）：
//!
//! - `INSERT INTO "T" ("a", "b") VALUES (?, ?)`
//! - `UPDATE "T" SET "a" = ?, "b" = ? WHERE (...)`
//! - `DELETE FROM "T" WHERE (...)`
//! - `SELECT * FROM "T" WHERE (...) ORDER BY "Id" LIMIT 20 OFFSET 0`
//! - `SELECT COUNT(*) FROM "T" WHERE (...)`

const std = @import("std");
const Buf = @import("zzig").Buf;
const Value = @import("zzig").db.Value;
const model = @import("model.zig");
const TableMeta = model.TableMeta;
const ColumnMeta = model.ColumnMeta;
const dialect = @import("dialect.zig");
const DatabaseKind = dialect.DatabaseKind;
const query = @import("query.zig");
const Where = query.Where;
const Query = query.Query;

/// 组装结果：`text` 与 `params` 均由 `gpa` 分配，调用方负责 `deinit`。
pub const Sql = struct {
    text: []u8,
    params: []Value,

    pub fn deinit(self: Sql, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.params);
    }
};

pub const Field = struct {
    name: []const u8,
    value: Value,
    /// 累加列（`Model.xml` 的 `Column@Additional`）：生成 `col = col + ?` 而不是 `col = ?`
    accumulate: bool = false,
};

fn columnName(table: *const TableMeta, field: []const u8) ![]const u8 {
    const col = table.column(field) orelse return error.ColumnNotFound;
    return table.effectiveColumnName(col);
}

/// 组装 INSERT（`table_name` 为物理表名，分表场景传实际表名）。
pub fn insert(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    fields: []const Field,
) !Sql {
    return insertWith(gpa, kind, table, table_name, fields, .{});
}

/// INSERT 的可选项。
pub const InsertOptions = struct {
    /// 允许显式写入**自增列**（数据迁移 / 导入 / 跳库同步必需）。
    ///
    /// 各方言的处理不同（C# 侧对应 `EntityOperate.AllowInsertIdentity`）：
    /// - SQL Server / SqlCe：整条语句外面包 `SET IDENTITY_INSERT <表> ON; … OFF`
    ///   （不包就是「不能为表 'x' 中的标识列插入显式值」）；
    /// - PostgreSQL 系 / DB2 / DuckDB：DDL 用的是 `GENERATED ALWAYS AS IDENTITY`，
    ///   必须在 `VALUES` 前加 `OVERRIDING SYSTEM VALUE`；
    /// - SQLite / MySQL / Oracle（本仓用序列表达式）：直接给值即可，不做包装。
    allow_identity: bool = false,
};

/// 组装 INSERT（带选项）。未显式提供自增列时，`allow_identity` 不起作用。
pub fn insertWith(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    fields: []const Field,
    opts: InsertOptions,
) !Sql {
    if (fields.len == 0) return error.Model;

    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    // 调用方是否显式给了自增列（决定要不要按方言做特殊处理）
    var identity_given = false;
    if (table.identity()) |identity| {
        for (fields) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, identity.name)) identity_given = true;
        }
    }
    const explicit_identity = opts.allow_identity and identity_given;

    if (explicit_identity and (kind == .sqlserver or kind == .sqlce)) {
        try b.add("SET IDENTITY_INSERT ");
        try kind.pushQuoted(&b, table_name);
        try b.add(" ON;");
    }

    try b.add("INSERT INTO ");
    try kind.pushQuoted(&b, table_name);
    try b.add(" (");

    for (fields, 0..) |field, index| {
        if (index > 0) try b.add(", ");
        try kind.pushQuoted(&b, try columnName(table, field.name));
    }

    // 序列型自增（Oracle，XCode 约定 SEQ_{表名}）：未显式提供自增列时补上序列表达式
    var sequence_identity: ?*const ColumnMeta = null;
    if (kind == .oracle) {
        if (table.identity()) |identity| {
            if (!identity_given) {
                try b.add(", ");
                try kind.pushQuoted(&b, table.effectiveColumnName(identity));
                sequence_identity = identity;
            }
        }
    }

    try b.add(")");

    // `GENERATED ALWAYS AS IDENTITY` 的方言：显式给值时必须声明覆盖
    if (explicit_identity and (kind.isPostgresFamily() or kind == .db2 or kind == .duckdb)) {
        try b.add(" OVERRIDING SYSTEM VALUE");
    }

    try b.add(" VALUES (");
    for (fields, 0..) |field, index| {
        if (index > 0) try b.add(", ");
        try kind.pushPlaceholder(&b, index);
        try params.append(gpa, field.value);
    }
    if (sequence_identity != null) {
        try b.fmt(", \"SEQ_{s}\".NEXTVAL", .{table_name});
    }
    try b.add(")");

    if (explicit_identity and (kind == .sqlserver or kind == .sqlce)) {
        try b.add(";SET IDENTITY_INSERT ");
        try kind.pushQuoted(&b, table_name);
        try b.add(" OFF");
    }

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 多行 UPDATE（同一个列集合）：把 N 条「按主键更新同样几列」合并成**一条**语句。
///
/// 为什么需要：逐条 `UPDATE` 的往返是 N 次；同组（脏列集合相同）合并后只要 1 次。
/// **只写 `cols` 里的列**——未改的列不进 SQL，多业务系统并发写同一张表时不会把
/// 别人刚写的值覆盖回旧值。
///
/// 方言：
/// - SQLite / PostgreSQL 系 / DuckDB / SQL Server：`UPDATE t SET c=v.c FROM (VALUES (...)) AS v(pk,c) WHERE t.pk=v.pk`
/// - MySQL：`UPDATE t JOIN (SELECT ? AS pk, ? AS c UNION ALL ...) v ON ... SET t.c=v.c`
/// - 其它方言返回 `error.Unsupported`（调用方逐条，仍只写脏列）
///
/// `rows` 每行：主键值 + `cols` 各列的值（顺序一致）。
pub fn updateMulti(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    pk_name: []const u8,
    cols: []const []const u8,
    rows: []const []const Value,
) !Sql {
    if (rows.len == 0 or cols.len == 0) return error.Model;
    for (rows) |r| {
        if (r.len != cols.len + 1) return error.Model;
    }

    const pk_col = try columnName(table, pk_name);

    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    var idx: usize = 0;

    switch (kind) {
        .mysql => {
            try b.add("UPDATE ");
            try kind.pushQuoted(&b, table_name);
            try b.add(" JOIN (");
            for (rows, 0..) |row, ri| {
                try b.add(if (ri == 0) "SELECT " else " UNION ALL SELECT ");
                try kind.pushPlaceholder(&b, idx);
                idx += 1;
                try b.add(" AS ");
                try kind.pushQuoted(&b, pk_col);
                for (cols) |c| {
                    try b.add(", ");
                    try kind.pushPlaceholder(&b, idx);
                    idx += 1;
                    try b.add(" AS ");
                    try kind.pushQuoted(&b, try columnName(table, c));
                }
                try params.appendSlice(gpa, row);
            }
            try b.add(") AS v ON ");
            try kind.pushQuoted(&b, table_name);
            try b.add(".");
            try kind.pushQuoted(&b, pk_col);
            try b.add(" = v.");
            try kind.pushQuoted(&b, pk_col);
            try b.add(" SET ");
            for (cols, 0..) |c, ci| {
                if (ci > 0) try b.add(", ");
                const cc = try columnName(table, c);
                try kind.pushQuoted(&b, table_name);
                try b.add(".");
                try kind.pushQuoted(&b, cc);
                try b.add(" = v.");
                try kind.pushQuoted(&b, cc);
            }
        },
        // SQLite 的 `UPDATE ... FROM` **不接受** `(VALUES ...) AS v(a,b)` 的列名列表
        // （实测报 `near "(": syntax error`），改用 `SELECT ? AS a UNION ALL ...`；
        // 每个 SELECT 的列别名已足够，外层不再需要列名列表。
        .sqlite => {
            try b.add("UPDATE ");
            try kind.pushQuoted(&b, table_name);
            try b.add(" SET ");
            for (cols, 0..) |c, ci| {
                if (ci > 0) try b.add(", ");
                const cc = try columnName(table, c);
                try kind.pushQuoted(&b, cc);
                try b.add(" = v.");
                try kind.pushQuoted(&b, cc);
            }
            try b.add(" FROM (");
            for (rows, 0..) |row, ri| {
                try b.add(if (ri == 0) "SELECT " else " UNION ALL SELECT ");
                try kind.pushPlaceholder(&b, idx);
                idx += 1;
                try b.add(" AS ");
                try kind.pushQuoted(&b, pk_col);
                for (cols) |c| {
                    try b.add(", ");
                    try kind.pushPlaceholder(&b, idx);
                    idx += 1;
                    try b.add(" AS ");
                    try kind.pushQuoted(&b, try columnName(table, c));
                }
                try params.appendSlice(gpa, row);
            }
            try b.add(") AS v WHERE ");
            try kind.pushQuoted(&b, table_name);
            try b.add(".");
            try kind.pushQuoted(&b, pk_col);
            try b.add(" = v.");
            try kind.pushQuoted(&b, pk_col);
        },
        .postgresql, .kingbase, .highgo, .vastbase, .duckdb, .sqlserver => {
            try b.add("UPDATE ");
            try kind.pushQuoted(&b, table_name);
            try b.add(" SET ");
            for (cols, 0..) |c, ci| {
                if (ci > 0) try b.add(", ");
                const cc = try columnName(table, c);
                try kind.pushQuoted(&b, cc);
                try b.add(" = v.");
                try kind.pushQuoted(&b, cc);
            }
            try b.add(" FROM (VALUES ");
            for (rows, 0..) |row, ri| {
                if (ri > 0) try b.add(", ");
                try b.add("(");
                for (row, 0..) |v, k| {
                    if (k > 0) try b.add(", ");
                    try kind.pushPlaceholder(&b, idx);
                    idx += 1;
                    try params.append(gpa, v);
                }
                try b.add(")");
            }
            try b.add(") AS v(");
            try kind.pushQuoted(&b, pk_col);
            for (cols) |c| {
                try b.add(", ");
                try kind.pushQuoted(&b, try columnName(table, c));
            }
            try b.add(") WHERE ");
            try kind.pushQuoted(&b, table_name);
            try b.add(".");
            try kind.pushQuoted(&b, pk_col);
            try b.add(" = v.");
            try kind.pushQuoted(&b, pk_col);
        },
        else => return error.Unsupported,
    }

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 「不存在才插入」：`INSERT INTO t (cols) SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM t WHERE k = ?)`。
///
/// 用途（`insert_ignore` 在**没有 `INSERT IGNORE` 的方言**上的实现）：
/// SQL Server / Oracle 等没有 `ON CONFLICT DO NOTHING`，而「先查再写」在批量场景是
/// N 次往返 + 竞态窗口；这条语句把判断与插入合成**一次往返**，服务端原子执行。
///
/// `keys` 用来判断「已存在」（主键或唯一索引列）；都必须在 `row` 里。
pub fn insertIfAbsent(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    row: []const Field,
    keys: []const []const u8,
) !Sql {
    if (row.len == 0 or keys.len == 0) return error.Model;

    var base = try insert(gpa, kind, table, table_name, row);
    defer base.deinit(gpa);

    // `INSERT INTO t ("a","b") VALUES (?, ?)` → `INSERT INTO t ("a","b") SELECT ?, ?`
    const marker = "VALUES (";
    const at = std.mem.indexOf(u8, base.text, marker) orelse return error.Model;

    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    try b.add(base.text[0..at]);
    try b.add("SELECT ");
    try b.add(base.text[at + marker.len ..]); // 保留右括号与后续内容
    try params.appendSlice(gpa, base.params);

    try b.add(" WHERE NOT EXISTS (SELECT 1 FROM ");
    try kind.pushQuoted(&b, table_name);
    try b.add(" WHERE ");
    for (keys, 0..) |k, i| {
        if (i > 0) try b.add(" AND ");
        try kind.pushQuoted(&b, try columnName(table, k));
        try b.add(" = ");
        try kind.pushPlaceholder(&b, base.params.len + i);

        var found: ?Value = null;
        for (row) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, k)) found = f.value;
        }
        try params.append(gpa, found orelse return error.Model);
    }
    try b.add(")");

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 多行 INSERT：`INSERT INTO "T" ("a","b") VALUES (?,?),(?,?)`。
///
/// 约束（与 XCode 批量写一致）：所有行列集合必须**完全一致**（含顺序），否则报 `error.Model`。
/// 参数上限由调用方按 `DatabaseKind.maxStatementParams()` 分批。
pub fn insertMulti(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    rows: []const []const Field,
) !Sql {
    return insertMultiWith(gpa, kind, table, table_name, rows, .{});
}

/// 多行 INSERT（带选项；`allow_identity` 语义同 `insertWith`）。
///
/// 批量导入/迁移同样要保留原主键，所以这里也必须处理
/// SQL Server 的 `SET IDENTITY_INSERT` 与 PG 系的 `OVERRIDING SYSTEM VALUE`。
pub fn insertMultiWith(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    rows: []const []const Field,
    opts: InsertOptions,
) !Sql {
    if (rows.len == 0) return error.Model;
    const cols = rows[0].len;
    if (cols == 0) return error.Model;
    for (rows[1..]) |row| {
        if (row.len != cols) return error.Model;
        for (row, 0..) |field, i| {
            if (!std.ascii.eqlIgnoreCase(field.name, rows[0][i].name)) return error.Model;
        }
    }

    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    // 列集合里是否含自增列（行间列集合已校验一致，看第一行即可）
    var identity_given = false;
    if (table.identity()) |identity| {
        for (rows[0]) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, identity.name)) identity_given = true;
        }
    }
    const explicit_identity = opts.allow_identity and identity_given;

    if (explicit_identity and (kind == .sqlserver or kind == .sqlce)) {
        try b.add("SET IDENTITY_INSERT ");
        try kind.pushQuoted(&b, table_name);
        try b.add(" ON;");
    }

    try b.add("INSERT INTO ");
    try kind.pushQuoted(&b, table_name);
    try b.add(" (");
    for (rows[0], 0..) |field, index| {
        if (index > 0) try b.add(", ");
        try kind.pushQuoted(&b, try columnName(table, field.name));
    }
    try b.add(")");

    if (explicit_identity and (kind.isPostgresFamily() or kind == .db2 or kind == .duckdb)) {
        try b.add(" OVERRIDING SYSTEM VALUE");
    }

    try b.add(" VALUES ");

    for (rows, 0..) |row, row_index| {
        if (row_index > 0) try b.add(", ");
        try b.add("(");
        for (row, 0..) |field, col_index| {
            if (col_index > 0) try b.add(", ");
            try kind.pushPlaceholder(&b, params.items.len);
            try params.append(gpa, field.value);
        }
        try b.add(")");
    }

    if (explicit_identity and (kind == .sqlserver or kind == .sqlce)) {
        try b.add(";SET IDENTITY_INSERT ");
        try kind.pushQuoted(&b, table_name);
        try b.add(" OFF");
    }

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 组装 UPDATE（`sets` 为空报错；`filter` 为空即全表，调用方自行保证带上主键条件）。
pub fn update(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    sets: []const Field,
    filter: ?*const Where,
) !Sql {
    if (sets.len == 0) return error.Model;

    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    try b.add("UPDATE ");
    try kind.pushQuoted(&b, table_name);
    try b.add(" SET ");
    for (sets, 0..) |field, index| {
        if (index > 0) try b.add(", ");
        try kind.pushQuoted(&b, try columnName(table, field.name));
        try b.add(" = ");
        if (field.accumulate) {
            // 累加列：`col = col + ?`（对应 C# `Column@Additional`）
            try kind.pushQuoted(&b, try columnName(table, field.name));
            try b.add(" + ");
        }
        try kind.pushPlaceholder(&b, params.items.len);
        try params.append(gpa, field.value);
    }
    if (filter) |f| {
        if (!f.isEmpty()) {
            try b.add(" WHERE ");
            try f.renderInto(gpa, kind, &params, &b);
        }
    }

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 累加模式（对应 C# 累加字段 `Additional` 的三种口径）。
pub const Accumulate = enum {
    /// `col = col + ?`（求和 / 计数）
    add,
    /// `col = CASE WHEN col IS NULL OR col < ? THEN ? ELSE col END`（求最大值）
    max,
    /// `col = CASE WHEN col IS NULL OR col > ? THEN ? ELSE col END`（求最小值）
    min,
};

/// 一条累加字段：列名 + 增量 + 模式。
pub const AccumulateField = struct {
    name: []const u8,
    value: Value,
    mode: Accumulate = .add,
};

/// 组装累加 UPDATE：SQL 侧原子累加，避免「读-改-写」的并发丢更新。
///
/// 与 `update` 的差别只在 SET 子句：这里不把列置为参数值，而是在列自身基础上累加。
/// 三种模式都只用标准 SQL（`+` 与 `CASE WHEN`），SQLite / MySQL / SQL Server / PostgreSQL / Oracle 通用。
pub fn updateAccumulate(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    fields: []const AccumulateField,
    filter: ?*const Where,
) !Sql {
    if (fields.len == 0) return error.Model;

    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    try b.add("UPDATE ");
    try kind.pushQuoted(&b, table_name);
    try b.add(" SET ");
    for (fields, 0..) |field, index| {
        if (index > 0) try b.add(", ");
        const quoted = try kind.quoteAlloc(gpa, try columnName(table, field.name));
        defer gpa.free(quoted);
        try b.add(quoted);
        switch (field.mode) {
            .add => {
                try b.add(" = ");
                try b.add(quoted);
                try b.add(" + ");
                try kind.pushPlaceholder(&b, params.items.len);
                try params.append(gpa, field.value);
            },
            .max, .min => {
                try b.add(" = CASE WHEN ");
                try b.add(quoted);
                try b.add(" IS NULL OR ");
                try b.add(quoted);
                try b.add(if (field.mode == .max) " < " else " > ");
                try kind.pushPlaceholder(&b, params.items.len);
                try params.append(gpa, field.value);
                try b.add(" THEN ");
                try kind.pushPlaceholder(&b, params.items.len);
                try params.append(gpa, field.value);
                try b.add(" ELSE ");
                try b.add(quoted);
                try b.add(" END");
            },
        }
    }
    if (filter) |f| {
        if (!f.isEmpty()) {
            try b.add(" WHERE ");
            try f.renderInto(gpa, kind, &params, &b);
        }
    }

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 组装 DELETE。
pub fn delete(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table_name: []const u8,
    filter: ?*const Where,
) !Sql {
    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    try b.add("DELETE FROM ");
    try kind.pushQuoted(&b, table_name);
    if (filter) |f| {
        if (!f.isEmpty()) {
            try b.add(" WHERE ");
            try f.renderInto(gpa, kind, &params, &b);
        }
    }

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 组装 COUNT。
pub fn count(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table_name: []const u8,
    filter: ?*const Where,
) !Sql {
    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    try b.add("SELECT COUNT(*) FROM ");
    try kind.pushQuoted(&b, table_name);
    if (filter) |f| {
        if (!f.isEmpty()) {
            try b.add(" WHERE ");
            try f.renderInto(gpa, kind, &params, &b);
        }
    }

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 聚合函数（对应 C# `Entity.FindMax` / `FindMin` 这类「取一列的最值」需求）。
pub const AggFunc = enum {
    max,
    min,
    sum,
    avg,
    count,

    pub fn text(self: AggFunc) []const u8 {
        return switch (self) {
            .max => "MAX",
            .min => "MIN",
            .sum => "SUM",
            .avg => "AVG",
            .count => "COUNT",
        };
    }
};

/// 组装聚合查询：`SELECT MAX("col") FROM "t" WHERE ...`。
///
/// 与 C# 的差异（有意）：C# `FindMin/FindMax` 是「按该列排序取第 1 行，再把整行字段转 decimal」，
/// 空表返回 `0`；本仓直接发**聚合**语句 —— 只回一个值（不带整行）、空表回 `NULL`（调用方用 `?Value`
/// 区分「没有数据」和「值就是 0」，增量同步/取最新时间正是需要这个区分）。
///
/// `func == .count` 时忽略 `column`，生成 `COUNT(*)`；其余函数要求 `column` 在模型里存在
/// （外部传入的列名必须校验，否则就是注入面）。
pub fn aggregate(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    func: AggFunc,
    column: []const u8,
    filter: ?*const Where,
) !Sql {
    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    try b.add("SELECT ");
    try b.add(func.text());
    try b.add("(");
    if (func == .count) {
        try b.add("*");
    } else {
        const quoted = try kind.quoteAlloc(gpa, try columnName(table, column));
        defer gpa.free(quoted);
        try b.add(quoted);
    }
    try b.add(") FROM ");
    try kind.pushQuoted(&b, table_name);

    if (filter) |f| {
        if (!f.isEmpty()) {
            try b.add(" WHERE ");
            try f.renderInto(gpa, kind, &params, &b);
        }
    }

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 「至多 N 行」的计数：`min(实际行数, limit)`。///
/// 用于**恒定成本**地判定「这张表是否超过缓存上限」——不会像 `COUNT(*)` 那样扫全表，
/// 亿级表上也只读 `limit` 行。各方言尽量用子查询 + 行数限制实现。
pub fn countUpTo(gpa: std.mem.Allocator, kind: DatabaseKind, table_name: []const u8, limit: u64) !Sql {
    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);
    try params.append(gpa, .{ .int = @intCast(limit) });

    switch (kind) {
        .sqlserver => {
            // 没有 LIMIT，用 TOP(n) 包一层
            try b.add("SELECT COUNT(*) FROM (SELECT TOP (");
            try kind.pushPlaceholder(&b, 0);
            try b.add(") 1 AS zcode_x FROM ");
            try kind.pushQuoted(&b, table_name);
            try b.add(") AS zcode_t");
        },
        .oracle => {
            try b.add("SELECT COUNT(*) FROM (SELECT 1 FROM ");
            try kind.pushQuoted(&b, table_name);
            try b.add(" WHERE ROWNUM <= ");
            try kind.pushPlaceholder(&b, 0);
            try b.add(") zcode_t");
        },
        .sqlite, .mysql, .postgresql => {
            try b.add("SELECT COUNT(*) FROM (SELECT 1 FROM ");
            try kind.pushQuoted(&b, table_name);
            try b.add(" LIMIT ");
            try kind.pushPlaceholder(&b, 0);
            try b.add(") zcode_t");
        },
        else => return error.Unsupported,
    }

    const text = try b.toOwnedSlice();
    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 组装 SELECT（含排序、分页、取前 N 条）。
///
/// - `query.select` 中的列名会校验并引用；不是列名的内容按原始表达式使用（如 `COUNT(*)`）
/// - 分页：`page_index >= 1 && page_size > 0` 时启用
/// - 分页/取前 N/跳行场景未显式排序时，按主键兜底，保证结果稳定
/// JOIN 类型（对应 C# `SelectBuilder` 的 Join 语义）。
pub const JoinKind = enum { inner, left, right, full, cross, raw };

/// 一个 JOIN：表名 + 别名 + ON 条件。
///
/// `ON` 用**原始 SQL 片段**：多表关联条件里常有 `a.x = b.y AND b.z > ?`，
/// 交给调用方写比在这里再发明一套表达式 DSL 更直接（与 C# `SelectBuilder` 的 join 用法一致）。
/// 注意：`ON` 里的 `?` 会由调用方自己带参数（本函数的 `params` 只收 WHERE 的参数）。
pub const Join = struct {
    kind: JoinKind = .inner,
    /// 表名（原样输出，调用方需要时自己引用；分库场景直接给物理分表名）
    table: []const u8,
    /// 别名（空 = 不写）
    alias: []const u8 = "",
    /// ON 条件（`CROSS JOIN` 不需要）
    on: []const u8 = "",
};

/// 组装 SELECT（无 JOIN，等价于 `selectJoined(..., &.{}, ...)`）。
pub fn select(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    q: *const Query,
) !Sql {
    return selectImpl(gpa, kind, table, table_name, &.{}, q);
}

/// 组装带 JOIN 的 SELECT（含排序、分页、取前 N 条）。
///
/// 与 `select` 的差别只在 FROM 之后：按 `joins` 顺序拼 `JOIN ... ON ...`。
/// - 选列：本表列名会引用；带 `.` 的表达式（如 `u.Name`）原样保留，建议自己写 `AS` 别名；
/// - 排序：不是本表列名的内容（如 `u.Name`）原样保留；
/// - 分页/取前 N 无显式排序时，仍按**主表**主键兜底。
pub fn selectJoined(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    joins: []const Join,
    q: *const Query,
) !Sql {
    return selectImpl(gpa, kind, table, table_name, joins, q);
}

fn selectImpl(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
    joins: []const Join,
    q: *const Query,
) !Sql {
    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

    try b.add("SELECT ");
    if (q.select.items.len == 0) {
        try b.add("*");
    } else {
        for (q.select.items, 0..) |column_spec, index| {
            if (index > 0) try b.add(", ");
            if (table.column(column_spec)) |col| {
                try kind.pushQuoted(&b, table.effectiveColumnName(col));
            } else {
                try b.add(column_spec);
            }
        }
    }
    try b.add(" FROM ");
    try kind.pushQuoted(&b, table_name);

    // SQL Server 的行锁是**表提示**（`WITH (UPDLOCK, READPAST)`），必须跟在表名后；
    // 其它方言是句尾后缀（`FOR UPDATE SKIP LOCKED`），在后面统一拼。
    if (q.lock != .none and kind == .sqlserver) {
        switch (q.lock) {
            .update => try b.add(" WITH (UPDLOCK)"),
            .no_wait => try b.add(" WITH (UPDLOCK, NOWAIT)"),
            .skip_locked => try b.add(" WITH (UPDLOCK, READPAST)"),
            .none => {},
        }
    }

    // JOIN：顺序拼在 FROM 之后（ON 是原样片段，不做引用改写）
    for (joins) |j| {
        if (j.kind == .raw) {
            // C# `SelectBuilder.Join` 就是一个字符串：多表/特殊语法原样拼
            try b.add(" ");
            try b.add(j.table);
            continue;
        }
        try b.add(switch (j.kind) {
            .inner => " INNER JOIN ",
            .left => " LEFT JOIN ",
            .right => " RIGHT JOIN ",
            .full => " FULL JOIN ",
            .cross => " CROSS JOIN ",
            .raw => unreachable,
        });
        try b.add(j.table);
        if (j.alias.len > 0) {
            try b.add(" ");
            try b.add(j.alias);
        }
        if (j.kind != .cross and j.on.len > 0) {
            try b.add(" ON ");
            try b.add(j.on);
        }
    }

    if (q.filter) |f| {
        if (!f.isEmpty()) {
            try b.add(" WHERE ");
            try f.renderInto(gpa, kind, &params, &b);
        }
    }

    // 排序
    var order = Buf.init(gpa);
    defer order.deinit();
    try renderOrder(&order, kind, table, q.order_by.items);

    const paging = q.page_index >= 1 and q.page_size > 0;
    if (order.slice().len == 0 and (paging or q.limit != null or q.offset != null)) {
        try renderOrderOfPrimaryKeys(&order, kind, table);
    }

    var text: []u8 = undefined;
    if (paging) {
        const offset = (q.page_index - 1) * q.page_size;
        text = try kind.applyPagingAlloc(gpa, b.slice(), order.slice(), offset, q.page_size);
    } else if (q.offset) |offset| {
        const size = q.limit orelse std.math.maxInt(usize);
        text = try kind.applyPagingAlloc(gpa, b.slice(), order.slice(), offset, size);
    } else if (q.limit) |limit| {
        text = try kind.applyPagingAlloc(gpa, b.slice(), order.slice(), 0, limit);
    } else {
        if (order.slice().len > 0) {
            try b.add(" ");
            try b.add(order.slice());
        }
        text = try b.toOwnedSlice();
    }

    // 行锁后缀（SQL Server 已在表名列处理，其余方言在此追加）
    if (q.lock != .none and kind != .sqlserver) {
        const suffix: ?[]const u8 = switch (kind) {
            .sqlite => null, // SQLite 只有库级写锁，无法行锁
            .mysql, .postgresql, .oracle, .dameng => switch (q.lock) {
                .update => " FOR UPDATE",
                .no_wait => " FOR UPDATE NOWAIT",
                .skip_locked => " FOR UPDATE SKIP LOCKED",
                .none => null,
            },
            else => null,
        };
        if (suffix) |sfx| {
            const joined = try std.mem.concat(gpa, u8, &.{ text, sfx });
            gpa.free(text);
            text = joined;
        } else {
            gpa.free(text);
            return error.Unsupported;
        }
    }

    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
}

/// 排序串的两种用法（对应 C# `PageParameter.Sort` 与 `OrderBy`）。
pub const BuildOrderMode = enum {
    /// 结构化排序串：`Name desc, Code`，可带 `asc`/`desc` 后缀；没写方向时用 `default_desc`
    sort,
    /// 原样排序串：直接返回（C# 口径：`OrderBy` 优先且 `Desc` 不生效）
    order_by,
};

/// 把排序串解析成 `ORDER BY` 内容（**不含** `ORDER BY` 关键字）。
///
/// 直译 C# `SqlBuilder.BuildOrder`（用例见 `XUnitTest.XCode/Common/SqlBuilderTests.cs`）：
/// - 按 `,` 分段，`\n` / `\r` / `\t` / 空格都会清掉（前端常把多行塞进 `sort`）；
/// - 每段可带 `asc` / `desc` 后缀（忽略大小写）；**没写后缀时用 `default_desc`**
///   （`asc` 段不写后缀，`desc` 段写 ` Desc`）；
/// - 列名按表校验（忽略大小写），输出**模型里的规范列名**（`name` → `Name`）；
///   校验不过报 `error.UnknownSortField` 并打印「表 X 不包含排序字段 Y」——
///   绝不把用户输入原样拼进 SQL（这是注入面）。
///
/// 输出**不加引号**（与 C# 一致，方便直接拼进 ORDER BY）；要带引号请用 `Query.orderBy`。
pub fn buildOrderAlloc(
    gpa: std.mem.Allocator,
    table: *const TableMeta,
    spec: []const u8,
    default_desc: bool,
    mode: BuildOrderMode,
) ![]u8 {
    const trimmed = std.mem.trim(u8, spec, " \t\r\n");
    if (mode == .order_by or trimmed.len == 0) return gpa.dupe(u8, trimmed);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var it = std.mem.splitScalar(u8, trimmed, ',');
    var first = true;
    while (it.next()) |raw_item| {
        // 清掉换行/制表（C# 用 String.Trim 同理，但这里连内部换行也压掉）
        var item_buf: [256]u8 = undefined;
        var n: usize = 0;
        for (raw_item) |c| {
            if (c == '\n' or c == '\r' or c == '\t') continue;
            if (n >= item_buf.len) return error.NameTooLong;
            item_buf[n] = c;
            n += 1;
        }
        const item = std.mem.trim(u8, item_buf[0..n], " ");
        if (item.len == 0) continue;

        // 取方向后缀
        var name = item;
        var desc = default_desc;
        if (endsWithIgnoreCase(item, " desc")) {
            name = std.mem.trimEnd(u8, item[0 .. item.len - 5], " ");
            desc = true;
        } else if (endsWithIgnoreCase(item, " asc")) {
            name = std.mem.trimEnd(u8, item[0 .. item.len - 4], " ");
            desc = false;
        }
        if (name.len == 0) continue;

        // 按表校验并取规范列名（大小写不敏感）
        const col = table.column(name) orelse {
            std.debug.print(
                "[zcode] 排序字段非法：表 {s} 不包含字段 {s}（可用字段见模型；该串来自外部输入，已拒绝）\n",
                .{ table.effectiveTableName(), name },
            );
            return error.UnknownSortField;
        };

        if (!first) try out.append(gpa, ',');
        first = false;
        try out.appendSlice(gpa, col.name);
        if (desc) try out.appendSlice(gpa, " Desc");
    }
    return out.toOwnedSlice(gpa);
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

fn renderOrder(out: *Buf, kind: DatabaseKind, table: *const TableMeta, orders: []const query.OrderBy) !void {
    if (orders.len == 0) return;
    try out.add("ORDER BY ");
    for (orders, 0..) |order, index| {
        if (index > 0) try out.add(", ");
        if (table.column(order.column)) |col| {
            try kind.pushQuoted(out, table.effectiveColumnName(col));
        } else {
            try out.add(order.column);
        }
        if (order.desc) try out.add(" DESC");
    }
}

fn renderOrderOfPrimaryKeys(out: *Buf, kind: DatabaseKind, table: *const TableMeta) !void {
    var pk_index: usize = 0;
    for (table.columns) |*col| {
        if (!col.primary_key) continue;
        if (pk_index == 0) {
            try out.add("ORDER BY ");
        } else {
            try out.add(", ");
        }
        try kind.pushQuoted(out, table.effectiveColumnName(col));
        pk_index += 1;
    }
}

// ─────────────────────────────── 测试 ───────────────────────────────

fn testTable() TableMeta {
    return .{
        .name = "Order",
        .table_name = "DH_Order",
        .columns = &[_]ColumnMeta{
            .{ .name = "Id", .data_type = .int32, .identity = true, .primary_key = true },
            .{ .name = "Code", .data_type = .string, .length = 50 },
            .{ .name = "Status", .data_type = .int32 },
        },
    };
}

test "INSERT 文本与参数" {
    const a = std.testing.allocator;
    const t = testTable();
    const sql = try insert(a, .sqlite, &t, "DH_Order", &[_]Field{
        .{ .name = "Code", .value = .{ .text = "k-001" } },
        .{ .name = "Status", .value = .{ .int = 1 } },
    });
    defer sql.deinit(a);
    try std.testing.expectEqualStrings("INSERT INTO \"DH_Order\" (\"Code\", \"Status\") VALUES (?, ?)", sql.text);
    try std.testing.expectEqual(@as(usize, 2), sql.params.len);
}

test "INSERT 未知列报错" {
    const a = std.testing.allocator;
    const t = testTable();
    try std.testing.expectError(error.ColumnNotFound, insert(a, .sqlite, &t, "DH_Order", &[_]Field{
        .{ .name = "Nope", .value = .{ .int = 1 } },
    }));
}

test "UPDATE 与 WHERE" {
    const a = std.testing.allocator;
    const t = testTable();
    var w = Where.init(a);
    defer w.deinit();
    _ = try w.eq("Id", .{ .int = 7 });

    const sql = try update(a, .sqlite, &t, "DH_Order", &[_]Field{
        .{ .name = "Status", .value = .{ .int = 2 } },
    }, &w);
    defer sql.deinit(a);

    try std.testing.expectEqualStrings("UPDATE \"DH_Order\" SET \"Status\" = ? WHERE (\"Id\" = ?)", sql.text);
    try std.testing.expectEqual(@as(usize, 2), sql.params.len);
}

test "DELETE 无过滤时不带 WHERE" {
    const a = std.testing.allocator;
    const sql = try delete(a, .sqlite, "DH_Order", null);
    defer sql.deinit(a);
    try std.testing.expectEqualStrings("DELETE FROM \"DH_Order\"", sql.text);
}

test "COUNT 带条件" {
    const a = std.testing.allocator;
    var w = Where.init(a);
    defer w.deinit();
    _ = try w.like("Code", "a%");

    const sql = try count(a, .sqlite, "DH_Order", &w);
    defer sql.deinit(a);
    try std.testing.expectEqualStrings("SELECT COUNT(*) FROM \"DH_Order\" WHERE (\"Code\" LIKE ?)", sql.text);
}

test "SELECT 分页按主键兜底排序" {
    const a = std.testing.allocator;
    const t = testTable();
    var q = Query.init(a);
    defer q.deinit();
    _ = q.page(2, 10);

    const sql = try select(a, .sqlite, &t, "DH_Order", &q);
    defer sql.deinit(a);
    try std.testing.expectEqualStrings(
        "SELECT * FROM \"DH_Order\" ORDER BY \"Id\" LIMIT 10 OFFSET 10",
        sql.text,
    );
}

test "SELECT 指定列与降序" {
    const a = std.testing.allocator;
    const t = testTable();
    var q = Query.init(a);
    defer q.deinit();
    _ = try q.column("Code");
    _ = try q.column("Status");
    _ = try q.orderBy("Status", true);
    _ = q.take(5);

    const sql = try select(a, .sqlite, &t, "DH_Order", &q);
    defer sql.deinit(a);
    try std.testing.expectEqualStrings(
        "SELECT \"Code\", \"Status\" FROM \"DH_Order\" ORDER BY \"Status\" DESC LIMIT 5 OFFSET 0",
        sql.text,
    );
}

test "SELECT 表达式列原样输出" {
    const a = std.testing.allocator;
    const t = testTable();
    var q = Query.init(a);
    defer q.deinit();
    _ = try q.column("COUNT(*)");
    _ = q.take(1);

    const sql = try select(a, .sqlite, &t, "DH_Order", &q);
    defer sql.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, sql.text, "SELECT COUNT(*) FROM") != null);
}

test "多行 INSERT：占位符与参数按行展开" {
    const a = std.testing.allocator;
    const t = testTable();

    const rows = [_][]const Field{
        &.{ .{ .name = "Code", .value = .{ .text = "k1" } }, .{ .name = "Status", .value = .{ .int = 1 } } },
        &.{ .{ .name = "Code", .value = .{ .text = "k2" } }, .{ .name = "Status", .value = .{ .int = 2 } } },
    };
    const sql = try insertMulti(a, .sqlite, &t, "DH_Order", &rows);
    defer sql.deinit(a);

    try std.testing.expectEqualStrings(
        "INSERT INTO \"DH_Order\" (\"Code\", \"Status\") VALUES (?, ?), (?, ?)",
        sql.text,
    );
    try std.testing.expectEqual(@as(usize, 4), sql.params.len);

    // 列集合不一致必须报错
    const bad = [_][]const Field{
        &.{.{ .name = "Code", .value = .{ .text = "k1" } }},
        &.{.{ .name = "Status", .value = .{ .int = 2 } }},
    };
    try std.testing.expectError(error.Model, insertMulti(a, .sqlite, &t, "DH_Order", &bad));
}

test "SELECT WHERE + 排序（无分页）" {
    const a = std.testing.allocator;
    const t = testTable();
    var w = Where.init(a);
    defer w.deinit();
    _ = try w.eq("Status", .{ .int = 1 });

    var q = Query.init(a);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = try q.orderBy("Code", false);

    const sql = try select(a, .sqlite, &t, "DH_Order", &q);
    defer sql.deinit(a);
    try std.testing.expectEqualStrings(
        "SELECT * FROM \"DH_Order\" WHERE (\"Status\" = ?) ORDER BY \"Code\"",
        sql.text,
    );
}

test "显式插入自增列：SQL Server 包 IDENTITY_INSERT，PG 系加 OVERRIDING SYSTEM VALUE" {
    const a = std.testing.allocator;
    const t = testTable(); // Id 为自增主键

    const with_id = [_]Field{
        .{ .name = "Id", .value = .{ .int = 7 } },
        .{ .name = "Code", .value = .{ .text = "k1" } },
    };

    // SQL Server / SqlCe：必须包 SET IDENTITY_INSERT
    const ss = try insertWith(a, .sqlserver, &t, "DH_Order", &with_id, .{ .allow_identity = true });
    defer ss.deinit(a);
    try std.testing.expectEqualStrings(
        "SET IDENTITY_INSERT [DH_Order] ON;INSERT INTO [DH_Order] ([Id], [Code]) VALUES (@p0, @p1);SET IDENTITY_INSERT [DH_Order] OFF",
        ss.text,
    );

    // PG 系：DDL 是 GENERATED ALWAYS，显式给值必须 OVERRIDING SYSTEM VALUE
    const pg = try insertWith(a, .postgresql, &t, "DH_Order", &with_id, .{ .allow_identity = true });
    defer pg.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, pg.text, " OVERRIDING SYSTEM VALUE VALUES (") != null);

    // SQLite / MySQL：直接给值，不加任何包装
    const lite = try insertWith(a, .sqlite, &t, "DH_Order", &with_id, .{ .allow_identity = true });
    defer lite.deinit(a);
    try std.testing.expectEqualStrings("INSERT INTO \"DH_Order\" (\"Id\", \"Code\") VALUES (?, ?)", lite.text);

    // 没给自增列时，选项不产生任何包装（避免无谓的多语句）
    const no_id = [_]Field{.{ .name = "Code", .value = .{ .text = "k1" } }};
    const ss2 = try insertWith(a, .sqlserver, &t, "DH_Order", &no_id, .{ .allow_identity = true });
    defer ss2.deinit(a);
    try std.testing.expectEqualStrings("INSERT INTO [DH_Order] ([Code]) VALUES (@p0)", ss2.text);

    // 默认选项（allow_identity = false）保持旧行为：SQL Server 不包
    const ss3 = try insert(a, .sqlserver, &t, "DH_Order", &with_id);
    defer ss3.deinit(a);
    try std.testing.expectEqualStrings("INSERT INTO [DH_Order] ([Id], [Code]) VALUES (@p0, @p1)", ss3.text);

    // 多行批量插入同样要处理（导入走的是批量路径，不是逐条 insert）
    const row2 = [_]Field{
        .{ .name = "Id", .value = .{ .int = 8 } },
        .{ .name = "Code", .value = .{ .text = "k2" } },
    };
    const batch = [_][]const Field{ &with_id, &row2 };
    const ss_batch = try insertMultiWith(a, .sqlserver, &t, "DH_Order", &batch, .{ .allow_identity = true });
    defer ss_batch.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, ss_batch.text, "SET IDENTITY_INSERT [DH_Order] ON;INSERT INTO [DH_Order] ([Id], [Code]) VALUES "));
    try std.testing.expect(std.mem.endsWith(u8, ss_batch.text, ");SET IDENTITY_INSERT [DH_Order] OFF"));

    const pg_batch = try insertMultiWith(a, .postgresql, &t, "DH_Order", &batch, .{ .allow_identity = true });
    defer pg_batch.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, pg_batch.text, " OVERRIDING SYSTEM VALUE VALUES ") != null);
}

test "聚合查询：MAX/MIN 带条件；COUNT(*) 忽略列；未知列报错" {
    const a = std.testing.allocator;
    const t = testTable();

    var w = Where.init(a);
    defer w.deinit();
    _ = try w.eq("Status", .{ .int = 1 });

    const mx = try aggregate(a, .sqlite, &t, "DH_Order", .max, "Code", &w);
    defer mx.deinit(a);
    try std.testing.expectEqualStrings("SELECT MAX(\"Code\") FROM \"DH_Order\" WHERE (\"Status\" = ?)", mx.text);
    try std.testing.expectEqual(@as(usize, 1), mx.params.len);

    // 不同方言的引用风格
    const mx_ss = try aggregate(a, .sqlserver, &t, "DH_Order", .min, "Code", null);
    defer mx_ss.deinit(a);
    try std.testing.expectEqualStrings("SELECT MIN([Code]) FROM [DH_Order]", mx_ss.text);

    // COUNT 不看列名（列名传空也行）
    const cnt = try aggregate(a, .postgresql, &t, "DH_Order", .count, "", null);
    defer cnt.deinit(a);
    try std.testing.expectEqualStrings("SELECT COUNT(*) FROM \"DH_Order\"", cnt.text);

    // 外部传入的列名必须按模型校验
    try std.testing.expectError(error.ColumnNotFound, aggregate(a, .sqlite, &t, "DH_Order", .max, "nope", null));
}

// ── JOIN（对应 C# `SelectBuilder` 的 join 能力）─────────────────────────────
test "SELECT JOIN：INNER/LEFT + 别名 + ON + WHERE + 排序" {
    const a = std.testing.allocator;
    const t = testTable();

    var w = Where.init(a);
    defer w.deinit();
    _ = try w.eq("Status", .{ .int = 1 });

    var q = Query.init(a);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = try q.column("u.Name AS UserName");
    _ = try q.orderBy("u.Name", false);

    const joins = [_]Join{
        .{ .kind = .inner, .table = "DH_User", .alias = "u", .on = "u.Id = DH_Order.UserId" },
        .{ .kind = .left, .table = "DH_Shop", .alias = "s", .on = "s.Id = DH_Order.ShopId" },
    };

    const sql = try selectJoined(a, .sqlite, &t, "DH_Order", &joins, &q);
    defer sql.deinit(a);
    try std.testing.expectEqualStrings(
        "SELECT u.Name AS UserName FROM \"DH_Order\"" ++
            " INNER JOIN DH_User u ON u.Id = DH_Order.UserId" ++
            " LEFT JOIN DH_Shop s ON s.Id = DH_Order.ShopId" ++
            " WHERE (\"Status\" = ?) ORDER BY u.Name",
        sql.text,
    );
    // WHERE 的参数照常收集（JOIN 的 ON 片段由调用方自己带参）
    try std.testing.expectEqual(@as(usize, 1), sql.params.len);
}

test "SELECT JOIN：CROSS 不写 ON；无排序分页时仍按主表主键兜底" {
    const a = std.testing.allocator;
    const t = testTable();

    var q = Query.init(a);
    defer q.deinit();
    _ = q.page(3, 20);

    const joins = [_]Join{.{ .kind = .cross, .table = "DH_Type", .on = "s.ignored = 1" }};

    const sql = try selectJoined(a, .sqlite, &t, "DH_Order", &joins, &q);
    defer sql.deinit(a);
    // CROSS JOIN 不输出 ON；ORDER BY 用主表主键（"Id"）；分页参数正确
    try std.testing.expectEqualStrings(
        "SELECT * FROM \"DH_Order\" CROSS JOIN DH_Type ORDER BY \"Id\" LIMIT 20 OFFSET 40",
        sql.text,
    );
}

test "SELECT JOIN：SQL Server 行锁提示仍在主表后，JOIN 顺延" {
    const a = std.testing.allocator;
    const t = testTable();

    var q = Query.init(a);
    defer q.deinit();
    _ = q.take(5);
    q.lock = .skip_locked;

    const joins = [_]Join{.{ .kind = .inner, .table = "DH_User", .alias = "u", .on = "u.Id = DH_Order.UserId" }};

    const sql = try selectJoined(a, .sqlserver, &t, "DH_Order", &joins, &q);
    defer sql.deinit(a);
    // 表提示紧跟主表（`[DH_Order] WITH (...)`），JOIN 在其后
    try std.testing.expect(std.mem.indexOf(u8, sql.text, "[DH_Order] WITH (UPDLOCK, READPAST) INNER JOIN DH_User u ON u.Id = DH_Order.UserId") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql.text, "TOP 5") != null or std.mem.indexOf(u8, sql.text, "FETCH NEXT 5 ROWS ONLY") != null);
}
