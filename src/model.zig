//! 数据模型：`Model.xml`（XCode 数据建模文件）的解析、内存表示与写出。
//!
//! 文件结构与 DH.NCode / XCode 完全一致，可直接沿用 C# 项目里已有的 `Model.xml`：
//!
//! ```xml
//! <EntityModel xmlns="https://newlifex.com/Model202509.xsd">
//!   <Option>
//!     <Namespace>Demo.Entity</Namespace>
//!     <ConnName>DH</ConnName>
//!   </Option>
//!   <Tables>
//!     <Table Name="JiLiYu" TableName="DH_JiLiYu" Description="激励语">
//!       <Columns>
//!         <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" Description="编号" />
//!       </Columns>
//!       <Indexes>
//!         <Index Columns="Code" Unique="True" />
//!       </Indexes>
//!     </Table>
//!   </Tables>
//! </EntityModel>
//! ```
//!
//! 对齐要点（与 Rust `Pek.RCode/src/model.rs` 逐条一致）：
//! - 按 XML 局部名匹配，忽略命名空间版本差异（Model202509 等各期 XSD 均可）
//! - `Nullable` 缺省 `false`（即 NOT NULL）；`TableName` 缺省等于 `Name`
//! - 未知属性/元素一律忽略，且**未识别属性原样保留**（解析→写出不丢信息）
//! - 表达式索引必须显式 `Name`（库里读不回表达式，只能按名字幂等比对）
//! - 含 `DataScale` 为 `time`/`timeShard:` 的表强制 `MaxCacheCount = 0`（大表不缓存）
//!
//! 生命周期：`EntityModel` 自持一个 arena，所有字符串/数组都从它分配；`deinit` 一次性释放。

const std = @import("std");
const zzig = @import("zzig");
pub const DataType = @import("types.zig").DataType;
const Buf = @import("zzig").Buf;

pub const default_namespace = "https://newlifex.com/Model202509.xsd";

/// MySQL/InnoDB 服务器层单行大小上限（字节；TEXT/BLOB 只计 20 字节指针）。
pub const mysql_max_row_bytes: usize = 65_535;

/// 规范阈值：`String` 列长度超过它就必须用 `Text`（MySQL→`LONGTEXT`）。
pub const mysql_safe_varchar_chars: i32 = 2_000;

/// 迁移档位（对应 DH.NCode 的 `Migration`）。
///
/// 档位只能**按 rank 收紧**（`Off < ReadOnly < On < Full`）：表级配置可把全局档位调得更保守，
/// 但不能更激进（对齐 C# `ResolveMigration` 的 `min(table, global)`）。
pub const Migration = enum {
    off,
    read_only,
    on,
    full,

    pub fn parse(text: []const u8) ?Migration {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(t, "off")) return .off;
        if (std.ascii.eqlIgnoreCase(t, "readonly") or std.ascii.eqlIgnoreCase(t, "read_only")) return .read_only;
        if (std.ascii.eqlIgnoreCase(t, "on")) return .on;
        if (std.ascii.eqlIgnoreCase(t, "full")) return .full;
        return null;
    }

    pub fn name(self: Migration) []const u8 {
        return switch (self) {
            .off => "Off",
            .read_only => "ReadOnly",
            .on => "On",
            .full => "Full",
        };
    }

    /// 严格程度序号（越大越激进）。
    pub fn rank(self: Migration) u8 {
        return switch (self) {
            .off => 0,
            .read_only => 1,
            .on => 2,
            .full => 3,
        };
    }

    /// 是否只读档（不执行 DDL）。
    pub fn isReadOnly(self: Migration) bool {
        return self.rank() <= Migration.read_only.rank();
    }

    /// 是否允许执行 DDL。
    pub fn canExecute(self: Migration) bool {
        return !self.isReadOnly();
    }

    /// 是否只做「创建类」动作（`On` 及以下；删除/修改仅 `Full` 允许）。
    pub fn onlyCreate(self: Migration) bool {
        return self.rank() < Migration.full.rank();
    }

    /// 用表级档位收紧（表级只能更保守）。
    pub fn tighten(self: Migration, table_level: ?Migration) Migration {
        const t = table_level orelse return self;
        return if (t.rank() < self.rank()) t else self;
    }
};

/// 原样保留的键值对（`<Option>` 子元素、未识别的属性）。
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const ModelOptions = struct {
    raw: []const KeyValue = &.{},

    pub fn get(self: ModelOptions, name: []const u8) ?[]const u8 {
        for (self.raw) |kv| {
            if (std.mem.eql(u8, kv.key, name) and kv.value.len > 0) return kv.value;
        }
        return null;
    }

    pub fn namespace(self: ModelOptions) ?[]const u8 {
        return self.get("Namespace");
    }

    pub fn connName(self: ModelOptions) ?[]const u8 {
        return self.get("ConnName");
    }

    pub fn output(self: ModelOptions) ?[]const u8 {
        return self.get("Output");
    }

    pub fn baseClass(self: ModelOptions) ?[]const u8 {
        return self.get("BaseClass");
    }

    pub fn migration(self: ModelOptions) ?Migration {
        return if (self.get("Migration")) |v| Migration.parse(v) else null;
    }
};

