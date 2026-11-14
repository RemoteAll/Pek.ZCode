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
const dbtable_mod = @import("dbtable.zig");
const TableRef = dbtable_mod.TableRef;
const shards = @import("shards.zig");
const keyed_lock = @import("keyed_lock.zig");

/// 单表实体支持的最大列数（脏位图宽度）。
pub const max_fields = 256;

/// 脏列位图。
pub const DirtyBits = u256;

/// 两个字段值是否相等（生成代码的 setter 用它做「未改不置脏」）。
///
/// - 字符串（`[]const u8`）比**内容**（切片直接 `==` 只比 ptr+len，会误判）；
/// - 结构体（`DateTime` / `Decimal`）与标量走 `std.meta.eql`。
pub fn valueEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (comptime T == []const u8) return std.mem.eql(u8, a, b);
    return std.meta.eql(a, b);
}

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
    // 生成代码里的下标来自模型声明顺序，`checkMeta` 已在编译期挡住 > 256 列的表；
    // 这里再断一次，避免手写调用把位移溢出变成未定义行为。
    std.debug.assert(index < max_fields);
    bits.* |= (@as(DirtyBits, 1) << @intCast(index));
}

pub fn isDirty(bits: DirtyBits, index: usize) bool {
    std.debug.assert(index < max_fields);
    return (bits & (@as(DirtyBits, 1) << @intCast(index))) != 0;
}

/// 编译期校验模型能不能装进实体的脏位图，并原样返回（生成代码写 `pub const meta = checkMeta(.{...});`）。
///
/// 为什么要在编译期卡：`DirtyBits = u256`，超宽列数会让 `1 << index` 位移溢出（ReleaseFast 下是 UB），
/// 而这种表（宽表 / 几百列的采集表）真的会出现，必须在**生成/编译**阶段就报清楚，不拖到运行期。
pub fn checkMeta(comptime meta: EntityMeta) EntityMeta {
    if (meta.fields.len > max_fields) {
        @compileError(std.fmt.comptimePrint(
            "实体 {s} 有 {d} 列，超过脏位图宽度 {d}：请拆表，或调整 zcode.entity.max_fields / DirtyBits",
            .{ meta.name, meta.fields.len, max_fields },
        ));
    }
    return meta;
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
    // 已知单一主键 → 缓存**精确失效**该行（单对象缓存不必整表清空）
    const affected = if (singlePkI64(meta, e)) |pk|
        try ref.updateOne(s, sets.items, &w, pk)
    else
        try ref.update(s, sets.items, &w);
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

/// 已存在实体的批量更新：按「脏列签名」分组合并成多行 `UPDATE`。
/// **口径**（两条都是用户明确要求）：
/// 1. **未改的列不进 SQL**：只写各自置脏的列；没脏列的实体在 `saveBatchWith` 里就已被跳过。
/// 2. **并发安全**：不做整行覆盖（upsert/全列 update）。同一张表被多个业务系统同时写时，
///    别人刚写的列不会被我们手里的旧值盖回去。
///
/// 同组（脏列集合完全相同）才合并成一条语句；方言不支持多行 UPDATE 时退化逐条，
/// 每条仍只写脏列。
fn updateDirtyBatch(dal: *Dal, comptime T: type, list: []const *T, s: *Session) !usize {
    const gpa = dal.gpa;
    const meta = T.meta;
    _ = try tableOf(dal, meta);

    var groups = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*T)).empty;
    defer {
        var git = groups.keyIterator();
        while (git.next()) |k| gpa.free(k.*);
        var vit = groups.valueIterator();
        while (vit.next()) |v| v.deinit(gpa);
        groups.deinit(gpa);
    }

    for (list) |e| {
        var sig: std.ArrayListUnmanaged(u8) = .empty;
        defer sig.deinit(gpa);
        for (meta.fields, 0..) |_, i| {
            if (!isDirty(e.dirty, i)) continue;
            var nb: [8]u8 = undefined;
            try sig.appendSlice(gpa, std.fmt.bufPrint(&nb, "{d},", .{i}) catch "");
        }
        const gop = try groups.getOrPut(gpa, sig.items);
        if (!gop.found_existing) {
            gop.key_ptr.* = try gpa.dupe(u8, sig.items);
            // `getOrPut` 不会初始化 value，unmanaged 容器必须显式置空，否则 append 读到垃圾
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, e);
    }

    var affected: usize = 0;
    var it = groups.valueIterator();
    while (it.next()) |rows| {
        affected += try updateSameColumns(dal, T, rows.items, s);
    }
    return affected;
}

