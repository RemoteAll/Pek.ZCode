//! 表级操作（对应 DH.NCode `EntitySession` / Rust `TableRef`）。
//!
//! 提供：`insert` / `update` / `delete` / `findByPk` / `query` / `count`。
//! SQL 一律经 `sqlbuild` 组装、`session` 参数绑定执行；本层只负责
//! 「按 `Model.xml` 列类型规整读取值」与主键推导。
//!
//! 第一轮不含：对象实体、脏字段更新、整表缓存、批量写、分表（见 docs/移植对照）。

const std = @import("std");
const model = @import("model.zig");
const TableMeta = model.TableMeta;
const ColumnMeta = model.ColumnMeta;
const Value = @import("value.zig").Value;
const DatabaseKind = @import("dialect.zig").DatabaseKind;
const sqlbuild = @import("sqlbuild.zig");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Row = session_mod.Row;
const query = @import("query.zig");
const Where = query.Where;
const Query = query.Query;
const DateTime = @import("datetime.zig").DateTime;

pub const TableRef = struct {
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    /// 物理表名（分表场景由调用方传入具体表名）
    table_name: []const u8,

    pub fn init(gpa: std.mem.Allocator, kind: DatabaseKind, table: *const TableMeta) TableRef {
        return .{ .gpa = gpa, .kind = kind, .table = table, .table_name = table.effectiveTableName() };
    }

    /// 插入一行，返回自增 ID（无自增列返回 0）。
    pub fn insert(self: *const TableRef, s: *Session, fields: []const sqlbuild.Field) !i64 {
        try self.ensureWritable();
        const sql = try sqlbuild.insert(self.gpa, self.kind, self.table, self.table_name, fields);
        defer sql.deinit(self.gpa);
        _ = try s.execute(sql.text, sql.params);
        if (self.table.identity() != null) return s.lastInsertId();
        return 0;
    }

    /// 更新（`filter` 为空即全表——调用方必须自己保证带上主键条件）。
    pub fn update(self: *const TableRef, s: *Session, sets: []const sqlbuild.Field, filter: ?*const Where) !usize {
        try self.ensureWritable();
        const sql = try sqlbuild.update(self.gpa, self.kind, self.table, self.table_name, sets, filter);
        defer sql.deinit(self.gpa);
        return try s.execute(sql.text, sql.params);
    }

    /// 删除（同样：`filter` 为空即清空全表，慎用）。
    pub fn delete(self: *const TableRef, s: *Session, filter: ?*const Where) !usize {
        try self.ensureWritable();
        const sql = try sqlbuild.delete(self.gpa, self.kind, self.table_name, filter);
        defer sql.deinit(self.gpa);
        return try s.execute(sql.text, sql.params);
    }

    /// 计数。
    pub fn count(self: *const TableRef, s: *Session, filter: ?*const Where) !i64 {
        const sql = try sqlbuild.count(self.gpa, self.kind, self.table_name, filter);
        defer sql.deinit(self.gpa);
        const v = try s.queryScalar(sql.text, sql.params);
        if (v) |value| return value.asI64() orelse 0;
        return 0;
    }

    /// 查询（行集按模型列类型规整）。
    pub fn queryRows(self: *const TableRef, s: *Session, q: *const Query) ![]Row {
        const sql = try sqlbuild.select(self.gpa, self.kind, self.table, self.table_name, q);
        defer sql.deinit(self.gpa);
        const raw = try s.queryRows(sql.text, sql.params);
        return self.normalizeRows(s, raw);
    }

    /// 按主键取一行。
    pub fn findByPk(self: *const TableRef, s: *Session, pk_values: []const Value) !?Row {
        var w = Where.init(self.gpa);
        defer w.deinit();

        const pks = try self.table.primaryKeys(self.gpa);
        defer self.gpa.free(pks);
        if (pks.len == 0) return error.NoPrimaryKey;
        if (pks.len != pk_values.len) return error.Model;

        for (pks, 0..) |pk, i| {
            _ = try w.eq(self.table.effectiveColumnName(pk), pk_values[i]);
        }

        var q = Query.init(self.gpa);
        defer q.deinit();
        _ = q.filterWhere(&w).take(1);

        const rows = try self.queryRows(s, &q);
        if (rows.len == 0) return null;
        return rows[0];
    }

    /// 按模型列类型规整值：读到的时间/小数/布尔都转成规范表示。
    fn normalizeRows(self: *const TableRef, s: *Session, raw: []const Row) ![]Row {
        const arena = s.resultAllocator();
        var out: std.ArrayList(Row) = .empty;
        try out.ensureTotalCapacity(arena, raw.len);

        for (raw) |row| {
            var values: std.ArrayList(Value) = .empty;
            try values.ensureTotalCapacity(arena, row.values.len);
            for (row.names, 0..) |name, i| {
                const raw_value = row.values[i];
                const col = self.table.column(name);
                values.appendAssumeCapacity(if (col) |c| try normalizeValue(arena, c.data_type, raw_value, self.table.effectiveColumnName(c)) else raw_value);
            }
            out.appendAssumeCapacity(.{ .names = row.names, .values = try values.toOwnedSlice(arena) });
        }
        return out.toOwnedSlice(arena);
    }

    fn ensureWritable(self: *const TableRef) !void {
        if (self.table.is_view) return error.ReadOnly;
    }
};

/// 把驱动读到的值按模型列类型规整；无法转换时保留原值（不丢数据）。
fn normalizeValue(arena: std.mem.Allocator, data_type: model.DataType, raw: Value, column_name: []const u8) !Value {
    _ = column_name;
    return switch (data_type) {
        .boolean => if (raw.asBool()) |v| .{ .boolean = v } else raw,
        .byte, .int16, .int32, .int64 => if (raw.asI64()) |v| .{ .int = v } else raw,
        .single, .double => if (raw.asF64()) |v| .{ .float = v } else raw,
        .decimal => if (raw.asDecimal()) |v| .{ .decimal = v } else raw,
        .datetime => if (raw.asDatetime()) |v| .{ .datetime = v } else raw,
        .string, .json => switch (raw) {
            .text => raw,
            .null => raw,
            else => blk: {
                const text = try raw.toTextAlloc(arena);
                break :blk .{ .text = text };
            },
        },
        .binary => switch (raw) {
            .blob, .null => raw,
            else => blk: {
                const text = try raw.toTextAlloc(arena);
                break :blk .{ .text = text };
            },
        },
    };
}

/// 构造字段列表的便捷函数（配合 `insert` / `update` 使用）。
pub fn field(name: []const u8, value: Value) sqlbuild.Field {
    return .{ .name = name, .value = value };
}

/// 当前时间（拦截器/业务写入字段用）。
pub fn now() DateTime {
    return DateTime.nowLocal();
}

test "规整时间与布尔" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const dt = try normalizeValue(arena.allocator(), .datetime, .{ .text = "2026-09-26 18:01:02.1230000" }, "CreateTime");
    try std.testing.expect(dt == .datetime);

    const ok = try normalizeValue(arena.allocator(), .boolean, .{ .int = 1 }, "Ok");
    try std.testing.expect(ok.boolean);
}