pub const ColumnMeta = struct {
    name: []const u8,
    column_name: ?[]const u8 = null,
    data_type: DataType,
    raw_type: ?[]const u8 = null,
    length: i32 = 0,
    precision: i32 = 0,
    scale: i32 = 0,
    identity: bool = false,
    primary_key: bool = false,
    master: bool = false,
    nullable: bool = false,
    /// 模型里**是否显式写了 `Nullable` 属性**。
    ///
    /// C# 同源模型（如 `membership/Member.xml`）大量列不写 `Nullable`，而 C# XCode 对
    /// 不写的列按「引用类型 NULL / 值类型 NOT NULL + 默认值」生成 DDL。没有本标记时
    /// `nullable=false` 无法区分「显式 False」与「没写」，建表就会把可空列建成 NOT NULL。
    nullable_explicit: bool = false,
    /// 累加字段（C# `BindColumnAttribute.Additional`）：更新时按 `col = col + 值` 累加，
    /// 不做整体覆盖；统计类字段靠它避免「读-改-写」丢更新。
    additional: bool = false,
    default_value: ?[]const u8 = null,
    description: []const u8 = "",
    enum_type: ?[]const u8 = null,
    data_scale: ?[]const u8 = null,
    map: ?[]const u8 = null,
    show_in: ?[]const u8 = null,
    model: ?[]const u8 = null,
    category: ?[]const u8 = null,
    item_type: ?[]const u8 = null,
    using_cache: ?bool = null,
    extra: []const KeyValue = &.{},

    /// 该列在 MySQL 行内的估算字节数（varchar = 4n+2；Text/JSON 只计指针）。
    pub fn mysqlRowBytes(self: ColumnMeta) usize {
        return switch (self.data_type) {
            .string => if (self.length > 0) @as(usize, @intCast(self.length)) * 4 + 2 else 20,
            .json => 20,
            .binary => if (self.length > 0) @as(usize, @intCast(self.length)) else 20,
            else => 8,
        };
    }

    /// 是否「超宽 varchar」（规范要求改用 `Text`）。
    pub fn isWideVarchar(self: ColumnMeta) bool {
        return self.data_type == .string and self.length > mysql_safe_varchar_chars;
    }
};

pub const IndexMeta = struct {
    name: ?[]const u8 = null,
    columns: []const []const u8 = &.{},
    unique: bool = false,
    /// 表达式索引（MySQL 函数索引 / JSON 多值索引）；与 `columns` 互斥。
    expression: ?[]const u8 = null,
};

pub const TableMeta = struct {
    name: []const u8,
    table_name: []const u8,
    description: []const u8 = "",
    conn_name: ?[]const u8 = null,
    base_type: ?[]const u8 = null,
    migration: ?Migration = null,
    insert_only: bool = false,
    is_view: bool = false,
    max_cache_count: i32 = 1000,
    columns: []const ColumnMeta = &.{},
    indexes: []const IndexMeta = &.{},
    extra: []const KeyValue = &.{},

    /// 数据库实际表名（`TableName` 为空时退回 `Name`）。
    pub fn effectiveTableName(self: *const TableMeta) []const u8 {
        return if (self.table_name.len == 0) self.name else self.table_name;
    }

    /// 数据库实际列名（`ColumnName` 为空时退回 `Name`）。
    pub fn effectiveColumnName(self: *const TableMeta, col: *const ColumnMeta) []const u8 {
        _ = self;
        if (col.column_name) |v| {
            if (v.len > 0) return v;
        }
        return col.name;
    }

    /// 按列名查找（忽略大小写；`Name` 或 `ColumnName` 均匹配）。
    pub fn column(self: *const TableMeta, name: []const u8) ?*const ColumnMeta {
        for (self.columns) |*c| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
            if (c.column_name) |cn| {
                if (std.ascii.eqlIgnoreCase(cn, name)) return c;
            }
        }
        return null;
    }

    /// 主键列（按声明顺序）。
    pub fn primaryKeys(self: *const TableMeta, gpa: std.mem.Allocator) ![]const *const ColumnMeta {
        var list: std.ArrayList(*const ColumnMeta) = .empty;
        errdefer list.deinit(gpa);
        for (self.columns) |*c| {
            if (c.primary_key) try list.append(gpa, c);
        }
        return list.toOwnedSlice(gpa);
    }

    /// 自增列（若有）。
    pub fn identity(self: *const TableMeta) ?*const ColumnMeta {
        for (self.columns) |*c| {
            if (c.identity) return c;
        }
        return null;
    }

    /// 累加字段列表（对应 C# `Meta.Factory.AdditionalFields`）。
    pub fn additionalFields(self: *const TableMeta, gpa: std.mem.Allocator) ![]const *const ColumnMeta {
        var list: std.ArrayList(*const ColumnMeta) = .empty;
        errdefer list.deinit(gpa);
        for (self.columns) |*c| {
            if (c.additional) try list.append(gpa, c);
        }
        return list.toOwnedSlice(gpa);
    }

    /// 整表按 MySQL utf8mb4 估算的行内字节数。
    pub fn mysqlRowBytes(self: *const TableMeta) usize {
        var total: usize = 0;
        for (self.columns) |c| total += c.mysqlRowBytes();
        return total;
    }

    /// 超过 MySQL 单行上限时的可读说明（未超限返回 null）。
    pub fn mysqlRowSizeIssue(self: *const TableMeta, gpa: std.mem.Allocator) !?[]u8 {
        const bytes = self.mysqlRowBytes();
        if (bytes <= mysql_max_row_bytes) return null;
        var widest: [5][]const u8 = undefined;
        var count: usize = 0;
        for (self.columns) |c| {
            if (c.data_type != .string or c.length <= 0) continue;
            if (count < widest.len) {
                widest[count] = c.name;
                count += 1;
            }
        }
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(gpa);
        for (widest[0..count], 0..) |n, i| {
            if (i > 0) try names.appendSlice(gpa, ", ");
            try names.appendSlice(gpa, n);
        }
        return try std.fmt.allocPrint(gpa, "表 {s} 按 MySQL utf8mb4 估算行内占用 {d} 字节，超过上限 {d} 字节（varchar 按 4 字节/字符计）；请把最长文本列改用 DataType=\"Text\"（MySQL→LONGTEXT）：{s}", .{ self.effectiveTableName(), bytes, mysql_max_row_bytes, names.items });
    }
};

