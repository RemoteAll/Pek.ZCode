//! 对象实体（对应 DH.NCode `Entity` / Rust `Pek.RCode/src/entity.rs` 的第一轮子集）。
//!
//! 设计取舍：Zig 没有运行时反射，因此实体由 `zcodegen` 按 `Model.xml` **生成**，
//! 生成结构体满足下面的「实体契约」，本模块用 comptime 鸭子类型实现通用操作：
//!
//! ```zig
//! pub const meta: zcode.entity.EntityMeta = .{ .name = "JiLiYu", .table_name = "DH_JiLiYu", .fields = &.{ ... } };
//! dirty: zcode.entity.DirtyBits = 0,                 // 脏列位图（最多 256 列）
//! pub fn columnValue(self: @This(), i: usize) zcode.Value
//! pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void   // 装载用，**不置脏**
//! ```
//!
//! 语义对齐 Rust 版：
//! - `update` 只写**变化列**；没有变化列时**不发 SQL**、返回 0；
//! - `insert` 跳过自增列，插入成功后把自增 ID 回写到实体；
//! - `save`：自增列还是 0/空 → insert，否则按主键 update；
//! - `insert_only` 表禁止 update/delete（C# `InsertOnly`）；
//! - 视图表禁止写（C# `IsView`）。
//!
//! 内存约定：`columnValue` 返回的字符串/二进制是**借用**，由调用方保证生命周期
//! （查询出来的实体指向会话 arena，`Session.resetResults()` 后失效）。

const std = @import("std");
const model = @import("model.zig");
const TableMeta = model.TableMeta;
const DataType = model.DataType;
const Value = @import("zzig").db.Value;
const sqlbuild = @import("sqlbuild.zig");
const query = @import("query.zig");
const Where = query.Where;
const Query = query.Query;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const dal_mod = @import("dal.zig");
const Dal = dal_mod.Dal;

/// 单表实体支持的最大列数（脏位图宽度）。
pub const max_fields = 256;

/// 脏列位图。
pub const DirtyBits = u256;

pub const FieldMeta = struct {
    /// 物理列名（与 `Model.xml` 的 `Name`/`ColumnName` 一致）
    name: []const u8,
    data_type: DataType,
    primary_key: bool = false,
    identity: bool = false,
};

pub const EntityMeta = struct {
    /// 实体名（`Model.xml` 的 `Table@Name`）
    name: []const u8,
    /// 物理表名（`Model.xml` 的 `Table@TableName`，缺省同 `name`）
    table_name: []const u8,
    fields: []const FieldMeta,
};

pub fn markDirty(bits: *DirtyBits, index: usize) void {
    bits.* |= (@as(DirtyBits, 1) << @intCast(index));
}

pub fn isDirty(bits: DirtyBits, index: usize) bool {
    return (bits & (@as(DirtyBits, 1) << @intCast(index))) != 0;
}

fn fieldIndex(meta: EntityMeta, name: []const u8) ?usize {
    for (meta.fields, 0..) |f, i| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) return i;
    }
    return null;
}

fn tableOf(dal: *Dal, meta: EntityMeta) !*const TableMeta {
    const t = dal.model.table(meta.table_name) orelse return error.TableNotFound;
    return t;
}

fn effectiveName(t: *const TableMeta, field_name: []const u8) []const u8 {
    const col = t.column(field_name) orelse return field_name;
    return t.effectiveColumnName(col);
}

fn assertWritable(t: *const TableMeta) !void {
    if (t.is_view) return error.ReadOnly;
}

/// 插入一行（跳过自增列），成功后把自增 ID 回写到实体并清脏。
pub fn insert(dal: *Dal, e: anytype, s: *Session) !i64 {
    const T = @TypeOf(e.*);
    const meta = T.meta;
    const t = try tableOf(dal, meta);
    try assertWritable(t);

    const gpa = dal.gpa;
    var fields: std.ArrayList(sqlbuild.Field) = .empty;
    defer fields.deinit(gpa);

    for (meta.fields, 0..) |f, i| {
        if (f.identity) continue;
        try fields.append(gpa, .{ .name = effectiveName(t, f.name), .value = e.columnValue(i) });
    }

    const ref = try dal.table(meta.table_name);
    const id = try ref.insert(s, fields.items);

    if (t.identity()) |identity| {
        if (fieldIndex(meta, identity.name)) |idx| {
            try e.setColumnValue(idx, .{ .int = id });
        }
    }
    e.dirty = 0;
    return id;
}