/// 脏列集合完全相同的若干实体 → 一条多行 `UPDATE`（失败/不支持则逐条）。
fn updateSameColumns(dal: *Dal, comptime T: type, rows: []const *T, s: *Session) !usize {
    if (rows.len == 0) return 0;
    const gpa = dal.gpa;
    const meta = T.meta;
    const t = try tableOf(dal, meta);

    // 复合主键不走批量（多行 UPDATE 的关联条件会变复杂）
    var pk_idx: ?usize = null;
    var pk_count: usize = 0;
    for (meta.fields, 0..) |f, i| {
        if (f.primary_key) {
            pk_count += 1;
            pk_idx = i;
        }
    }
    if (pk_count != 1) return updateEach(dal, T, rows, s);
    const pk = pk_idx.?;

    var cols: std.ArrayListUnmanaged([]const u8) = .empty;
    defer cols.deinit(gpa);
    var col_idx: std.ArrayListUnmanaged(usize) = .empty;
    defer col_idx.deinit(gpa);
    for (meta.fields, 0..) |f, i| {
        if (i == pk) continue;
        if (!isDirty(rows[0].dirty, i)) continue;
        try cols.append(gpa, effectiveName(t, f.name));
        try col_idx.append(gpa, i);
    }
    if (cols.items.len == 0) return 0;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const values = try a.alloc([]const Value, rows.len);
    for (rows, 0..) |e, ri| {
        const one = try a.alloc(Value, col_idx.items.len + 1);
        one[0] = e.columnValue(pk);
        for (col_idx.items, 0..) |ci, k| one[k + 1] = e.columnValue(ci);
        values[ri] = one;
    }

    const sql = sqlbuild.updateMulti(
        gpa,
        dal.opts.provider,
        t,
        meta.table_name,
        effectiveName(t, meta.fields[pk].name),
        cols.items,
        values,
    ) catch |e| switch (e) {
        // 方言不支持多行 UPDATE：退化逐条（仍只写脏列）
        error.Unsupported => return updateEach(dal, T, rows, s),
        else => return e,
    };
    defer sql.deinit(gpa);

    const n = s.execute(sql.text, sql.params) catch |e| {
        std.debug.print(
            "[zcode] 批量更新失败：表 {s}，列 {d} 个，行 {d} 条\n  SQL: {s}\n  错误: {s}；{s}\n",
            .{ meta.table_name, cols.items.len, rows.len, sql.text, @errorName(e), s.lastError() },
        );
        return e;
    };
    for (rows) |e| e.dirty = 0;
    return n;
}

fn updateEach(dal: *Dal, comptime T: type, rows: []const *T, s: *Session) !usize {
    var n: usize = 0;
    for (rows) |e| {
        if (try update(dal, e, s) > 0) n += 1;
    }
    return n;
}

/// 批量保存（可指定 `SaveModes`）：
/// - 新增：全列合并成一条多行 `INSERT`（`upsert` / `insert_ignore` / `replace` 走方言 `ON CONFLICT` 等）；
/// - 已存在：**只写脏列**，同脏列签名合并成一条多行 `UPDATE`（未改的列不进 SQL，并发不覆盖别人）；
/// - 没脏列的实体：一条 SQL 都不发（计入 `unchanged`）；
/// - **配了分片策略的表自动走分片批量**（先按连接 + 物理分片表分组，绝不跨分片合并）。
pub fn saveBatchWith(dal: *Dal, comptime T: type, entities: []const *T, s: *Session, mode: SaveModes) !SaveBatchReport {
    const meta = T.meta;

    // 分表 / 分库：分片边界优先于「合并成一条」——跨库/跨表绝不能合成一条语句
    if (dal.shardPolicyFor(meta.table_name) != null) {
        return saveBatchSharded(dal, T, entities, mode);
    }

    const t = try tableOf(dal, meta);
    try assertWritable(t);

    const gpa = dal.gpa;
    var new_rows: std.ArrayList([]const sqlbuild.Field) = .empty;
    defer {
        for (new_rows.items) |r| gpa.free(r);
        new_rows.deinit(gpa);
    }

    var report = SaveBatchReport{};

    // 第一步：分流。新增 → 全列（一条多行 INSERT）；已存在 → 只按**各自的脏列**更新。
    // 「有脏列」与「没脏列」分开统计：没脏列的实体**一条 SQL 都不发**。
    var dirty_list: std.ArrayList(*T) = .empty;
    defer dirty_list.deinit(gpa);

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
        } else if (e.dirty != 0) {
            try dirty_list.append(gpa, e);
        } else {
            report.unchanged += 1;
        }
    }

    if (new_rows.items.len > 0) {
        const ref = try dal.table(meta.table_name);
        report.inserted = try ref.upsertBatch(s, new_rows.items, mode);
    }

    // 第二步：已存在实体按「脏列签名」分组合并成多行 UPDATE（同组列相同才能合）；
    // 方言不支持时退化为逐条（每条仍只写脏列，**不会**覆盖别人改过的列）。
    if (dirty_list.items.len > 0) {
        report.updated = try updateDirtyBatch(dal, T, dirty_list.items, s);
    }
    return report;
}