pub const EntityModel = struct {
    arena: std.heap.ArenaAllocator,
    version: ?[]const u8 = null,
    model_version: ?[]const u8 = null,
    document: ?[]const u8 = null,
    options: ModelOptions = .{},
    tables: []TableMeta = &.{},

    /// 从 XML 文本解析（`gpa` 只用于 arena 的底层分配）。
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) !EntityModel {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const doc = try zzig.xml.parse(a, text);
        // doc 的 arena 是 a 的子分配器；随 EntityModel.deinit 一并释放，无需单独 deinit
        const root = doc.root;
        if (!std.ascii.eqlIgnoreCase(root.name, "EntityModel")) return error.InvalidModel;

        var options: std.ArrayList(KeyValue) = .empty;
        var tables: std.ArrayList(TableMeta) = .empty;

        for (root.children) |child_node| {
            const child = child_node.asElement() orelse continue;
            if (std.mem.eql(u8, child.name, "Option")) {
                for (child.children) |opt_node| {
                    const opt = opt_node.asElement() orelse continue;
                    const value = textOf(opt);
                    try options.append(a, .{ .key = opt.name, .value = value });
                }
            } else if (std.mem.eql(u8, child.name, "Tables")) {
                for (child.children) |table_node| {
                    const te = table_node.asElement() orelse continue;
                    if (!std.mem.eql(u8, te.name, "Table")) continue;
                    try tables.append(a, try parseTable(a, te));
                }
            }
        }

        // 注意：arena 必须在**所有分配完成之后**整体移入返回值，
        // 中途复制 ArenaAllocator 会让后续分配只更新副本的 buffer_list（实测会泄漏）
        return EntityModel{
            .arena = arena,
            .version = attrString(root, "Version"),
            .model_version = attrString(root, "ModelVersion"),
            .document = attrString(root, "Document"),
            .options = .{ .raw = try options.toOwnedSlice(a) },
            .tables = try tables.toOwnedSlice(a),
        };
    }

    /// 从文件加载。
    pub fn load(gpa: std.mem.Allocator, path: []const u8) !EntityModel {
        const text = try zzig.File.ReadAllAlloc(gpa, path, 64 * 1024 * 1024);
        defer gpa.free(text);
        return parse(gpa, text);
    }

    pub fn deinit(self: *EntityModel) void {
        self.arena.deinit();
    }

    /// 按实体名或物理表名查找（忽略大小写）。
    pub fn table(self: *const EntityModel, name: []const u8) ?*const TableMeta {
        for (self.tables) |*t| {
            if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
            if (std.ascii.eqlIgnoreCase(t.effectiveTableName(), name)) return t;
        }
        return null;
    }

    /// 模型级连接名（`<Option><ConnName>`，缺省/空白返回 null）。
    pub fn modelConn(self: *const EntityModel) ?[]const u8 {
        const v = self.options.connName() orelse return null;
        const t = std.mem.trim(u8, v, " \t\r\n");
        return if (t.len == 0) null else t;
    }

    /// 某张表**实际归属**的连接名：表级 `ConnName` 优先，否则取模型级 `ConnName`。
    ///
    /// 这就是 C# `DH.NCode` 的「`TableItem.ConnName` 缺省用 `EntityModel.ConnName`」；
    /// 建表/迁移与面板「表在哪个库」必须是**同一条规则**，所以只在这里实现一次。
    /// 两级都没配时返回 null（= 由调用方自己的默认连接代管）。
    pub fn tableConn(self: *const EntityModel, meta: *const TableMeta) ?[]const u8 {
        if (meta.conn_name) |c| {
            const t = std.mem.trim(u8, c, " \t\r\n");
            if (t.len > 0) return t;
        }
        return self.modelConn();
    }

    /// **按 C# XCode 的列语义补全模型**（就地修改）。
    ///
    /// 为什么需要：C# 同源模型（`membership/Member.xml`）大量列**不写 `Nullable` / `DefaultValue`**，
    /// 而 C# 的建表规则是「**引用类型默认 NULL；值类型默认 NOT NULL + 默认值 0**」。
    /// Zig 侧若直接按「没写 = NOT NULL」建表，`User.Password` / `User.DisplayName` 这类列会被建成
    /// `NOT NULL`，随后 C# 往同一张表写 NULL 就报错 —— 表结构复用就断了。
    ///
    /// 规则（**只补没显式写的**，写了 `Nullable` / `DefaultValue` 的列原样保留）：
    /// - 值类型（`boolean` / `byte` / `int16` / `int32` / `int64` / `single` / `double` / `decimal`）
    ///   → NOT NULL + `DefaultValue = "0"`（对齐 C# 生成的 `... NOT NULL DEFAULT 0`）；
    /// - 其它（`string` / `datetime` / `guid` / `binary` / `json`）→ 可空（对齐 C# 生成的 `... NULL`）。
    ///
    /// 幂等：重复调用结果不变。建表/迁移前调用一次即可。
    pub fn applyCsharpColumnDefaults(self: *EntityModel) void {
        for (self.tables) |*tbl| {
            const cols = @constCast(tbl.columns);
            for (cols) |*col| {
                if (col.primary_key or col.identity) continue;
                if (!col.nullable_explicit) {
                    col.nullable = switch (col.data_type) {
                        .boolean, .byte, .int16, .int32, .int64, .single, .double, .decimal => false,
                        else => true,
                    };
                }
                if (col.default_value == null) {
                    switch (col.data_type) {
                        .boolean, .byte, .int16, .int32, .int64, .single, .double, .decimal => col.default_value = "0",
                        else => {},
                    }
                }
            }
        }
    }

    /// 实体并入模型的统计（日志 / 测试用）。
    pub const MergeEntityReport = struct {
        /// 模型里没有、由实体补上的表
        tables_added: usize = 0,
        /// 模型里已有、被实体补列的表
        tables_merged: usize = 0,
        /// 实体补进来的列（XML 里没有）
        columns_added: usize = 0,
        /// 实体补进来的索引
        indexes_added: usize = 0,
    };

    /// 把**编译期实体**（`{表}.zig` 的 `meta` / `indexes` / `max_cache_count`）并入模型。
    ///
    /// 口径：建表 = **`Model.xml` ∪ 实体**，两边谁都不许单方面把表/列「删掉」。
    /// 因为 `Model.xml` 可能被人为清理掉表或列，而实体仍被业务代码引用 —— 此时表/列不能消失；
    /// 反过来 XML 里还有实体表达不了的信息（`ConnName` / `Migration` / `DefaultValue` / `EnumType`
    /// / `DataScale` / 描述），所以**同名表/列一律保留 XML 的定义**，实体只补「XML 里没有的」。
    ///
    /// 合并规则：
    /// - 模型里**没有**的表 → 按实体追加上（`tables_added`）；
    /// - 模型里**已有**的表 → 只追加 XML 缺的列（`columns_added`），同名列保留 XML；
    /// - 索引取并集（按「列组合 + unique」去重）；
    /// - `max_cache_count`：XML 用默认值（1000）时才采用实体给的更具体值。
    ///
    /// `nullable`：实体补进来的列里，`true` 记为显式（保留可空）；`false` 视为「没写」，
    /// 交给 [`applyCsharpColumnDefaults`] 按 C# 口径判定（否则会把 C# 同源的可空列建成 NOT NULL）。
    pub fn mergeEntityTypes(self: *EntityModel, comptime types: anytype) !MergeEntityReport {
        const a = self.arena.allocator();
        var report = MergeEntityReport{};
        var tables: std.ArrayList(TableMeta) = .empty;
        try tables.appendSlice(a, self.tables);

        inline for (types) |T| {
            const em = @field(T, "meta");

            // 实体列（字符串全部复制进 arena；实体是 comptime 常量，不能直接借它的内存）
            var ent_cols: std.ArrayList(ColumnMeta) = .empty;
            inline for (em.fields) |f| {
                try ent_cols.append(a, .{
                    .name = try a.dupe(u8, f.name),
                    .column_name = if (f.column_name) |cn| try a.dupe(u8, cn) else null,
                    .data_type = f.data_type,
                    .length = f.length,
                    .precision = f.precision,
                    .scale = f.scale,
                    .identity = f.identity,
                    .primary_key = f.primary_key,
                    .nullable = f.nullable,
                    // 只有「显式 true」才算显式；false 交给 C# 默认口径推断
                    .nullable_explicit = f.nullable,
                    .additional = f.additional,
                    .description = try a.dupe(u8, f.description),
                });
            }

            // 实体索引
            var ent_indexes: std.ArrayList(IndexMeta) = .empty;
            if (@hasDecl(T, "indexes")) {
                inline for (@field(T, "indexes")) |info| {
                    const idx_cols = try a.alloc([]const u8, info.columns.len);
                    inline for (info.columns, 0..) |c, k| idx_cols[k] = try a.dupe(u8, c);
                    try ent_indexes.append(a, .{
                        .name = if (info.name.len > 0) try a.dupe(u8, info.name) else null,
                        .columns = idx_cols,
                        .unique = info.unique,
                        .expression = if (info.expression) |e| try a.dupe(u8, e) else null,
                    });
                }
            }

            const cache: i32 = if (@hasDecl(T, "max_cache_count")) @field(T, "max_cache_count") else 1000;

            // 定位同名表（物理表名 / 逻辑名任一相同即视为同一张表）
            var hit: ?usize = null;
            for (tables.items, 0..) |t, i| {
                const tn = t.effectiveTableName();
                if (std.ascii.eqlIgnoreCase(tn, em.table_name) or
                    std.ascii.eqlIgnoreCase(tn, em.name) or
                    std.ascii.eqlIgnoreCase(t.name, em.name))
                {
                    hit = i;
                    break;
                }
            }

            if (hit) |i| {
                const t = &tables.items[i];
                // 1) XML 的列**原样保留**（信息更全：DefaultValue / EnumType / DataScale …）
                var final_cols: std.ArrayList(ColumnMeta) = .empty;
                try final_cols.appendSlice(a, t.columns);
                // 2) 只追加 XML 里没有的列（XML 被清理掉列时，靠这一步补回来）
                for (ent_cols.items) |ec| {
                    var exists = false;
                    for (t.columns) |xc| {
                        if (std.ascii.eqlIgnoreCase(xc.name, ec.name)) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) {
                        try final_cols.append(a, ec);
                        report.columns_added += 1;
                    }
                }
                t.columns = try final_cols.toOwnedSlice(a);

                // 3) 索引并集（按「列组合 + unique」去重）
                var final_idx: std.ArrayList(IndexMeta) = .empty;
                try final_idx.appendSlice(a, t.indexes);
                for (ent_indexes.items) |ei| {
                    var dup = false;
                    for (t.indexes) |xi| {
                        if (xi.unique == ei.unique and sameColumns(xi.columns, ei.columns)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        try final_idx.append(a, ei);
                        report.indexes_added += 1;
                    }
                }
                t.indexes = try final_idx.toOwnedSlice(a);
                // 实体给了更具体的缓存上限才覆盖（XML 未写时是默认 1000）
                if (t.max_cache_count == 1000) t.max_cache_count = cache;
                report.tables_merged += 1;
            } else {
                try tables.append(a, .{
                    .name = try a.dupe(u8, em.name),
                    .table_name = try a.dupe(u8, em.table_name),
                    .max_cache_count = cache,
                    .columns = try ent_cols.toOwnedSlice(a),
                    .indexes = try ent_indexes.toOwnedSlice(a),
                });
                report.tables_added += 1;
            }
        }

        self.tables = try tables.toOwnedSlice(a);
        return report;
    }

    /// 两组列名是否等价（忽略大小写与顺序）。
    fn sameColumns(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a) |x| {
            var found = false;
            for (b) |y| {
                if (std.ascii.eqlIgnoreCase(x, y)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    /// 表是否归属指定连接（忽略大小写；两级都没配视为归属）。
    pub fn tableBelongsToConn(self: *const EntityModel, meta: *const TableMeta, conn: []const u8) bool {
        const target = std.mem.trim(u8, conn, " \t\r\n");
        const own = self.tableConn(meta) orelse return true;
        return std.ascii.eqlIgnoreCase(own, target);
    }

    /// 归属指定连接的全部表（表级 `ConnName` 优先，否则模型级；两级都没配视为归属）。
    ///
    /// 盘点/迁移「只处理本库的表」、面板按连接看表都用它，口径与建表一致。
    pub fn tablesOfConn(self: *const EntityModel, gpa: std.mem.Allocator, conn: []const u8) ![]*const TableMeta {
        var list: std.ArrayList(*const TableMeta) = .empty;
        errdefer list.deinit(gpa);
        for (self.tables) |*t| {
            if (self.tableBelongsToConn(t, conn)) try list.append(gpa, t);
        }
        return list.toOwnedSlice(gpa);
    }

    /// 全部表的 MySQL 行大小问题（空 = 通过；视图不参与）。
    pub fn mysqlRowSizeIssues(self: *const EntityModel, gpa: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        for (self.tables) |*t| {
            if (t.is_view) continue;
            if (try t.mysqlRowSizeIssue(gpa)) |issue| try list.append(gpa, issue);
        }
        return list.toOwnedSlice(gpa);
    }

    /// 序列化为 Model.xml 文本（与 C# / Rust 版可互读）。
    pub fn toXmlAlloc(self: *const EntityModel, gpa: std.mem.Allocator) ![]u8 {
        var b = Buf.init(gpa);
        defer b.deinit();

        try b.add("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<EntityModel xmlns=\"");
        try b.add(default_namespace);
        try b.add("\"");
        try writeAttr(&b, "Version", self.version);
        try writeAttr(&b, "ModelVersion", self.model_version);
        try writeAttr(&b, "Document", self.document);
        try b.add(">\n");

        try b.add("  <Option>\n");
        for (self.options.raw) |kv| {
            try b.fmt("    <{s}>{s}</{s}>\n", .{ kv.key, kv.value, kv.key });
        }
        try b.add("  </Option>\n");

        try b.add("  <Tables>\n");
        for (self.tables) |t| {
            try b.add("    <Table");
            try writeAttr(&b, "Name", t.name);
            if (!std.mem.eql(u8, t.table_name, t.name)) try writeAttr(&b, "TableName", t.table_name);
            try writeAttr(&b, "Description", t.description);
            try writeAttr(&b, "ConnName", t.conn_name);
            try writeAttr(&b, "BaseType", t.base_type);
            if (t.migration) |m| try writeAttr(&b, "Migration", m.name());
            if (t.insert_only) try writeAttr(&b, "InsertOnly", "True");
            if (t.is_view) try writeAttr(&b, "IsView", "True");
            if (t.max_cache_count != 1000) try b.fmt(" MaxCacheCount=\"{d}\"", .{t.max_cache_count});
            for (t.extra) |kv| try b.fmt(" {s}=\"{s}\"", .{ kv.key, kv.value });
            try b.add(">\n");

            try b.add("      <Columns>\n");
            for (t.columns) |c| {
                try b.add("        <Column");
                try writeAttr(&b, "Name", c.name);
                try writeAttr(&b, "ColumnName", c.column_name);
                try writeAttr(&b, "DataType", c.data_type.name());
                try writeAttr(&b, "RawType", c.raw_type);
                if (c.length > 0) try b.fmt(" Length=\"{d}\"", .{c.length});
                if (c.precision > 0) try b.fmt(" Precision=\"{d}\"", .{c.precision});
                if (c.scale > 0) try b.fmt(" Scale=\"{d}\"", .{c.scale});
                if (c.identity) try writeAttr(&b, "Identity", "True");
                if (c.primary_key) try writeAttr(&b, "PrimaryKey", "True");
                if (c.master) try writeAttr(&b, "Master", "True");
                if (c.nullable) try writeAttr(&b, "Nullable", "True");
                if (c.additional) try writeAttr(&b, "Additional", "True");
                try writeAttr(&b, "DefaultValue", c.default_value);
                try writeAttr(&b, "Type", c.enum_type);
                try writeAttr(&b, "DataScale", c.data_scale);
                try writeAttr(&b, "Map", c.map);
                try writeAttr(&b, "ShowIn", c.show_in);
                try writeAttr(&b, "Model", c.model);
                try writeAttr(&b, "Category", c.category);
                try writeAttr(&b, "ItemType", c.item_type);
                if (c.using_cache) |uc| try writeAttr(&b, "UsingCache", if (uc) "True" else "False");
                try writeAttr(&b, "Description", c.description);
                for (c.extra) |kv| try b.fmt(" {s}=\"{s}\"", .{ kv.key, kv.value });
                try b.add(" />\n");
            }
            try b.add("      </Columns>\n");

            if (t.indexes.len > 0) {
                try b.add("      <Indexes>\n");
                for (t.indexes) |idx| {
                    try b.add("        <Index");
                    try writeAttr(&b, "Name", idx.name);
                    if (idx.columns.len > 0) {
                        try b.add(" Columns=\"");
                        for (idx.columns, 0..) |col, i| {
                            if (i > 0) try b.add(",");
                            try b.add(col);
                        }
                        try b.add("\"");
                    }
                    if (idx.unique) try writeAttr(&b, "Unique", "True");
                    try writeAttr(&b, "Expression", idx.expression);
                    try b.add(" />\n");
                }
                try b.add("      </Indexes>\n");
            }
            try b.add("    </Table>\n");
        }
        try b.add("  </Tables>\n</EntityModel>\n");

        return b.toOwnedSlice();
    }
};

fn parseTable(a: std.mem.Allocator, e: *const zzig.xml.Dom.Element) !TableMeta {
    const name = attrString(e, "Name") orelse return error.InvalidModel;
    const table_name = attrString(e, "TableName") orelse name;

    var table = TableMeta{
        .name = name,
        .table_name = table_name,
        .description = attrString(e, "Description") orelse "",
        .conn_name = attrString(e, "ConnName"),
        .base_type = attrString(e, "BaseType"),
        .migration = if (attrString(e, "Migration")) |v| Migration.parse(v) else null,
        .insert_only = attrBool(e, "InsertOnly"),
        .is_view = attrBool(e, "IsView") or (name.len > 0 and name[0] == '#'),
        .max_cache_count = if (attrString(e, "MaxCacheCount")) |v| (std.fmt.parseInt(i32, v, 10) catch 1000) else 1000,
    };

    var cols: std.ArrayList(ColumnMeta) = .empty;
    var idxs: std.ArrayList(IndexMeta) = .empty;

    for (e.children) |child_node| {
        const child = child_node.asElement() orelse continue;
        if (std.mem.eql(u8, child.name, "Columns")) {
            for (child.children) |col_node| {
                const ce = col_node.asElement() orelse continue;
                if (!std.mem.eql(u8, ce.name, "Column")) continue;
                try cols.append(a, try parseColumn(a, ce, table.name));
            }
        } else if (std.mem.eql(u8, child.name, "Indexes")) {
            for (child.children) |idx_node| {
                const ie = idx_node.asElement() orelse continue;
                if (!std.mem.eql(u8, ie.name, "Index")) continue;
                const idx = try parseIndex(a, ie);
                if (idx.expression != null and idx.name == null) return error.InvalidModel;
                try idxs.append(a, idx);
            }
        }
    }

    if (cols.items.len == 0) return error.InvalidModel;

    table.columns = try cols.toOwnedSlice(a);
    table.indexes = try idxs.toOwnedSlice(a);
    table.extra = try collectExtra(a, e, &table_known_attrs);

    // 大表（时序/时序分表）不参与实体缓存（对齐 C# EntityBuilder.Prepare）
    if (table.max_cache_count > 0) {
        for (table.columns) |c| {
            if (c.data_scale) |ds| {
                const v = std.mem.trim(u8, ds, " \t\r\n");
                if (std.ascii.eqlIgnoreCase(v, "time") or startsWithIgnoreCase(v, "time:") or startsWithIgnoreCase(v, "timeshard:")) {
                    table.max_cache_count = 0;
                    break;
                }
            }
        }
    }
    return table;
}

fn parseColumn(a: std.mem.Allocator, e: *const zzig.xml.Dom.Element, table_name: []const u8) !ColumnMeta {
    _ = table_name;
    const name = attrString(e, "Name") orelse return error.InvalidModel;
    const type_text = attrString(e, "DataType") orelse return error.InvalidModel;
    const data_type = DataType.fromName(type_text) catch return error.InvalidModel;

    var col = ColumnMeta{
        .name = name,
        .column_name = attrString(e, "ColumnName"),
        .data_type = data_type,
        .raw_type = attrString(e, "RawType"),
        .length = attrI32(e, "Length"),
        .precision = attrI32(e, "Precision"),
        .scale = attrI32(e, "Scale"),
        .identity = attrBool(e, "Identity"),
        .primary_key = attrBool(e, "PrimaryKey"),
        .master = attrBool(e, "Master"),
        .nullable = attrBool(e, "Nullable"),
        .nullable_explicit = attrString(e, "Nullable") != null,
        .additional = attrBool(e, "Additional"),
        .default_value = attrString(e, "DefaultValue"),
        .description = attrString(e, "Description") orelse "",
        .enum_type = attrString(e, "Type"),
        .data_scale = attrString(e, "DataScale"),
        .map = attrString(e, "Map"),
        .show_in = attrString(e, "ShowIn"),
        .model = attrString(e, "Model"),
        .category = attrString(e, "Category"),
        .item_type = attrString(e, "ItemType"),
        .using_cache = if (attrString(e, "UsingCache")) |_| attrBool(e, "UsingCache") else null,
    };
    col.extra = try collectExtra(a, e, &column_known_attrs);
    return col;
}

fn parseIndex(a: std.mem.Allocator, e: *const zzig.xml.Dom.Element) !IndexMeta {
    var idx = IndexMeta{
        .name = attrString(e, "Name"),
        .unique = attrBool(e, "Unique"),
        .expression = attrString(e, "Expression"),
    };
    if (attrString(e, "Columns")) |cols| {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, cols, ',');
        while (it.next()) |raw| {
            const part = std.mem.trim(u8, raw, " \t\r\n");
            if (part.len > 0) try list.append(a, part);
        }
        idx.columns = try list.toOwnedSlice(a);
    }
    return idx;
}

const table_known_attrs = [_][]const u8{
    "Name",      "TableName",  "Description", "ConnName",      "BaseType",
    "Migration", "InsertOnly", "IsView",      "MaxCacheCount",
};

const column_known_attrs = [_][]const u8{
    "Name",       "ColumnName",   "DataType", "RawType",    "Length",
    "Precision",  "Scale",        "Identity", "PrimaryKey", "Master",
    "Nullable",   "DefaultValue", "Type",     "DataScale",  "Map",
    "ShowIn",     "Model",        "Category", "ItemType",   "UsingCache",
    "Additional", "Description",
};

/// 收集未识别属性（跳过 `xmlns*` 与带前缀的属性）。
fn collectExtra(a: std.mem.Allocator, e: *const zzig.xml.Dom.Element, known: []const []const u8) ![]KeyValue {
    var list: std.ArrayList(KeyValue) = .empty;
    for (e.attributes) |attribute| {
        if (std.mem.indexOfScalar(u8, attribute.name, ':') != null) continue;
        var is_known = false;
        for (known) |k| {
            if (std.mem.eql(u8, k, attribute.name)) {
                is_known = true;
                break;
            }
        }
        if (is_known) continue;
        try list.append(a, .{ .key = attribute.name, .value = attribute.value });
    }
    return list.toOwnedSlice(a);
}

fn attrString(e: *const zzig.xml.Dom.Element, name: []const u8) ?[]const u8 {
    const raw = e.attr(name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn attrBool(e: *const zzig.xml.Dom.Element, name: []const u8) bool {
    const v = attrString(e, name) orelse return false;
    return std.ascii.eqlIgnoreCase(v, "true") or std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "yes");
}

fn attrI32(e: *const zzig.xml.Dom.Element, name: []const u8) i32 {
    const v = attrString(e, name) orelse return 0;
    return std.fmt.parseInt(i32, v, 10) catch 0;
}

fn textOf(e: *const zzig.xml.Dom.Element) []const u8 {
    for (e.children) |node| {
        if (node.asText()) |t| return std.mem.trim(u8, t, " \t\r\n");
    }
    return "";
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn writeAttr(b: *Buf, name: []const u8, value: ?[]const u8) !void {
    const v = value orelse return;
    if (v.len == 0) return;
    try b.fmt(" {s}=\"{s}\"", .{ name, v });
}

test "解析 C# 风格 Model.xml 基本语义" {
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd" Version="1.0">
        \\  <Option>
        \\    <Namespace>XCode.Membership</Namespace>
        \\    <ConnName>Membership</ConnName>
        \\  </Option>
        \\  <Tables>
        \\    <Table Name="JiLiYu" TableName="DH_JiLiYu" Description="激励语">
        \\      <Columns>
        \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" Description="编号" />
        \\        <Column Name="Code" DataType="String" Length="50" Master="True" Description="编码" />
        \\        <Column Name="CreateTime" DataType="DateTime" Description="创建时间" />
        \\        <Column Name="Extra" DataType="Int32" Foo="Bar" />
        \\      </Columns>
        \\      <Indexes>
        \\        <Index Columns="Code" Unique="True" />
        \\      </Indexes>
        \\    </Table>
        \\  </Tables>
        \\</EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 1), m.tables.len);
    try std.testing.expectEqualStrings("Membership", m.options.connName().?);

    const t = m.table("JiLiYu").?;
    try std.testing.expectEqualStrings("DH_JiLiYu", t.effectiveTableName());
    try std.testing.expectEqual(@as(usize, 4), t.columns.len);
    try std.testing.expect(t.identity().?.identity);
    try std.testing.expect(!t.column("Code").?.nullable);
    try std.testing.expectEqual(@as(usize, 1), t.indexes.len);
    try std.testing.expect(t.indexes[0].unique);
    // 未识别属性原样保留
    try std.testing.expectEqual(@as(usize, 1), t.column("Extra").?.extra.len);
    try std.testing.expectEqualStrings("Foo", t.column("Extra").?.extra[0].key);
}

test "表达式索引必须显式命名" {
    const xml =
        \\<EntityModel><Tables><Table Name="T">
        \\  <Columns><Column Name="Id" DataType="Int32" PrimaryKey="True" /></Columns>
        \\  <Indexes><Index Expression="CAST(Payload-&gt;'$.c' AS UNSIGNED)" /></Indexes>
        \\</Table></Tables></EntityModel>
    ;
    try std.testing.expectError(error.InvalidModel, EntityModel.parse(std.testing.allocator, xml));
}

// 「表在哪个连接」只有一条规则：表级 `ConnName` 优先，否则模型级；两级都没配 = 归调用方的连接。
//
// 与 Rust `Pek.RCode` 的同名 API 语义逐条对齐（建表/迁移/面板必须同一口径）。
test "表归属连接：表级优先，否则模型级" {
    const xml =
        \\<EntityModel>
        \\  <Option><ConnName>Proxy</ConnName></Option>
        \\  <Tables>
        \\    <Table Name="Usage" TableName="DH_Usage">
        \\      <Columns><Column Name="Id" DataType="Int32" PrimaryKey="True" /></Columns>
        \\    </Table>
        \\    <Table Name="UserEx" TableName="DH_UserEx" ConnName="DH">
        \\      <Columns><Column Name="Id" DataType="Int32" PrimaryKey="True" /></Columns>
        \\    </Table>
        \\  </Tables>
        \\</EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();

    try std.testing.expectEqualStrings("Proxy", m.modelConn().?);

    const usage = m.table("Usage").?;
    const user_ex = m.table("DH_UserEx").?;

    // 表级优先：UserEx 归 DH，尽管模型级是 Proxy
    try std.testing.expectEqualStrings("DH", m.tableConn(user_ex).?);
    try std.testing.expectEqualStrings("Proxy", m.tableConn(usage).?);

    // 连接名忽略大小写
    try std.testing.expect(m.tableBelongsToConn(usage, "proxy"));
    try std.testing.expect(!m.tableBelongsToConn(usage, "DH"));
    try std.testing.expect(m.tableBelongsToConn(user_ex, "dh"));
    try std.testing.expect(!m.tableBelongsToConn(user_ex, "Proxy"));

    const of_proxy = try m.tablesOfConn(std.testing.allocator, "Proxy");
    defer std.testing.allocator.free(of_proxy);
    try std.testing.expectEqual(@as(usize, 1), of_proxy.len);
    try std.testing.expectEqualStrings("Usage", of_proxy[0].name);

    const of_dh = try m.tablesOfConn(std.testing.allocator, "DH");
    defer std.testing.allocator.free(of_dh);
    try std.testing.expectEqual(@as(usize, 1), of_dh.len);
    try std.testing.expectEqualStrings("UserEx", of_dh[0].name);

    // 两级都没配：由调用方的默认连接代管（不丢表）
    const plain =
        \\<EntityModel><Tables><Table Name="Only">
        \\  <Columns><Column Name="Id" DataType="Int32" /></Columns></Table></Tables></EntityModel>
    ;
    var p = try EntityModel.parse(std.testing.allocator, plain);
    defer p.deinit();
    try std.testing.expect(p.modelConn() == null);
    try std.testing.expect(p.tableConn(&p.tables[0]) == null);
    try std.testing.expect(p.tableBelongsToConn(&p.tables[0], "Whatever"));
    const of_plain = try p.tablesOfConn(std.testing.allocator, "Whatever");
    defer std.testing.allocator.free(of_plain);
    try std.testing.expectEqual(@as(usize, 1), of_plain.len);
}

test "MaxCacheCount 缺省 1000，时序列强制 0" {
    const plain =
        \\<EntityModel><Tables><Table Name="T">
        \\  <Columns><Column Name="Id" DataType="Int32" PrimaryKey="True" /></Columns>
        \\</Table></Tables></EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, plain);
    defer m.deinit();
    try std.testing.expectEqual(@as(i32, 1000), m.tables[0].max_cache_count);

    const shard =
        \\<EntityModel><Tables><Table Name="S">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" PrimaryKey="True" />
        \\    <Column Name="LogTime" DataType="DateTime" DataScale="timeShard:yyyyMM" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    var m2 = try EntityModel.parse(std.testing.allocator, shard);
    defer m2.deinit();
    try std.testing.expectEqual(@as(i32, 0), m2.tables[0].max_cache_count);
}

test "写出→再解析 往返一致" {
    const xml =
        \\<EntityModel Version="1.0"><Option><Namespace>Demo.Entity</Namespace><ConnName>DH</ConnName></Option>
        \\<Tables><Table Name="JiLiYu" TableName="DH_JiLiYu" Description="激励语">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" Description="编号" />
        \\    <Column Name="Amount" DataType="Decimal" Precision="18" Scale="4" Nullable="True" />
        \\  </Columns>
        \\  <Indexes><Index Name="ix_a" Columns="Amount" Unique="True" /></Indexes>
        \\</Table></Tables></EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();

    const out = try m.toXmlAlloc(std.testing.allocator);
    defer std.testing.allocator.free(out);

    var m2 = try EntityModel.parse(std.testing.allocator, out);
    defer m2.deinit();

    try std.testing.expectEqual(m.tables.len, m2.tables.len);
    try std.testing.expectEqualStrings(m.tables[0].name, m2.tables[0].name);
    try std.testing.expectEqual(m.tables[0].columns.len, m2.tables[0].columns.len);
    try std.testing.expectEqual(DataType.decimal, m2.tables[0].column("Amount").?.data_type);
    try std.testing.expectEqual(@as(i32, 4), m2.tables[0].column("Amount").?.scale);
}

test "Guid 列：Model.xml 里 DataType=\"Guid\" 能解析（以前直接 error.InvalidModel）" {
    const xml =
        \\<EntityModel><Tables>
        \\<Table Name="Doc"><Columns>
        \\<Column Name="Id" DataType="Int32" PrimaryKey="True" Identity="True" />
        \\<Column Name="Token" DataType="Guid" />
        \\<Column Name="Uuid" DataType="uuid" />
        \\</Columns></Table>
        \\</Tables></EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();

    const t = &m.tables[0];
    try std.testing.expectEqual(DataType.guid, t.column("Token").?.data_type);
    // 反查/其它库给的别名也认
    try std.testing.expectEqual(DataType.guid, t.column("Uuid").?.data_type);

    // 写回 XML 时保持 C# 口径的类型名 `Guid`
    const out = try m.toXmlAlloc(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "DataType=\"Guid\"") != null);
}