/// 只更新脏列；无脏列时**不发 SQL**、返回 0。
pub fn update(dal: *Dal, e: anytype, s: *Session) !usize {
    const T = @TypeOf(e.*);
    const meta = T.meta;
    const t = try tableOf(dal, meta);
    try assertWritable(t);
    if (t.insert_only) return error.ReadOnly;

    if (e.dirty == 0) return 0;

    const gpa = dal.gpa;
    var sets: std.ArrayList(sqlbuild.Field) = .empty;
    defer sets.deinit(gpa);

    var w = Where.init(gpa);
    defer w.deinit();

    var pk_count: usize = 0;
    for (meta.fields, 0..) |f, i| {
        if (f.primary_key) {
            _ = try w.eq(effectiveName(t, f.name), e.columnValue(i));
            pk_count += 1;
        } else if (isDirty(e.dirty, i)) {
            try sets.append(gpa, .{ .name = effectiveName(t, f.name), .value = e.columnValue(i) });
        }
    }
    if (pk_count == 0) return error.NoPrimaryKey;
    if (sets.items.len == 0) {
        // 只改了主键列（不允许）：按无变化处理，保持「无修改不发 SQL」
        e.dirty = 0;
        return 0;
    }

    const ref = try dal.table(meta.table_name);
    const affected = try ref.update(s, sets.items, &w);
    e.dirty = 0;
    return affected;
}

/// 保存：自增列为 0/空 → 插入；否则按主键更新（对齐 XCode `Save`）。
pub fn save(dal: *Dal, e: anytype, s: *Session) !i64 {
    const T = @TypeOf(e.*);
    const meta = T.meta;
    const t = try tableOf(dal, meta);

    if (t.insert_only) return insert(dal, e, s);

    if (t.identity()) |identity| {
        const idx = fieldIndex(meta, identity.name) orelse return insert(dal, e, s);
        const v = e.columnValue(idx);
        const is_new = switch (v) {
            .null => true,
            .int => |n| n == 0,
            else => false,
        };
        if (is_new) return insert(dal, e, s);
    } else if (countPkValues(meta, e) == 0) {
        return insert(dal, e, s);
    }

    _ = try update(dal, e, s);
    return pkToI64(meta, e);
}

fn countPkValues(meta: EntityMeta, e: anytype) usize {
    var n: usize = 0;
    for (meta.fields, 0..) |f, i| {
        if (!f.primary_key) continue;
        const v = e.columnValue(i);
        if (!v.isNull()) n += 1;
    }
    return n;
}

fn pkToI64(meta: EntityMeta, e: anytype) i64 {
    for (meta.fields, 0..) |f, i| {
        if (!f.primary_key) continue;
        if (e.columnValue(i).asI64()) |v| return v;
    }
    return 0;
}

/// 按主键删除。
pub fn delete(dal: *Dal, e: anytype, s: *Session) !usize {
    const T = @TypeOf(e.*);
    const meta = T.meta;
    const t = try tableOf(dal, meta);
    try assertWritable(t);
    if (t.insert_only) return error.ReadOnly;

    var w = try pkWhere(dal.gpa, t, meta, e);
    defer w.deinit();

    const ref = try dal.table(meta.table_name);
    return ref.delete(s, &w);
}

/// 按主键取一行并装载到实体。
pub fn findByPk(dal: *Dal, comptime T: type, s: *Session, pk_values: []const Value) !?T {
    const ref = try dal.table(T.meta.table_name);
    const row = (try ref.findByPk(s, pk_values)) orelse return null;
    return try fromRow(T, row);
}

/// 条件查询（分页/排序/列选择同 `Query`）。
pub fn queryRows(dal: *Dal, comptime T: type, s: *Session, q: *const Query) ![]T {
    const ref = try dal.table(T.meta.table_name);
    const rows = try ref.queryRows(s, q);
    const arena = s.resultAllocator();
    var out: std.ArrayList(T) = .empty;
    try out.ensureTotalCapacity(arena, rows.len);
    for (rows) |row| out.appendAssumeCapacity(try fromRow(T, row));
    return out.toOwnedSlice(arena);
}

/// 计数。
pub fn count(dal: *Dal, comptime T: type, s: *Session, filter: ?*const Where) !i64 {
    const ref = try dal.table(T.meta.table_name);
    return ref.count(s, filter);
}

/// 行 → 实体（按列名匹配，装载不置脏）。
pub fn fromRow(comptime T: type, row: session_mod.Row) !T {
    var e = T{};
    for (row.names, 0..) |name, i| {
        const idx = fieldIndex(T.meta, name) orelse continue;
        try e.setColumnValue(idx, row.values[i]);
    }
    e.dirty = 0;
    return e;
}

fn pkWhere(gpa: std.mem.Allocator, t: *const TableMeta, meta: EntityMeta, e: anytype) !Where {
    var w = Where.init(gpa);
    errdefer w.deinit();
    var n: usize = 0;
    for (meta.fields, 0..) |f, i| {
        if (!f.primary_key) continue;
        _ = try w.eq(effectiveName(t, f.name), e.columnValue(i));
        n += 1;
    }
    if (n == 0) return error.NoPrimaryKey;
    return w;
}