/// 分表分库的批量保存：**先按「连接 + 物理分片表」分组，再在组内按脏列签名分组**。
///
/// 三条硬约束（与主表批量同样的口径，但多一层分片边界）：
/// 1. **绝不跨分片合并**——不同库 / 不同物理表必须是不同语句，也不共用会话；
/// 2. **未改的列不进 SQL**——组内只带主键 + 该实体的脏列；
/// 3. **每个分片一次往返**——同组多行合成一条（方言不支持多行 UPDATE 时退化逐条）。
fn saveBatchSharded(dal: *Dal, comptime T: type, entities: []const *T, mode: SaveModes) !SaveBatchReport {
    const gpa = dal.gpa;
    const meta = T.meta;
    const policy = dal.shardPolicyFor(meta.table_name) orelse return error.NoShardPolicy;

    // 分片列在实体里的下标（模型字段名或物理列名都认）
    var fidx: ?usize = null;
    for (meta.fields, 0..) |f, i| {
        if (std.ascii.eqlIgnoreCase(f.name, policy.field) or
            std.ascii.eqlIgnoreCase(f.effectiveName(), policy.field))
        {
            fidx = i;
        }
    }
    const shard_field = fidx orelse {
        std.debug.print(
            "[zcode] 批量保存：表 {s} 配了分片策略，但实体里找不到分片列 {s}\n",
            .{ meta.table_name, policy.field },
        );
        return error.ShardFieldNotFound;
    };

    const Group = struct {
        model: shards.ShardModel,
        list: std.ArrayListUnmanaged(*T) = .empty,
    };

    var groups = std.StringHashMapUnmanaged(Group).empty;
    defer {
        var git = groups.keyIterator();
        while (git.next()) |k| gpa.free(k.*);
        var vit = groups.valueIterator();
        while (vit.next()) |g| {
            var m = g.model;
            m.deinit(gpa);
            g.list.deinit(gpa);
        }
        groups.deinit(gpa);
    }

    var report = SaveBatchReport{};
    for (entities) |e| {
        const sm = try dal.shardOfTable(meta.table_name, e.columnValue(shard_field));
        var kb: std.ArrayListUnmanaged(u8) = .empty;
        defer kb.deinit(gpa);
        try kb.appendSlice(gpa, sm.conn_name);
        try kb.append(gpa, 0);
        try kb.appendSlice(gpa, sm.table_name);

        const gop = try groups.getOrPut(gpa, kb.items);
        if (!gop.found_existing) {
            gop.key_ptr.* = try gpa.dupe(u8, kb.items);
            gop.value_ptr.* = .{ .model = sm };
        } else {
            var owned = sm;
            owned.deinit(gpa);
        }
        try gop.value_ptr.list.append(gpa, e);
    }

    var it = groups.valueIterator();
    while (it.next()) |g| {
        // 分片表可能还不存在（首次写入）
        _ = dal.ensureShardTable(meta.table_name, g.model) catch |e| {
            std.debug.print(
                "[zcode] 批量保存：建分片表失败 {s}.{s}：{s}\n",
                .{ g.model.conn_name, g.model.table_name, @errorName(e) },
            );
            return e;
        };

        const ref = try dal.tableShardOn(meta.table_name, g.model);
        var s = try dal.sessionForConn(g.model.conn_name);
        defer s.deinit();

        // 组内二分：新增（全列一次多行 INSERT）/ 已存在（脏列合并 UPDATE）
        var new_rows: std.ArrayListUnmanaged([]const sqlbuild.Field) = .empty;
        defer {
            for (new_rows.items) |r| gpa.free(r);
            new_rows.deinit(gpa);
        }
        var dirty_list: std.ArrayListUnmanaged(*T) = .empty;
        defer dirty_list.deinit(gpa);

        for (g.list.items) |e| {
            if (isNewEntity(meta, ref.table, e)) {
                var n: usize = 0;
                for (meta.fields) |f| {
                    if (!f.identity) n += 1;
                }
                const fields = try gpa.alloc(sqlbuild.Field, n);
                var k: usize = 0;
                for (meta.fields, 0..) |f, i| {
                    if (f.identity) continue;
                    fields[k] = .{ .name = effectiveName(ref.table, f.name), .value = e.columnValue(i) };
                    k += 1;
                }
                try new_rows.append(gpa, fields);
                e.dirty = 0;
            } else if (e.dirty != 0) {
                try dirty_list.append(gpa, e);
            } else {
                report.unchanged += 1;
            }
        }

        if (new_rows.items.len > 0) {
            report.inserted += try ref.upsertBatch(&s, new_rows.items, mode);
        }
        if (dirty_list.items.len > 0) {
            report.updated += try updateDirtyOn(dal, T, ref, &s, dirty_list.items);
        }
    }
    return report;
}

