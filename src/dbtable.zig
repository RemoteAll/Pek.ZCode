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
const Value = @import("zzig").db.Value;
const DatabaseKind = @import("dialect.zig").DatabaseKind;
const sqlbuild = @import("sqlbuild.zig");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Row = session_mod.Row;
const query = @import("query.zig");
const Where = query.Where;
const Query = query.Query;
const DateTime = @import("zzig").DateTime;

pub const TableRef = struct {
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    /// 物理表名（分表场景由调用方传入具体表名）
    table_name: []const u8,
    /// 写后失效通知（由 `Dal.table()` 注入；不引入对 dal 的循环依赖）
    write_ctx: ?*anyopaque = null,
    write_notify: ?*const fn (ctx: *anyopaque, table_name: []const u8) void = null,
    /// 写入拦截器链（审计列自动补全；由 `Dal` 注入，可为空）
    chain: ?*@import("interceptor.zig").Chain = null,

    pub fn init(gpa: std.mem.Allocator, kind: DatabaseKind, table: *const TableMeta) TableRef {
        return .{ .gpa = gpa, .kind = kind, .table = table, .table_name = table.effectiveTableName() };
    }

    /// 注入写后通知（Dal 用它使整表缓存失效）。
    pub fn setWriteNotifier(self: *TableRef, ctx: *anyopaque, notify: *const fn (ctx: *anyopaque, table_name: []const u8) void) void {
        self.write_ctx = ctx;
        self.write_notify = notify;
    }

    fn notifyWrite(self: *const TableRef) void {
        if (self.write_ctx) |ctx| {
            if (self.write_notify) |notify| notify(ctx, self.table_name);
        }
    }

    /// 注入写入拦截器链。
    pub fn setInterceptorChain(self: *TableRef, chain: ?*@import("interceptor.zig").Chain) void {
        self.chain = chain;
    }

    /// 把拦截器应用到一次写入的字段列表（无链时直接返回原切片，不分配）。
    fn applyInterceptors(
        self: *const TableRef,
        s: *Session,
        method: @import("interceptor.zig").Method,
        fields: []const sqlbuild.Field,
    ) ![]const sqlbuild.Field {
        const chain = self.chain orelse return fields;
        if (chain.count() == 0) return fields;

        const gpa = s.gpa;
        var list: std.ArrayList(sqlbuild.Field) = .empty;
        try list.appendSlice(gpa, fields);
        errdefer list.deinit(gpa);

        chain.applyTo(method, self.table, .{ .gpa = gpa, .items = &list }) catch |e| {
            list.deinit(gpa);
            return e;
        };

        // 结果直接传回调用方，由调用方（本函数的所有调用点）负责释放
        return list.toOwnedSlice(gpa);
    }

    /// 插入一行（带拦截器）：拦截器可能追加审计列。
    fn insertWithInterceptors(self: *const TableRef, s: *Session, fields: []const sqlbuild.Field) !i64 {
        const chain = self.chain orelse return self.insertRaw(s, fields);
        if (chain.count() == 0) return self.insertRaw(s, fields);

        const effective = try self.applyInterceptors(s, .insert, fields);
        defer s.gpa.free(effective);
        return self.insertRaw(s, effective);
    }

    /// 插入一行，返回自增 ID（无自增列返回 0）。
    pub fn insert(self: *const TableRef, s: *Session, fields: []const sqlbuild.Field) !i64 {
        return self.insertWithInterceptors(s, fields);
    }

    fn insertRaw(self: *const TableRef, s: *Session, fields: []const sqlbuild.Field) !i64 {
        try self.ensureWritable();
        const sql = try sqlbuild.insert(self.gpa, self.kind, self.table, self.table_name, fields);
        defer sql.deinit(self.gpa);
        _ = try s.execute(sql.text, sql.params);
        self.notifyWrite();
        if (self.table.identity() != null) return s.lastInsertId();
        return 0;
    }

    /// 更新（`filter` 为空即全表——调用方必须自己保证带上主键条件）。
    pub fn update(self: *const TableRef, s: *Session, sets: []const sqlbuild.Field, filter: ?*const Where) !usize {
        var effective = sets;
        var owned: ?[]sqlbuild.Field = null;
        if (self.chain) |chain| {
            if (chain.count() > 0) {
                effective = try self.applyInterceptors(s, .update, sets);
                owned = @constCast(effective);
            }
        }
        defer if (owned) |o| s.gpa.free(o);

        try self.ensureWritable();
        const sql = try sqlbuild.update(self.gpa, self.kind, self.table, self.table_name, effective, filter);
        defer sql.deinit(self.gpa);
        const affected = try s.execute(sql.text, sql.params);
        if (affected > 0) self.notifyWrite();
        return affected;
    }

    /// 删除（同样：`filter` 为空即清空全表，慎用）。
    pub fn delete(self: *const TableRef, s: *Session, filter: ?*const Where) !usize {
        try self.ensureWritable();
        const sql = try sqlbuild.delete(self.gpa, self.kind, self.table_name, filter);
        defer sql.deinit(self.gpa);
        const affected = try s.execute(sql.text, sql.params);
        if (affected > 0) self.notifyWrite();
        return affected;
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

    /// 批量插入：多行 VALUES，按方言参数上限自动分批（默认最多 5000 行/批）。
    ///
    /// 行列集合必须一致（同 `sqlbuild.insertMulti`）；返回累计影响行数。
    pub fn insertBatch(self: *const TableRef, s: *Session, rows: []const []const sqlbuild.Field) !usize {
        try self.ensureWritable();
        if (rows.len == 0) return 0;

        // 拦截器：逐行补齐审计列（每行独立内存，避免复用同一缓冲）
        var patched: std.ArrayList([]const sqlbuild.Field) = .empty;
        defer {
            for (patched.items) |r| self.gpa.free(r);
            patched.deinit(self.gpa);
        }
        if (self.chain) |chain| {
            if (chain.count() > 0) {
                try patched.ensureTotalCapacity(self.gpa, rows.len);
                for (rows) |row| {
                    const effective = try self.applyInterceptors(s, .insert, row);
                    patched.appendAssumeCapacity(effective);
                }
            }
        }
        const effective_rows: []const []const sqlbuild.Field = if (patched.items.len > 0) patched.items else rows;

        const cols = effective_rows[0].len;
        if (cols == 0) return error.Model;

        var per_batch: usize = 5000;
        const param_limit = self.kind.maxStatementParams() / cols;
        if (param_limit > 0 and param_limit < per_batch) per_batch = param_limit;
        if (per_batch == 0) per_batch = 1;

        var affected: usize = 0;
        var start: usize = 0;
        while (start < effective_rows.len) {
            const end = @min(start + per_batch, effective_rows.len);
            const sql = try sqlbuild.insertMulti(self.gpa, self.kind, self.table, self.table_name, effective_rows[start..end]);
            defer sql.deinit(self.gpa);
            affected += try s.execute(sql.text, sql.params);
            start = end;
        }
        if (affected > 0) self.notifyWrite();
        return affected;
    }

    /// 通过 `LOAD DATA LOCAL INFILE` 批量装载（**MySQL 专属**；其它方言返回 `error.Unsupported`，
    /// 调用方应回落到 `insertBatch`）。
    ///
    /// 为什么快：一次往返 + 服务端批量解析，没有逐行 INSERT 的语法分析与参数绑定。
    /// 本机实测见 `docs/决策记录.md`（万行级别通常是多行 INSERT 的 3~10 倍）。
    ///
    /// 约定：
    /// - `columns` 是**物理列名**，顺序与 `rows` 里每个元素的顺序一一对应；
    /// - NULL 写成 `\N`；`\\` / `\t` / `\n` / `\r` 按 MySQL 默认转义规则转义；
    /// - 二进制列（`Value.blob`）**不支持**文本装载，直接报 `error.Unsupported`（不静默截断）。
    pub fn loadDataBatch(self: *const TableRef, s: *Session, columns: []const []const u8, rows: []const []const Value) !usize {
        try self.ensureWritable();
        if (rows.len == 0) return 0;
        if (s.kind != .mysql) {
            std.debug.print("[zcode] loadDataBatch 仅支持 MySQL（当前 {s}），请改用 insertBatch\n", .{@tagName(s.kind)});
            return error.Unsupported;
        }

        const gpa = s.gpa;

        // 1) 数据（TSV，MySQL 默认 FIELDS/ESCAPED/LINES 口径）
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        for (rows) |row| {
            if (row.len != columns.len) {
                std.debug.print(
                    "[zcode] loadDataBatch：行列数不一致（列 {d} / 值 {d}），无法装载\n",
                    .{ columns.len, row.len },
                );
                return error.Model;
            }
            for (row, 0..) |v, i| {
                if (i > 0) try data.append(gpa, '\t');
                try appendLoadField(&data, gpa, v);
            }
            try data.append(gpa, '\n');
        }

        // 2) SQL（文件名只用于服务端日志；数据由客户端流式发送）
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(gpa);
        try sql.appendSlice(gpa, "LOAD DATA LOCAL INFILE 'zcode_bulk.tsv' INTO TABLE ");
        const quoted_table = try self.kind.quoteAlloc(gpa, self.table_name);
        defer gpa.free(quoted_table);
        try sql.appendSlice(gpa, quoted_table);
        try sql.appendSlice(gpa, " CHARACTER SET utf8mb4 FIELDS TERMINATED BY '\\t' ESCAPED BY '\\\\' LINES TERMINATED BY '\\n' (");
        for (columns, 0..) |c, i| {
            if (i > 0) try sql.appendSlice(gpa, ", ");
            const q = try self.kind.quoteAlloc(gpa, c);
            defer gpa.free(q);
            try sql.appendSlice(gpa, q);
        }
        try sql.appendSlice(gpa, ")");

        const n = try s.loadDataLocal(sql.items, data.items);
        if (n > 0) self.notifyWrite();
        return @intCast(n);
    }

    /// 按主键批量删除：`WHERE pk IN (...)`，按参数上限分批（复合主键调用方自己拼 Where）。
    pub fn deleteByPkBatch(self: *const TableRef, s: *Session, pk_values: []const Value) !usize {
        try self.ensureWritable();
        if (pk_values.len == 0) return 0;

        const pks = try self.table.primaryKeys(self.gpa);
        defer self.gpa.free(pks);
        if (pks.len != 1) return error.Unsupported;
        const pk_name = self.table.effectiveColumnName(pks[0]);

        var per_batch = self.kind.maxStatementParams();
        if (per_batch > 1000) per_batch = 1000;
        if (per_batch == 0) per_batch = 1;

        var affected: usize = 0;
        var start: usize = 0;
        while (start < pk_values.len) {
            const end = @min(start + per_batch, pk_values.len);
            var w = Where.init(self.gpa);
            defer w.deinit();
            _ = try w.in(pk_name, pk_values[start..end]);
            const sql = try sqlbuild.delete(self.gpa, self.kind, self.table_name, &w);
            defer sql.deinit(self.gpa);
            affected += try s.execute(sql.text, sql.params);
            start = end;
        }
        if (affected > 0) self.notifyWrite();
        return affected;
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
    /// 按模型列类型规整值：读到的时间/小数/布尔都转成规范表示。
    ///
    /// 分配口径（性能相关）：直接 `arena.alloc` 一次拿到结果数组、每行一次 `alloc` 拿到值数组，
    /// **不再用 ArrayList + toOwnedSlice**——后者会多复制一遍（arena 上的 toOwnedSlice 是拷贝），
    /// 分页 10 行 × 5 列就是 20 次多余分配。
    fn normalizeRows(self: *const TableRef, s: *Session, raw: []const Row) ![]Row {
        const arena = s.resultAllocator();
        if (raw.len == 0) return &.{};

        const out = try arena.alloc(Row, raw.len);
        for (raw, 0..) |row, r| {
            const values = try arena.alloc(Value, row.values.len);
            for (row.names, 0..) |name, i| {
                const raw_value = row.values[i];
                const col = self.table.column(name);
                values[i] = if (col) |c|
                    try normalizeValue(arena, c.data_type, raw_value, self.table.effectiveColumnName(c))
                else
                    raw_value;
            }
            out[r] = .{ .names = row.names, .values = values };
        }
        return out;
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

/// 把值写成 MySQL `LOAD DATA` 文本字段（`\N` 表示 NULL，其余按默认转义规则处理）。
fn appendLoadField(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: Value) !void {
    var num_buf: [64]u8 = undefined;
    const text: []const u8 = switch (v) {
        .null => {
            try out.appendSlice(gpa, "\\N");
            return;
        },
        .boolean => |b| if (b) "1" else "0",
        .int => |n| try std.fmt.bufPrint(&num_buf, "{d}", .{n}),
        .float => |f| try std.fmt.bufPrint(&num_buf, "{d}", .{f}),
        .decimal => |d| try d.formatBuf(&num_buf),
        .datetime => |dt| try dt.formatBuf(&num_buf),
        .text => |t| t,
        .blob => {
            // 文本装载无法安全表达任意二进制（含 \0 与分隔符）
            std.debug.print("[zcode] loadDataBatch：不支持二进制列（请改用 insertBatch）\n", .{});
            return error.Unsupported;
        },
    };

    for (text) |c| {
        switch (c) {
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            0 => try out.appendSlice(gpa, "\\0"),
            else => try out.append(gpa, c),
        }
    }
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
