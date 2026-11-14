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
const SaveModes = @import("setting.zig").SaveModes;
/// InfluxDB 驱动（Line Protocol 拼装只在驱动里，本层只做「列 → tag/field/时间」的角色划分）
const influx_mod = @import("zzig").influxdb;

/// MySQL 行别名（`INSERT ... VALUES (...) AS zcode_new ON DUPLICATE KEY UPDATE c = zcode_new.c`）。
///
/// MySQL 规定**行别名不能与表名相同**；`zcode_new` 带 ORM 前缀，业务表不会叫这个名字。
const mysql_row_alias = "zcode_new";

pub const TableRef = struct {
    gpa: std.mem.Allocator,
    kind: DatabaseKind,
    table: *const TableMeta,
    /// 物理表名（分表场景由调用方传入具体表名）
    table_name: []const u8,
    /// 连接名（空 = 主连接）：分库同名表的缓存作用域
    conn_name: []const u8 = "",
    /// 写后失效通知（由 `Dal.table()` 注入；不引入对 dal 的循环依赖）
    write_ctx: ?*anyopaque = null,
    write_notify: ?*const fn (ctx: *anyopaque, table_name: []const u8, conn_name: []const u8, key: ?i64) void = null,
    /// 写入拦截器链（审计列自动补全；由 `Dal` 注入，可为空）
    chain: ?*@import("interceptor.zig").Chain = null,
    /// 方言能力开关（由 `Dal` 探测服务端版本后注入）。
    ///
    /// 默认 `conservative`（只用各产品最早在役版本就有的语法）：调用方直接
    /// `TableRef.init` 构造句柄时（工具 / 测试）行为可预期，不会突然产出对方不认识的 SQL。
    features: @import("dialect.zig").Features = .conservative,

    pub fn init(gpa: std.mem.Allocator, kind: DatabaseKind, table: *const TableMeta) TableRef {
        return .{ .gpa = gpa, .kind = kind, .table = table, .table_name = table.effectiveTableName() };
    }

    /// 注入写后通知（Dal 用它使缓存失效）。
    pub fn setWriteNotifier(self: *TableRef, ctx: *anyopaque, notify: *const fn (ctx: *anyopaque, table_name: []const u8, conn_name: []const u8, key: ?i64) void) void {
        self.write_ctx = ctx;
        self.write_notify = notify;
    }

    /// 写后通知。`key` 非空表示**本次只影响这一行**，缓存可精确失效（不用整表清空）。
    fn notifyWriteKey(self: *const TableRef, key: ?i64) void {
        if (self.write_ctx) |ctx| {
            if (self.write_notify) |notify| notify(ctx, self.table_name, self.conn_name, key);
        }
    }

    fn notifyWrite(self: *const TableRef) void {
        self.notifyWriteKey(null);
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

    /// 把一行字段拼成 InfluxDB 的 Line Protocol（对应 C# `InfluxDBSession.BuildLineProtocol`）。
    ///
    /// 角色划分（按模型列）：
    /// - **时间列**：列名 `Time` / `CreateTime` / `UpdateTime` 且值非空 → 行尾纳秒时间戳；
    /// - **标签（tag）**：`primary_key`（主键/主列）→ `key=value`；
    /// - **字段（field）**：其余列 → `key=value`（字符串双引号包裹，数字/布尔原样）。
    ///
    /// 没给值（`fields` 里没有该列）的列**不出现**，让 InfluxDB 用默认值——不要凭空写 NULL。
    pub fn influxLineAlloc(self: *const TableRef, a: std.mem.Allocator, fields: []const sqlbuild.Field) ![]u8 {
        var tags: std.ArrayListUnmanaged(influx_mod.PointTag) = .empty;
        defer tags.deinit(a);
        var flds: std.ArrayListUnmanaged(influx_mod.PointField) = .empty;
        defer flds.deinit(a);
        var ts_ns: ?i64 = null;

        for (self.table.columns) |col| {
            const name = self.table.effectiveColumnName(&col);
            const v = fieldValue(fields, name) orelse continue;
            if (v == .null) continue;

            if (col.primary_key and ts_ns == null and isTimeColumnName(name)) {
                if (v.asDatetime()) |dt| ts_ns = datetimeToNanos(dt);
                continue;
            }
            if (isTimeColumnName(name)) {
                if (v.asDatetime()) |dt| {
                    ts_ns = datetimeToNanos(dt);
                    continue;
                }
            }

            if (col.primary_key) {
                const text = try v.toTextAlloc(a);
                try tags.append(a, .{ .name = name, .value = text });
            } else {
                try flds.append(a, .{ .name = name, .value = try influxFieldValueAlloc(a, v) });
            }
        }

        if (flds.items.len == 0) {
            // Line Protocol 要求至少一个字段；只有标签 + 时间的一行是非法的
            std.debug.print(
                "[zcode] InfluxDB 写入：表 {s} 这一行没有可写字段（列都在标签/时间中），已拒绝\n",
                .{self.table_name},
            );
            return error.InfluxNoField;
        }

        return influx_mod.buildLineAlloc(a, self.table_name, tags.items, flds.items, ts_ns);
    }

    fn fieldValue(fields: []const sqlbuild.Field, name: []const u8) ?Value {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.value;
        }
        return null;
    }

    fn isTimeColumnName(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "Time") or
            std.ascii.eqlIgnoreCase(name, "CreateTime") or
            std.ascii.eqlIgnoreCase(name, "UpdateTime");
    }

    /// 时间 → 纳秒时间戳（Line Protocol 缺省精度就是纳秒）。
    fn datetimeToNanos(dt: DateTime) i64 {
        const secs = dt.toUnixSeconds();
        return secs * std.time.ns_per_s + @as(i64, @intCast(dt.nanos));
    }

    /// 字段值渲染：整数/浮点/布尔裸写，字符串/时间带双引号并转义。
    fn influxFieldValueAlloc(a: std.mem.Allocator, v: Value) ![]u8 {
        return switch (v) {
            .int => |i| std.fmt.allocPrint(a, "{d}", .{i}),
            .float => |f| std.fmt.allocPrint(a, "{d}", .{f}),
            .boolean => |b| a.dupe(u8, if (b) "true" else "false"),
            .decimal => |d| d.formatAlloc(a),
            else => blk: {
                const text = try v.toTextAlloc(a);
                var out: std.ArrayListUnmanaged(u8) = .empty;
                try out.append(a, '"');
                for (text) |c| {
                    if (c == '"' or c == '\\') try out.append(a, '\\');
                    try out.append(a, c);
                }
                try out.append(a, '"');
                break :blk try out.toOwnedSlice(a);
            },
        };
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
        // InfluxDB 没有 INSERT 语句：写的是 Line Protocol（与 C# `InfluxDBSession.Insert` 一致）
        if (self.kind == .influxdb) {
            const line = try self.influxLineAlloc(s.resultAllocator(), fields);
            _ = try s.execute(line, &.{});
            self.notifyWrite();
            return 0;
        }
        // 允许显式写入自增列：导入 / 迁移 / 跳库同步必须保留原主键。
        // SQL Server 会包 `SET IDENTITY_INSERT`，PG 系会加 `OVERRIDING SYSTEM VALUE`；
        // 调用方没给自增列时这些处理自然不会发生（见 `sqlbuild.insertWith`）。
        const sql = try sqlbuild.insertWith(self.gpa, self.kind, self.table, self.table_name, fields, .{ .allow_identity = true });
        defer sql.deinit(self.gpa);

        if (self.table.identity()) |idcol| {
            // PG 系：`RETURNING <自增列>` 在**同一次往返**里拿回 ID。
            // 驱动自身没有「自增值回写」（`lastInsertId` 恒 0），不用 RETURNING 就只能再发
            // 一条 `SELECT currval()` / `SELECT ...`，那是白白多一个来回。
            if (self.kind.isPostgresFamily() and self.features.pg_returning) {
                var b = @import("zzig").Buf.init(self.gpa);
                defer b.deinit();
                try b.add(sql.text);
                try b.add(" RETURNING ");
                try self.kind.pushQuoted(&b, self.table.effectiveColumnName(idcol));
                const returning_sql = try b.toOwnedSlice();
                defer self.gpa.free(returning_sql);

                const rows = s.queryRows(returning_sql, sql.params) catch |e| {
                    std.debug.print(
                        "[zcode] 插入回写自增 ID 失败：表 {s}\n  SQL: {s}\n  错误: {s}；{s}\n",
                        .{ self.table_name, returning_sql, @errorName(e), s.lastError() },
                    );
                    return e;
                };
                if (rows.len == 0 or rows[0].values.len == 0) {
                    // INSERT ... RETURNING 必须有行返回；没有说明服务端行为异常，不能装成功
                    std.debug.print(
                        "[zcode] 插入回写自增 ID 异常：表 {s} 的 RETURNING 没有任何行\n  SQL: {s}\n",
                        .{ self.table_name, returning_sql },
                    );
                    return error.NoReturningRow;
                }
                const id = rows[0].values[0].asI64() orelse 0;
                self.notifyWriteKey(if (id > 0) id else null);
                return id;
            }

            _ = try s.execute(sql.text, sql.params);
            const id = s.lastInsertId();
            // 自增主键已知 → 精确失效那一行，免得单对象缓存被整表清空（写多读多场景的关键）
            self.notifyWriteKey(if (id > 0) id else null);
            return id;
        }

        _ = try s.execute(sql.text, sql.params);
        self.notifyWrite();
        return 0;
    }

    /// 更新（`filter` 为空即全表——调用方必须自己保证带上主键条件）。
    pub fn update(self: *const TableRef, s: *Session, sets: []const sqlbuild.Field, filter: ?*const Where) !usize {
        return self.updateInner(s, sets, filter, null);
    }

    /// 单行更新（调用方已带主键条件且知道主键值）：缓存**精确失效**该行。
    pub fn updateOne(self: *const TableRef, s: *Session, sets: []const sqlbuild.Field, filter: ?*const Where, pk: i64) !usize {
        return self.updateInner(s, sets, filter, pk);
    }

    fn updateInner(self: *const TableRef, s: *Session, sets: []const sqlbuild.Field, filter: ?*const Where, pk: ?i64) !usize {
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
        if (affected > 0) self.notifyWriteKey(pk);
        return affected;
    }

    /// 累加更新（对应 C# 累加字段 `Additional`）：`SET col = col + ?`。
    ///
    /// 与 `update` 的区别：`update` 把列置为给定值（覆盖），`accumulate` 在列自身基础上累加。
    /// 统计类字段必须走这里——覆盖写会丢并发增量。
    pub fn accumulate(self: *const TableRef, s: *Session, fields: []const sqlbuild.AccumulateField, filter: ?*const Where) !usize {
        return self.accumulateWith(s, fields, filter);
    }

    /// 累加更新（显式模式：`add` / `max` / `min`）。
    pub fn accumulateWith(self: *const TableRef, s: *Session, fields: []const sqlbuild.AccumulateField, filter: ?*const Where) !usize {
        if (fields.len == 0) return 0;
        try self.ensureWritable();
        const sql = try sqlbuild.updateAccumulate(self.gpa, self.kind, self.table, self.table_name, fields, filter);
        defer sql.deinit(self.gpa);
        const affected = try s.execute(sql.text, sql.params);
        if (affected > 0) self.notifyWrite();
        return affected;
    }

    /// 删除（同样：`filter` 为空即清空全表，慎用）。
    pub fn delete(self: *const TableRef, s: *Session, filter: ?*const Where) !usize {
        return self.deleteInner(s, filter, null);
    }

    /// 单行删除（知道主键）：缓存**精确失效**该行。
    pub fn deleteOne(self: *const TableRef, s: *Session, filter: ?*const Where, pk: i64) !usize {
        return self.deleteInner(s, filter, pk);
    }

    fn deleteInner(self: *const TableRef, s: *Session, filter: ?*const Where, pk: ?i64) !usize {
        try self.ensureWritable();
        const sql = try sqlbuild.delete(self.gpa, self.kind, self.table_name, filter);
        defer sql.deinit(self.gpa);
        const affected = try s.execute(sql.text, sql.params);
        if (affected > 0) self.notifyWriteKey(pk);
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

        // InfluxDB：整批拼成一个 Line Protocol 文本，**一次 HTTP 请求**写完
        if (self.kind == .influxdb) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var text: std.ArrayListUnmanaged(u8) = .empty;
            for (rows) |row| {
                const line = try self.influxLineAlloc(a, row);
                try text.appendSlice(a, line);
                try text.append(a, '\n');
            }
            _ = try s.execute(text.items, &.{});
            self.notifyWrite();
            return rows.len;
        }

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
            const sql = try sqlbuild.insertMultiWith(self.gpa, self.kind, self.table, self.table_name, effective_rows[start..end], .{ .allow_identity = true });
            defer sql.deinit(self.gpa);
            affected += try s.execute(sql.text, sql.params);
            start = end;
        }
        if (affected > 0) self.notifyWrite();
        return affected;
    }

    /// 批量写入，按 `SaveModes` 决定 SQL 形态（对应 C# `DataAccessLayer/SaveModes`）。
    ///
    /// | 模式 | SQLite | MySQL | PostgreSQL 系 |
    /// |---|---|---|---|
    /// | `insert` | `INSERT INTO` | 同左 | 同左 |
    /// | `upsert` | `... ON CONFLICT(pk) DO UPDATE SET` | `... ON DUPLICATE KEY UPDATE` | `... ON CONFLICT(pk) DO UPDATE SET` |
    /// | `insert_ignore` | `... ON CONFLICT DO NOTHING`（只忽略唯一冲突） | `INSERT IGNORE`（⚠️ 也会吞数据错误） | `... ON CONFLICT DO NOTHING` |
    /// | `replace` | `INSERT OR REPLACE INTO` | `REPLACE INTO` | 退回 `upsert`（PG 无 REPLACE） |
    ///
    /// 其它方言（SQL Server / Oracle / Access …）**不做字符串改写**：整批退化为
    /// 「逐行先 UPDATE、未命中再 INSERT」，放在同一个事务里（语义等价、往返多）。
    ///
    /// 冲突目标用**模型定义**：优先主键（且主键列都在插入列里），
    /// 否则第一个「列全在插入列里」的**唯一索引**；都不适用时 SQLite/PG 报 `error.NoUniqueKey`
    /// （不编造一个不存在的冲突目标，否则 SQL 会报 UNIQUE constraint failed）。
    ///
    /// MySQL 的 `ON DUPLICATE KEY UPDATE` 不需要目标，因此它不受此限制。
    pub fn upsertBatch(self: *const TableRef, s: *Session, rows: []const []const sqlbuild.Field, mode: SaveModes) !usize {
        try self.ensureWritable();
        if (rows.len == 0) return 0;
        if (mode == .insert) return self.insertBatch(s, rows);

        const pks = try self.table.primaryKeys(self.gpa);
        defer self.gpa.free(pks);

        // `insert_ignore` 是「存在就跳过」，**不需要主键也不需要冲突目标**（冲突由数据库按唯一约束判定）。
        // 需要冲突目标的是 `upsert` / `replace`。
        //
        // ⚠️ 方言语义差异（重要）：
        // - SQLite / PG 系：`ON CONFLICT DO NOTHING` 只忽略**唯一/排他冲突**，其它约束照常报错；
        // - MySQL：`INSERT IGNORE` 会把 NOT NULL / 数据截断 / 非法日期等**一并降级为 warning 后跳过**，
        //   对数据质量敏感的表不要用 `.insert_ignore`（改用 `.upsert` 或先清洗数据）；
        // - SQL Server / Oracle 等：走 `INSERT ... SELECT ... WHERE NOT EXISTS`（只按唯一键判存）。
        var conflict: ?[]const []const u8 = null;
        if (mode != .insert_ignore) {
            if (pks.len == 0) {
                std.debug.print("[zcode] upsertBatch：表 {s} 没有主键，无法做 {s}\n", .{ self.table_name, mode.name() });
                return error.NoPrimaryKey;
            }
            // 冲突目标（主键 → 唯一索引），只选「列都在插入列里」的
            conflict = try self.conflictColumnsAlloc(rows[0], pks);
            if (conflict == null and self.kind != .mysql) {
                std.debug.print(
                    "[zcode] upsertBatch：表 {s} 既无可用主键也无覆盖插入列的唯一索引，无法做 {s}" ++
                        "（MySQL 除外，它不需要冲突目标）\n",
                    .{ self.table_name, mode.name() },
                );
                return error.NoUniqueKey;
            }
        }
        defer if (conflict) |c| self.gpa.free(c);

        // 拦截器：与 insertBatch 一致地逐行补齐审计列
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

        switch (self.kind) {
            .sqlite, .mysql, .postgresql, .kingbase, .highgo, .vastbase => {},
            else => return self.upsertFallback(s, effective_rows, pks, conflict, mode),
        }

        var per_batch: usize = 5000;
        const param_limit = self.kind.maxStatementParams() / cols;
        if (param_limit > 0 and param_limit < per_batch) per_batch = param_limit;
        if (per_batch == 0) per_batch = 1;

        var affected: usize = 0;
        var start: usize = 0;
        while (start < effective_rows.len) {
            const end = @min(start + per_batch, effective_rows.len);
            const base = try sqlbuild.insertMultiWith(self.gpa, self.kind, self.table, self.table_name, effective_rows[start..end], .{ .allow_identity = true });
            defer base.deinit(self.gpa);

            const text = try self.upsertSqlAlloc(base.text, effective_rows[0], conflict, mode);
            defer self.gpa.free(text);

            affected += s.execute(text, base.params) catch |e| {
                std.debug.print(
                    "[zcode] upsertBatch 失败：表 {s} 模式 {s}\n  SQL: {s}\n  错误: {s}\n",
                    .{ self.table_name, mode.name(), text, s.lastError() },
                );
                return e;
            };
            start = end;
        }
        if (affected > 0) self.notifyWrite();
        return affected;
    }

    /// 选冲突目标：主键（列都在 row 里）→ 第一个可覆盖的唯一索引；都不行返回 null。
    fn conflictColumnsAlloc(
        self: *const TableRef,
        row: []const sqlbuild.Field,
        pks: []const *const ColumnMeta,
    ) !?[]const []const u8 {
        const all_present = struct {
            fn check(fields: []const sqlbuild.Field, names: []const []const u8) bool {
                for (names) |n| {
                    var hit = false;
                    for (fields) |f| {
                        if (std.ascii.eqlIgnoreCase(f.name, n)) hit = true;
                    }
                    if (!hit) return false;
                }
                return true;
            }
        }.check;

        // 1) 主键
        if (pks.len > 0) {
            const names = try self.gpa.alloc([]const u8, pks.len);
            for (pks, 0..) |pk, i| names[i] = self.table.effectiveColumnName(pk);
            if (all_present(row, names)) return names;
            self.gpa.free(names);
        }

        // 2) 唯一索引（按模型顺序取第一个可覆盖的）
        for (self.table.indexes) |idx| {
            if (!idx.unique) continue;
            var names = try self.gpa.alloc([]const u8, idx.columns.len);
            for (idx.columns, 0..) |c, i| {
                const col = self.table.column(c) orelse {
                    self.gpa.free(names);
                    names = &.{};
                    break;
                };
                names[i] = self.table.effectiveColumnName(col);
            }
            if (names.len == idx.columns.len and all_present(row, names)) return names;
            self.gpa.free(names);
        }
        return null;
    }

    /// 把多行 `INSERT INTO` 改写成对应方言的 upsert/ignore/replace 语句。
    fn upsertSqlAlloc(
        self: *const TableRef,
        insert_sql: []const u8,
        row: []const sqlbuild.Field,
        conflict: ?[]const []const u8,
        mode: SaveModes,
    ) ![]u8 {
        const gpa = self.gpa;
        const verb = "INSERT INTO ";
        const rest = if (std.mem.startsWith(u8, insert_sql, verb)) insert_sql[verb.len..] else insert_sql;

        var b = @import("zzig").Buf.init(gpa);
        defer b.deinit();

        switch (mode) {
            .replace => {
                if (self.kind == .sqlite) {
                    try b.add("INSERT OR REPLACE INTO ");
                    try b.add(rest);
                } else if (self.kind == .mysql) {
                    try b.add("REPLACE INTO ");
                    try b.add(rest);
                } else {
                    // PG 系没有 REPLACE：等价语义 = 冲突时更新全部非主键列
                    try b.add(insert_sql);
                    try self.pushConflictSuffix(&b, row, conflict);
                }
            },
            .insert_ignore => {
                if (self.kind == .sqlite) {
                    // 用 `ON CONFLICT DO NOTHING` 而**不是** `INSERT OR IGNORE`：
                    // 后者会把 NOT NULL / CHECK / 外键等**任意约束违反**也静默跳过，
                    // 调用方只看到「插入数少了一条」，查不出是「已存在」还是「数据坏了」。
                    // `ON CONFLICT DO NOTHING` 只忽略唯一/排他冲突，其它约束照常报错。
                    try b.add(insert_sql);
                    try b.add(" ON CONFLICT DO NOTHING");
                } else if (self.kind == .mysql) {
                    // MySQL 没有窄语义的「只忽略唯一键冲突」写法：
                    // `INSERT IGNORE` 会把数据截断、非法日期等也降级为 warning（数据风险），
                    // 但它是唯一能准确统计「插入条数」的形态（`ON DUPLICATE KEY UPDATE` 在
                    // `CLIENT_FOUND_ROWS` 下会把跳过也算成匹配行）。这里保留它并**明确告警**：
                    // 对数据质量敏感的表请改用 `.upsert` 或先清洗数据。
                    try b.add("INSERT IGNORE INTO ");
                    try b.add(rest);
                } else {
                    try b.add(insert_sql);
                    try b.add(" ON CONFLICT DO NOTHING");
                }
            },
            .upsert => {
                try b.add(insert_sql);
                try self.pushConflictSuffix(&b, row, conflict);
            },
            .insert => try b.add(insert_sql), // 已在上层分流，保持穷尽
        }
        return b.toOwnedSlice();
    }

    /// 追加冲突处理子句（`ON CONFLICT (...) DO UPDATE SET` / `ON DUPLICATE KEY UPDATE`）。
    ///
    /// 两种形态按服务端版本选：
    /// - **MySQL 8.0.19+**：`... VALUES (...) AS <别名> ON DUPLICATE KEY UPDATE c = <别名>.c`
    ///   （行别名；`VALUES(col)` 官方已标 deprecated）。别名固定 `zcode_new`——它不能与
    ///   表名相同（MySQL 规定），业务表也不会叫这个名字。
    /// - MySQL 5.7 / 8.0.18 / **MariaDB**：`c = VALUES(c)`（唯一可用的老写法）。
    ///
    /// **`conflict` 覆盖全部列时**（比如单列主键表只 upsert 主键）没有可更新列，
    /// `DO UPDATE SET` 后面会是空的 → 语法错。这里退化成「冲突就什么都不改」：
    /// MySQL 用第一列的恒等赋值，其它方言用 `ON CONFLICT (...) DO NOTHING`。
    fn pushConflictSuffix(
        self: *const TableRef,
        b: *@import("zzig").Buf,
        row: []const sqlbuild.Field,
        conflict: ?[]const []const u8,
    ) !void {
        const in_conflict = struct {
            fn call(cols: ?[]const []const u8, name: []const u8) bool {
                const list = cols orelse return false;
                for (list) |c| {
                    if (std.ascii.eqlIgnoreCase(c, name)) return true;
                }
                return false;
            }
        }.call;

        var updatable: usize = 0;
        for (row) |f| {
            if (!in_conflict(conflict, f.name)) updatable += 1;
        }

        const use_alias = self.kind == .mysql and self.features.mysql_row_alias;

        // 没有可更新列（典型：只写主键）：多数方言上**无法表达**，明确报错而不是发一条注定失败的 SQL。
        //
        // 实测结论（三方言）：
        // - MySQL 8.0.29 严格模式：先校验未提供列 → `ERROR 1364 Field 'X' doesn't have a default value`
        //   （即使原本会走 `ON DUPLICATE KEY UPDATE` 分支）；
        // - SQLite 3.49.1：`DO NOTHING` **不处理 rowid 冲突**（绕开冲突判定直接插入 → NOT NULL 失败），
        //   而 `DO UPDATE` 又没有列可写；
        // - 只有 PostgreSQL 系的 `ON CONFLICT (...) DO NOTHING` 行为正确（冲突时不插入 → 不校验列）。
        if (updatable == 0) {
            if (self.kind == .mysql or self.kind == .sqlite) {
                std.debug.print(
                    "[zcode] upsert 不可用：表 {s} 本次只写了冲突列本身，没有任何可更新的列。\n" ++
                        "  MySQL 严格模式会报 1364（未提供列无默认值）；SQLite 的 DO NOTHING 不处理 rowid 冲突、" ++
                        "DO UPDATE 又无列可写。\n" ++
                        "  处理方式：带上至少一个非冲突列（哪怕值不变），或改用带唯一索引列作为冲突目标。\n",
                    .{self.table_name},
                );
                return error.UpsertNeedsUpdatableColumn;
            }
            try self.pushConflictTarget(b, conflict);
            try b.add(" DO NOTHING");
            return;
        }

        if (self.kind == .mysql) {
            if (use_alias) {
                try b.add(" AS ");
                try b.add(mysql_row_alias);
                try b.add(" ON DUPLICATE KEY UPDATE ");
            } else {
                try b.add(" ON DUPLICATE KEY UPDATE ");
            }
        } else {
            try self.pushConflictTarget(b, conflict);
            try b.add(" DO UPDATE SET ");
        }

        var first = true;
        for (row) |f| {
            if (in_conflict(conflict, f.name)) continue;

            if (!first) try b.add(", ");
            first = false;
            const quoted = try self.kind.quoteAlloc(self.gpa, f.name);
            defer self.gpa.free(quoted);
            if (self.kind == .mysql) {
                try b.add(quoted);
                if (use_alias) {
                    try b.add(" = ");
                    try b.add(mysql_row_alias);
                    try b.add(".");
                    try b.add(quoted);
                } else {
                    try b.add(" = VALUES(");
                    try b.add(quoted);
                    try b.add(")");
                }
            } else {
                try b.add(quoted);
                try b.add(" = excluded.");
                try b.add(quoted);
            }
        }
    }

    /// `ON CONFLICT (<冲突列>)` 的公共前缀（SQLite / PG 系）。
    fn pushConflictTarget(self: *const TableRef, b: *@import("zzig").Buf, conflict: ?[]const []const u8) !void {
        try b.add(" ON CONFLICT (");
        if (conflict) |cols| {
            for (cols, 0..) |c, i| {
                if (i > 0) try b.add(", ");
                try self.kind.pushQuoted(b, c);
            }
        }
        try b.add(")");
    }

    /// 方言不支持 SQL 级 upsert 时的退路：同事务内逐行「先 UPDATE，未命中再 INSERT」。
    fn upsertFallback(
        self: *const TableRef,
        s: *Session,
        rows: []const []const sqlbuild.Field,
        pks: []const *const ColumnMeta,
        conflict: ?[]const []const u8,
        mode: SaveModes,
    ) !usize {
        // `insert_ignore` 走「一条语句判存 + 插入」：`INSERT ... SELECT ... WHERE NOT EXISTS (...)`
        // 既不是「先查再写」的 N 次往返，也**不会覆盖已存在的行**（旧实现会先 UPDATE，语义错）。
        if (mode == .insert_ignore) {
            const keys = conflict orelse {
                // 没有主键/唯一索引就没法判存：明确报错，不假装成功
                std.debug.print(
                    "[zcode] insert_ignore：表 {s} 没有主键也没有唯一索引，无法判断是否已存在\n",
                    .{self.table_name},
                );
                return error.NoUniqueKey;
            };

            var affected_ignore: usize = 0;
            var scoped_ignore = try Session.Scoped.begin(s);
            errdefer scoped_ignore.rollback();
            for (rows) |row| {
                const sql = sqlbuild.insertIfAbsent(self.gpa, self.kind, self.table, self.table_name, row, keys) catch |e| {
                    std.debug.print(
                        "[zcode] insert_ignore 组装失败：表 {s}，错误 {s}\n",
                        .{ self.table_name, @errorName(e) },
                    );
                    return e;
                };
                defer sql.deinit(self.gpa);
                affected_ignore += s.execute(sql.text, sql.params) catch |e| {
                    std.debug.print(
                        "[zcode] insert_ignore 失败：表 {s}\n  SQL: {s}\n  错误: {s}；{s}\n",
                        .{ self.table_name, sql.text, @errorName(e), s.lastError() },
                    );
                    return e;
                };
            }
            try scoped_ignore.commit();
            if (affected_ignore > 0) self.notifyWrite();
            return affected_ignore;
        }

        var affected: usize = 0;
        var scoped = try Session.Scoped.begin(s);
        errdefer scoped.rollback();

        for (rows) |row| {
            var w = Where.init(self.gpa);
            defer w.deinit();
            for (pks) |pk| {
                const name = self.table.effectiveColumnName(pk);
                var found: ?Value = null;
                for (row) |f| {
                    if (std.ascii.eqlIgnoreCase(f.name, name)) found = f.value;
                }
                if (found == null) return error.Model;
                _ = try w.eq(name, found.?);
            }

            var sets: std.ArrayList(sqlbuild.Field) = .empty;
            defer sets.deinit(self.gpa);
            for (row) |f| {
                var pk_hit = false;
                for (pks) |pk| {
                    if (std.ascii.eqlIgnoreCase(self.table.effectiveColumnName(pk), f.name)) pk_hit = true;
                }
                if (!pk_hit) try sets.append(self.gpa, f);
            }

            var n: usize = 0;
            if (sets.items.len > 0) {
                const sql = try sqlbuild.update(self.gpa, self.kind, self.table, self.table_name, sets.items, &w);
                defer sql.deinit(self.gpa);
                n = try s.execute(sql.text, sql.params);
            }
            if (n == 0) {
                const sql = try sqlbuild.insert(self.gpa, self.kind, self.table, self.table_name, row);
                defer sql.deinit(self.gpa);
                n = try s.execute(sql.text, sql.params);
            }
            affected += n;
        }
        try scoped.commit();
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

    /// 深分页查询结果：`reversed = true` 表示这次真的走了「倒序取尾部」分支（可直接写进日志/指标）。
    pub const DeepPageResult = struct {
        rows: []Row,
        reversed: bool,
    };

    /// 深分页查询（≂ C# `Entity.FindAll` 的「海量数据查询优化」）。
    ///
    /// 偏移落在表尾时**倒序取尾部、再把结果翻回正序**：扫描量从 `offset` 降到 `total - offset`。
    /// 亿级表翻到第 90 万页时这一条能把一次查询从「扫 90 万行」降到「扫几万行」。
    ///
    /// 前置条件：
    /// - `q.order_by` 非空（没有确定排序就不敢翻，直接按原样查）；
    /// - `total` 由调用方给（通常来自 `Dal.countTotal` / `countUpTo`；走缓存还是从库由调用方决定），
    ///   本函数**不自己发 COUNT**——亿级表上多一次 COUNT 就是多一次全扫。
    ///
    /// 返回的行已经按**原排序**排好，调用方无需再翻。
    pub fn queryDeepPage(
        self: *const TableRef,
        s: *Session,
        q: *const query.Query,
        total: i64,
        plan: @import("pagesplit.zig").DeepPage,
    ) !DeepPageResult {
        const offset = q.offset orelse 0;
        const page_size = q.limit orelse 0;
        const reversed_offset = plan.plan(offset, page_size, total) orelse return .{ .rows = try self.queryRows(s, q), .reversed = false };
        if (q.order_by.items.len == 0) return .{ .rows = try self.queryRows(s, q), .reversed = false };

        // 浅复制 Query：只把排序翻过来 + 换偏移，其余字段沿用原值
        var q2 = q.*;
        var flipped: std.ArrayList(query.OrderBy) = .empty;
        defer flipped.deinit(self.gpa);
        try flipped.ensureTotalCapacity(self.gpa, q.order_by.items.len);
        for (q.order_by.items) |ob| {
            flipped.appendAssumeCapacity(.{ .column = ob.column, .desc = !ob.desc });
        }
        q2.order_by = flipped;
        q2.offset = reversed_offset;

        const rows = try self.queryRows(s, &q2);
        // 倒序取回来的行翻回正序（原地交换）
        if (rows.len > 1) {
            var i: usize = 0;
            var j: usize = rows.len - 1;
            while (i < j) : ({
                i += 1;
                j -= 1;
            }) {
                const tmp = rows[i];
                rows[i] = rows[j];
                rows[j] = tmp;
            }
        }
        return .{ .rows = rows, .reversed = true };
    }

    /// 取一列的最大值（对应 C# `Entity.FindMax` 的用途：增量同步要「最大 ID / 最新时间」）。    ///
    /// 空表 / 无匹配行返回 `null`（C# 返回 0，无法区分「没有数据」和「值就是 0」；
    /// 这里用 `?Value` 把这个区分留给调用方）。
    pub fn maxValue(self: *const TableRef, s: *Session, column: []const u8, filter: ?*const Where) !?Value {
        return self.aggregateValue(s, .max, column, filter);
    }

    /// 取一列的最小值（语义同 `maxValue`）。
    pub fn minValue(self: *const TableRef, s: *Session, column: []const u8, filter: ?*const Where) !?Value {
        return self.aggregateValue(s, .min, column, filter);
    }

    /// 聚合取单值；`func == .count` 时忽略 `column`。
    pub fn aggregateValue(
        self: *const TableRef,
        s: *Session,
        func: sqlbuild.AggFunc,
        column: []const u8,
        filter: ?*const Where,
    ) !?Value {
        const sql = try sqlbuild.aggregate(self.gpa, self.kind, self.table, self.table_name, func, column, filter);
        defer sql.deinit(self.gpa);

        const rows = try s.queryRows(sql.text, sql.params);
        if (rows.len == 0 or rows[0].values.len == 0) return null;
        const v = rows[0].values[0];
        return switch (v) {
            .null => null,
            else => v,
        };
    }

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
        // GUID 在 Zig 侧就是字符串：驱动读回来若是 blob（如 SQL Server uniqueidentifier 的原始字节）
        // 或其它形态，统一转成文本，不做二进制 GUID 布局解析（各家字节序不同，猜必错）。
        .guid => switch (raw) {
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

test "InfluxDB：列按 时间 / 标签 / 字段 三种角色拼 Line Protocol" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const xml =
        \\<EntityModel><Tables><Table Name="Meter" TableName="MeterData">
        \\  <Columns>
        \\    <Column Name="DeviceId" DataType="String" Length="32" PrimaryKey="True" />
        \\    <Column Name="Current" DataType="Double" />
        \\    <Column Name="Online" DataType="Boolean" />
        \\    <Column Name="CreateTime" DataType="DateTime" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m = try model.EntityModel.parse(a, xml);
    defer {
        var mm = m;
        mm.deinit();
    }

    var t = TableRef.init(a, .influxdb, m.table("Meter").?);
    const line = try t.influxLineAlloc(arena.allocator(), &[_]sqlbuild.Field{
        .{ .name = "DeviceId", .value = .{ .text = "dev-1" } },
        .{ .name = "Current", .value = .{ .float = 12.5 } },
        .{ .name = "Online", .value = .{ .boolean = true } },
        .{ .name = "CreateTime", .value = .{ .datetime = DateTime.fromUnixSeconds(1_700_000_000) } },
    });

    // measurement 用物理表名；主键 → tag；其余 → field；时间列 → 行尾纳秒时间戳
    try std.testing.expectEqualStrings(
        "MeterData,DeviceId=dev-1 Current=12.5,Online=true 1700000000000000000",
        line,
    );

    // 没有任何 field 时明确报错（Line Protocol 不允许只有 tag + 时间）
    try std.testing.expectError(error.InfluxNoField, t.influxLineAlloc(arena.allocator(), &[_]sqlbuild.Field{
        .{ .name = "DeviceId", .value = .{ .text = "dev-1" } },
    }));
}