test "视图识别：IsView 与 # 前缀" {
    const xml =
        \\<EntityModel><Tables>
        \\<Table Name="V1" IsView="True"><Columns><Column Name="Id" DataType="Int32" /></Columns></Table>
        \\<Table Name="#V2"><Columns><Column Name="Id" DataType="Int32" /></Columns></Table>
        \\</Tables></EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();
    try std.testing.expect(m.tables[0].is_view);
    try std.testing.expect(m.tables[1].is_view);
}

// ───────────────── 实体并入模型（建表 = Model.xml ∪ 实体） ─────────────────

const FakeField = struct {
    name: []const u8,
    data_type: DataType,
    primary_key: bool = false,
    identity: bool = false,
    column_name: ?[]const u8 = null,
    nullable: bool = false,
    additional: bool = false,
    length: i32 = 0,
    precision: i32 = 0,
    scale: i32 = 0,
    description: []const u8 = "",
};

const FakeMeta = struct {
    name: []const u8,
    table_name: []const u8,
    fields: []const FakeField,
};

const FakeIndex = struct {
    name: []const u8 = "",
    columns: []const []const u8 = &.{},
    unique: bool = false,
    expression: ?[]const u8 = null,
};

/// XML 里已有 `Config`（少一列 `Remark`），实体把它补回来。
const FakeConfigEntity = struct {
    pub const meta = FakeMeta{ .name = "Config", .table_name = "Config", .fields = &.{
        .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
        .{ .name = "Name", .data_type = .string, .length = 100 },
        .{ .name = "Remark", .data_type = .string, .length = 200, .nullable = true },
    } };
    pub const indexes = [_]FakeIndex{.{ .columns = &.{"Name"}, .unique = true }};
    pub const max_cache_count: i32 = 1000;
};

