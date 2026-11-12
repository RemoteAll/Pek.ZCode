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
const SaveModes = @import("setting.zig").SaveModes;
const Value = @import("zzig").db.Value;
const sqlbuild = @import("sqlbuild.zig");
/// 凑批队列（`SaveAsync` 走它，对齐 C# `Entity.SaveAsync` → `EntityQueue.Add`）
const entity_queue = @import("entity_queue.zig");
const clock = @import("clock.zig");
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
    /// 模型里的逻辑列名（`Model.xml` 的 `Column@Name`）
    name: []const u8,
    data_type: DataType,
    primary_key: bool = false,
    identity: bool = false,
    /// 物理列名（`Column@ColumnName`；为空表示与 `name` 相同）
    column_name: ?[]const u8 = null,
    /// 是否允许 NULL（`Column@Nullable`）
    nullable: bool = false,
    /// 累加字段（`Column@Additional`）：更新时按 `col = col + 值` 累加
    additional: bool = false,
    length: i32 = 0,
    precision: i32 = 0,
    scale: i32 = 0,
    /// 列注释（生成代码里同时作为文档注释）
    description: []const u8 = "",

    /// 物理列名（`ColumnName` 缺省等于 `name`）。
    pub fn effectiveName(self: FieldMeta) []const u8 {
        if (self.column_name) |c| {
            if (c.len > 0) return c;
        }
        return self.name;
    }
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
            // `Column@Additional` → 累加（`col = col + ?`），不是整值覆盖
            try sets.append(gpa, .{
                .name = effectiveName(t, f.name),
                .value = e.columnValue(i),
                .accumulate = f.additional,
            });
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

    if (isNewEntity(meta, t, e)) return insert(dal, e, s);

    _ = try update(dal, e, s);
    return pkToI64(meta, e);
}

/// 是否“新实体”：`insert_only` 表恒为是；有自增列看它是否为 0/空；否则看主键是否为空。
fn isNewEntity(meta: EntityMeta, t: *const TableMeta, e: anytype) bool {
    if (t.insert_only) return true;
    if (t.identity()) |identity| {
        const idx = fieldIndex(meta, identity.name) orelse return true;
        const v = e.columnValue(idx);
        return switch (v) {
            .null => true,
            .int => |n| n == 0,
            else => false,
        };
    }
    return countPkValues(meta, e) == 0;
}

pub const SaveBatchReport = struct {
    /// 批量插入的行数（新增合并成多行 VALUES）
    inserted: usize = 0,
    /// 逐条更新且确有变化的实体数
    updated: usize = 0,
    /// 逐条更新但无脏列（未发 SQL）的实体数
    unchanged: usize = 0,
};

/// 批量保存（对齐 C# `EntityExtension.Save(list)` / Rust `save_batch`）：
/// 新增行合并为多行 INSERT（按方言参数上限分批），已存在行按脏列逐条更新。
///
/// 注意：批量插入**不回写每个实体的自增 ID**（只有最后一条可由 `lastInsertId` 得到）。
pub fn saveBatch(dal: *Dal, comptime T: type, entities: []const *T, s: *Session) !SaveBatchReport {
    return saveBatchWith(dal, T, entities, s, .insert);
}

/// 批量保存（可指定 `SaveModes`）：
/// - `insert`：多行 `INSERT`（原来 `saveBatch` 的行为）
/// - `upsert` / `insert_ignore` / `replace`：交给表级 `upsertBatch`，按方言生成
///   `ON CONFLICT` / `ON DUPLICATE KEY` / `OR REPLACE` 等（SQL Server 等退化为同事务逐行先改后插）
///
/// 已存在实体（主键非 0）仍走脏列逐条 `update`——这是 C# `IList.Update()` 的语义：
/// 只写脏列，不整行覆盖。
pub fn saveBatchWith(dal: *Dal, comptime T: type, entities: []const *T, s: *Session, mode: SaveModes) !SaveBatchReport {
    const meta = T.meta;
    const t = try tableOf(dal, meta);
    try assertWritable(t);

    const gpa = dal.gpa;
    var new_rows: std.ArrayList([]const sqlbuild.Field) = .empty;
    defer {
        for (new_rows.items) |r| gpa.free(r);
        new_rows.deinit(gpa);
    }

    var report = SaveBatchReport{};
    for (entities) |e| {
        if (isNewEntity(meta, t, e)) {
            var field_count: usize = 0;
            for (meta.fields) |f| {
                if (!f.identity) field_count += 1;
            }
            const fields = try gpa.alloc(sqlbuild.Field, field_count);
            var i: usize = 0;
            for (meta.fields, 0..) |f, idx| {
                if (f.identity) continue;
                fields[i] = .{ .name = effectiveName(t, f.name), .value = e.columnValue(idx) };
                i += 1;
            }
            try new_rows.append(gpa, fields);
            e.dirty = 0;
        } else {
            if (try update(dal, e, s) > 0) {
                report.updated += 1;
            } else {
                report.unchanged += 1;
            }
        }
    }

    if (new_rows.items.len > 0) {
        const ref = try dal.table(meta.table_name);
        report.inserted = try ref.upsertBatch(s, new_rows.items, mode);
    }
    return report;
}