/// 在**指定分片表**上做脏列合并更新（`updateDirtyBatch` 的分片版）。
fn updateDirtyOn(dal: *Dal, comptime T: type, ref: TableRef, s: *Session, list: []const *T) !usize {
    const gpa = dal.gpa;
    const meta = T.meta;

    var groups = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*T)).empty;
    defer {
        var git = groups.keyIterator();
        while (git.next()) |k| gpa.free(k.*);
        var vit = groups.valueIterator();
        while (vit.next()) |v| v.deinit(gpa);
        groups.deinit(gpa);
    }

    for (list) |e| {
        var sig: std.ArrayListUnmanaged(u8) = .empty;
        defer sig.deinit(gpa);
        for (meta.fields, 0..) |_, i| {
            if (!isDirty(e.dirty, i)) continue;
            var nb: [8]u8 = undefined;
            try sig.appendSlice(gpa, std.fmt.bufPrint(&nb, "{d},", .{i}) catch "");
        }
        const gop = try groups.getOrPut(gpa, sig.items);
        if (!gop.found_existing) {
            gop.key_ptr.* = try gpa.dupe(u8, sig.items);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, e);
    }

    var affected: usize = 0;
    var it = groups.valueIterator();
    while (it.next()) |rows| {
        if (rows.items.len == 0) continue;

        var pk_idx: ?usize = null;
        var pk_count: usize = 0;
        for (meta.fields, 0..) |f, i| {
            if (f.primary_key) {
                pk_count += 1;
                pk_idx = i;
            }
        }
        if (pk_count != 1) {
            for (rows.items) |e| {
                if (try update(dal, e, s) > 0) affected += 1;
            }
            continue;
        }
        const pk = pk_idx.?;

        var cols: std.ArrayListUnmanaged([]const u8) = .empty;
        defer cols.deinit(gpa);
        var col_idx: std.ArrayListUnmanaged(usize) = .empty;
        defer col_idx.deinit(gpa);
        for (meta.fields, 0..) |f, i| {
            if (i == pk) continue;
            if (!isDirty(rows.items[0].dirty, i)) continue;
            try cols.append(gpa, effectiveName(ref.table, f.name));
            try col_idx.append(gpa, i);
        }
        if (cols.items.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const values = try a.alloc([]const Value, rows.items.len);
        for (rows.items, 0..) |e, ri| {
            const one = try a.alloc(Value, col_idx.items.len + 1);
            one[0] = e.columnValue(pk);
            for (col_idx.items, 0..) |ci, k| one[k + 1] = e.columnValue(ci);
            values[ri] = one;
        }

        const sql = sqlbuild.updateMulti(
            gpa,
            dal.opts.provider,
            ref.table,
            ref.table_name,
            effectiveName(ref.table, meta.fields[pk].name),
            cols.items,
            values,
        ) catch |e| switch (e) {
            error.Unsupported => {
                for (rows.items) |it2| {
                    if (try update(dal, it2, s) > 0) affected += 1;
                }
                continue;
            },
            else => return e,
        };
        defer sql.deinit(gpa);

        affected += s.execute(sql.text, sql.params) catch |e| {
            std.debug.print(
                "[zcode] 分片批量更新失败：表 {s}，列 {d} 个，行 {d} 条\n  SQL: {s}\n  错误: {s}；{s}\n",
                .{ ref.table_name, cols.items.len, rows.items.len, sql.text, @errorName(e), s.lastError() },
            );
            return e;
        };
        for (rows.items) |e| e.dirty = 0;
    }
    return affected;
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

/// 唯一主键且为整型时返回其值；复合主键/非整型主键返回 `null`。
/// 用于「单行写 → 缓存按主键精确失效」：复合主键的缓存只能整体失效。
fn singlePkI64(meta: EntityMeta, e: anytype) ?i64 {
    var found: ?i64 = null;
    for (meta.fields, 0..) |f, i| {
        if (!f.primary_key) continue;
        if (found != null) return null; // 复合主键
        found = e.columnValue(i).asI64() orelse return null;
    }
    return found;
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
    return if (singlePkI64(meta, e)) |pk|
        try ref.deleteOne(s, &w, pk)
    else
        try ref.delete(s, &w);
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

/// 行集 → 实体列表（对应 C# `DataRowEntityAccessor.LoadData<T>`）。
///
/// 用途：把**任意来源**的表格数据（查询结果、协议包解出来的行、CSV 读出来的行）
/// 一次转成实体列表，不必自己写循环。内存归 `arena`（会话结果缓冲出了作用域就失效，
/// 所以实体里的字符串必须先深拷贝一份——与 `queryRows` 同口径）。
pub fn fromRows(comptime T: type, a: std.mem.Allocator, rows: []const session_mod.Row) ![]T {
    var out: std.ArrayList(T) = .empty;
    try out.ensureTotalCapacity(a, rows.len);
    for (rows) |row| {
        var e = try fromRow(T, row);
        // 字符串列深拷贝：`Row` 里的切片借用结果集缓冲
        for (T.meta.fields, 0..) |_, i| {
            const v = e.columnValue(i);
            if (v == .text) {
                try e.setColumnValue(i, .{ .text = try a.dupe(u8, v.text) });
            } else if (v == .blob) {
                try e.setColumnValue(i, .{ .blob = try a.dupe(u8, v.blob) });
            }
        }
        e.dirty = 0;
        out.appendAssumeCapacity(e);
    }
    return out.toOwnedSlice(a);
}

/// get-or-create 的结果。
pub fn GetOrAddResult(comptime T: type) type {
    return struct {
        entity: T,
        /// true = 本次新建并已插入；false = 命中已有记录
        created: bool,
    };
}

/// 进程内按 key 串行化的条带锁（对应 C# `KeyedLocker<TEntity>`；8 条带与 C# 一致）。
var get_or_add_locks: keyed_lock.KeyedLock = .{};

/// 「有就取、没有就建」——对应 C# `Entity<T>.GetOrAdd(key)`。
///
/// 并发语义（C# 用的是同一套）：先无锁查一次；没有则**按主键值加锁**再查一次（双重检查），
/// 仍未命中才在事务里创建并插入。没有这把锁，两个线程会各插一条，唯一索引上直接炸。
///
/// `create` 由调用方提供（Zig 没有闭包捕获，用 `ctx` + 函数指针；返回值是**未插入**的实体，
/// 本函数负责插入并把自增 ID 回写）。
pub fn getOrAdd(
    dal: *Dal,
    comptime T: type,
    s: *Session,
    pk_values: []const Value,
    ctx: *anyopaque,
    create: *const fn (ctx: *anyopaque) anyerror!T,
) !GetOrAddResult(T) {
    if (try findByPk(dal, T, s, pk_values)) |e| return .{ .entity = e, .created = false };

    // 锁 key = 主键值（拼接带分隔符，避免不同主键拼出同一个 key）
    const key = try keyed_lock.keyOfAlloc(dal.gpa, pk_values);
    defer dal.gpa.free(key);

    var guard = get_or_add_locks.lock(key);
    defer guard.release();

    // 双重检查：别的线程可能刚插完
    if (try findByPk(dal, T, s, pk_values)) |e| return .{ .entity = e, .created = false };

    // 事务：保证「插入 + 后续读」一致（调用方已经在事务里就复用，不嵌套）
    const own_tx = !s.inTransaction();
    var tx: Session.Scoped = undefined;
    if (own_tx) tx = try Session.Scoped.begin(s);

    var e = try create(ctx);
    _ = try insert(dal, &e, s);

    if (own_tx) {
        tx.commit() catch |err| {
            tx.deinit();
            return err;
        };
    }
    return .{ .entity = e, .created = true };
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

// ── 用例：getOrAdd / fromRows（SQLite 内存库）────────────────────────────────

const TestUser = struct {
    Code: []const u8 = "",
    Name: []const u8 = "",
    dirty: DirtyBits = 0,

    /// 用**业务主键**（字符串 Code）建模：`getOrAdd` 的语义是「按业务键取或建」，
    /// 自增主键那种表用不上它（新行的主键由数据库生成，锁 key 无从预先给出）。
    pub const meta = EntityMeta{
        .name = "GaoUser",
        .table_name = "Gao_User",
        .fields = &.{
            .{ .name = "Code", .data_type = .string, .primary_key = true },
            .{ .name = "Name", .data_type = .string },
        },
    };

    pub fn columnValue(self: @This(), i: usize) Value {
        return switch (i) {
            0 => .{ .text = self.Code },
            1 => .{ .text = self.Name },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: Value) !void {
        switch (i) {
            0 => self.Code = v.asText() orelse "",
            1 => self.Name = v.asText() orelse "",
            else => return error.ColumnNotFound,
        }
    }
};

fn openGaoDal(a: std.mem.Allocator) !Dal {
    const xml =
        \\<EntityModel><Tables><Table Name="GaoUser" TableName="Gao_User">
        \\  <Columns>
        \\    <Column Name="Code" DataType="String" Length="20" PrimaryKey="True" />
        \\    <Column Name="Name" DataType="String" Length="50" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m = try model.EntityModel.parse(a, xml);
    return Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
}

/// 造实体用的上下文（Zig 没有闭包捕获，用 ctx + 函数指针）
const CreateCtx = struct {
    code: []const u8,
    name: []const u8,
    calls: usize = 0,
};

fn createOne(ctx: *anyopaque) anyerror!TestUser {
    const c: *CreateCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    return .{ .Code = c.code, .Name = c.name };
}

test "getOrAdd：第一次新建、第二次命中已有（不重复插入）" {
    const a = std.testing.allocator;
    var dal = openGaoDal(a) catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer dal.deinit();
    var s = dal.openSession() catch {
        std.debug.print("[SKIP] 无法加载 SQLite\n", .{});
        return;
    };
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var ctx = CreateCtx{ .code = "c1", .name = "alice" };
    const pk = [_]Value{.{ .text = "c1" }};

    const r1 = try getOrAdd(&dal, TestUser, &s, &pk, @ptrCast(&ctx), createOne);
    try std.testing.expect(r1.created);
    try std.testing.expectEqualStrings("c1", r1.entity.Code);
    try std.testing.expectEqualStrings("alice", r1.entity.Name);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);

    // 第二次：业务键已存在 → 命中，不再调用 create
    const r2 = try getOrAdd(&dal, TestUser, &s, &pk, @ptrCast(&ctx), createOne);
    try std.testing.expect(!r2.created);
    try std.testing.expectEqualStrings("alice", r2.entity.Name);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);

    const t = try dal.table("GaoUser");
    try std.testing.expectEqual(@as(i64, 1), try t.count(&s, null));
}

test "fromRows：行集批量转实体（字符串深拷贝，不借用结果缓冲）" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var names = [_][]const u8{ "Code", "Name" };
    var v1 = [_]Value{ .{ .text = "k1" }, .{ .text = "a" } };
    var v2 = [_]Value{ .{ .text = "k2" }, .{ .text = "b" } };
    const rows = [_]session_mod.Row{
        .{ .names = &names, .values = &v1 },
        .{ .names = &names, .values = &v2 },
    };

    var owned = std.heap.ArenaAllocator.init(a);
    defer owned.deinit();

    const list = try fromRows(TestUser, owned.allocator(), &rows);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("k1", list[0].Code);
    try std.testing.expectEqualStrings("a", list[0].Name);
    try std.testing.expectEqualStrings("k2", list[1].Code);
    try std.testing.expectEqualStrings("b", list[1].Name);
    // 不置脏：转进来的实体应当可以原样 update（不会因 dirty 位误写）
    try std.testing.expectEqual(@as(DirtyBits, 0), list[0].dirty);
    _ = aa;
}
