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
    if (fields.len == 0) return error.Model;

    var b = Buf.init(gpa);
    defer b.deinit();

    var params: std.ArrayList(Value) = .empty;
    errdefer params.deinit(gpa);

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
            var provided = false;
            for (fields) |f| {
                if (std.ascii.eqlIgnoreCase(f.name, identity.name)) provided = true;
            }
            if (!provided) {
                try b.add(", ");
                try kind.pushQuoted(&b, table.effectiveColumnName(identity));
                sequence_identity = identity;
            }
        }
    }

    try b.add(") VALUES (");
    for (fields, 0..) |field, index| {
        if (index > 0) try b.add(", ");
        try kind.pushPlaceholder(&b, index);
        try params.append(gpa, field.value);
    }
    if (sequence_identity != null) {
        try b.fmt(", \"SEQ_{s}\".NEXTVAL", .{table_name});
    }
    try b.add(")");

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

    try b.add("INSERT INTO ");
    try kind.pushQuoted(&b, table_name);
    try b.add(" (");
    for (rows[0], 0..) |field, index| {
        if (index > 0) try b.add(", ");
        try kind.pushQuoted(&b, try columnName(table, field.name));
    }
    try b.add(") VALUES ");

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

/// 组装 SELECT（含排序、分页、取前 N 条）。
///
/// - `query.select` 中的列名会校验并引用；不是列名的内容按原始表达式使用（如 `COUNT(*)`）
/// - 分页：`page_index >= 1 && page_size > 0` 时启用
/// - 分页/取前 N/跳行场景未显式排序时，按主键兜底，保证结果稳定
pub fn select(
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    table_name: []const u8,
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

    return .{ .text = text, .params = try params.toOwnedSlice(gpa) };
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