/// 异步保存（对齐 C# `Entity.SaveAsync(msDelay)`）：**入凑批队列**，不是一调一线程。
///
/// - `ms_delay == 0` → 近实时桶，下一次队列 tick（默认 1000ms）就写；
/// - `ms_delay > 0`  → 延迟桶，到点才写；
/// - 队列按表**合并成多行 INSERT**（新增）+ 逐条脏列更新（已存在）。
///
/// 实体被**拷贝**到堆上，调用后可以立即修改/释放原对象。
/// 会话由队列按 `Model.xml` 的表归属连接新开，不共用调用方的 `Session`。
/// 进程退出前调 `entity_queue.stopGlobal()`（并确保在 `Dal` 释放前）把剩余项写完。
pub fn saveAsync(gpa: std.mem.Allocator, dal: *Dal, e: anytype, ms_delay: u64) !void {
    return saveAsyncInner(gpa, dal, e, ms_delay, null);
}

/// 带分片键的异步保存：入队时带上分片键，`flush` 时才能**按分片目标归组**，
/// 同分片合并成一条多行 INSERT（分表分库的性能关键）。
/// 分片键只支持 `datetime` / `int`（时间分片就是时间列）。
pub fn saveAsyncSharded(gpa: std.mem.Allocator, dal: *Dal, e: anytype, ms_delay: u64, shard_value: Value) !void {
    return saveAsyncInner(gpa, dal, e, ms_delay, shard_value);
}

fn saveAsyncInner(gpa: std.mem.Allocator, dal: *Dal, e: anytype, ms_delay: u64, shard_value: ?Value) !void {
    const T = @TypeOf(e.*);
    const copy = try gpa.create(T);
    copy.* = e.*;

    // 新实体（主键空/0）：给一个“建行字段”回调，让队列能合并成多行 INSERT
    const is_new = blk: {
        var n: usize = 0;
        inline for (T.meta.fields, 0..) |f, i| {
            if (f.primary_key and !e.columnValue(i).isNull()) {
                const v = e.columnValue(i);
                if (!(v == .int and v.int == 0)) n += 1;
            }
        }
        break :blk n == 0;
    };

    const q = try entity_queue.globalFor(gpa, dal);
    try q.enqueue(.{
        .ctx = copy,
        .base_table = T.meta.table_name,
        .conn = try dal.tableConnName(T.meta.table_name),
        .table_name = T.meta.table_name,
        .shard_value = shard_value,
        .due_ms = clock.nowMs() + @as(i64, @intCast(ms_delay)),
        .fieldsFn = if (is_new) struct {
            fn build(ctx: *anyopaque, a: std.mem.Allocator) anyerror![]sqlbuild.Field {
                const p: *T = @ptrCast(@alignCast(ctx));
                var field_count: usize = 0;
                inline for (T.meta.fields) |f| {
                    if (!f.identity) field_count += 1;
                }
                const out = try a.alloc(sqlbuild.Field, field_count);
                var i: usize = 0;
                inline for (T.meta.fields, 0..) |f, idx| {
                    if (f.identity) continue;
                    out[i] = .{ .name = f.name, .value = p.columnValue(idx) };
                    i += 1;
                }
                return out;
            }
        }.build else null,
        .saveFn = struct {
            fn saveOne(ctx: *anyopaque, dal2: *Dal, s: *Session) anyerror!void {
                const p: *T = @ptrCast(@alignCast(ctx));
                _ = save(dal2, p, s) catch |err| return err;
            }
        }.saveOne,
        .destroyFn = struct {
            fn destroy(ctx: *anyopaque, a: std.mem.Allocator) void {
                const p: *T = @ptrCast(@alignCast(ctx));
                a.destroy(p);
            }
        }.destroy,
    });
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
