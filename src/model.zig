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