/// XML 里**没有**这张表（被清理了），实体还在 → 必须建出来。
const FakeSessionEntity = struct {
    pub const meta = FakeMeta{ .name = "Session", .table_name = "Session", .fields = &.{
        .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
        .{ .name = "Token", .data_type = .string, .length = 200 },
    } };
    pub const max_cache_count: i32 = 0;
};

test "实体并入：XML 缺表按实体补、缺列按实体补、同名列保留 XML" {
    const xml =
        \\<EntityModel><Tables>
        \\<Table Name="Config" TableName="Config">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Name" DataType="String" Nullable="True" DefaultValue="''" />
        \\  </Columns>
        \\</Table>
        \\</Tables></EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();

    const report = try m.mergeEntityTypes(.{ FakeConfigEntity, FakeSessionEntity });
    try std.testing.expectEqual(@as(usize, 1), report.tables_added); // Session
    try std.testing.expectEqual(@as(usize, 1), report.columns_added); // Config.Remark
    try std.testing.expectEqual(@as(usize, 1), report.indexes_added); // Config.ix(Name)

    // XML 被清理掉的表由实体补回
    const session = m.table("Session") orelse return error.MissingSession;
    try std.testing.expectEqual(@as(usize, 2), session.columns.len);
    try std.testing.expectEqual(@as(i32, 0), session.max_cache_count);

    // 同名列保留 XML 定义（`DefaultValue` 不能丢）
    const config = m.table("Config") orelse return error.MissingConfig;
    const name_col = config.column("Name") orelse return error.MissingName;
    try std.testing.expectEqualStrings("''", name_col.default_value.?);
    // 缺列由实体补回
    try std.testing.expect(config.column("Remark") != null);
}

test "实体并入：幂等（重复并两次不产生重复列/索引）" {
    const xml =
        \\<EntityModel><Tables>
        \\<Table Name="Config" TableName="Config">
        \\  <Columns><Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" /></Columns>
        \\</Table>
        \\</Tables></EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();

    const first = try m.mergeEntityTypes(.{FakeConfigEntity});
    const second = try m.mergeEntityTypes(.{FakeConfigEntity});
    try std.testing.expectEqual(@as(usize, 0), first.tables_added);
    try std.testing.expectEqual(@as(usize, 0), second.tables_added);
    try std.testing.expectEqual(@as(usize, 0), second.columns_added);
    try std.testing.expectEqual(@as(usize, 0), second.indexes_added);

    const config = m.table("Config") orelse return error.MissingConfig;
    try std.testing.expectEqual(@as(usize, 3), config.columns.len);
    try std.testing.expectEqual(@as(usize, 1), config.indexes.len);
}
