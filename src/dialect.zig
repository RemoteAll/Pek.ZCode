//! 数据库方言：类型映射 / DDL / 分页 / 标识符与占位符。
//!
//! 与 DH.NCode 的各 `DbBase` 子类、Rust `Pek.RCode/src/dialect.rs` 对齐。
//!
//! **第一轮范围**：SQLite / MySQL / SQL Server / PostgreSQL（含金仓/瀚高/海量）/
//! Oracle 五族实现完整；其余数据库（DuckDB、ClickHouse、TDengine、InfluxDB、HANA、
//! Firebird、DB2、达梦、IRIS、Access、MongoDB）在枚举与连接串解析里占位，但类型映射
//! **明确返回 `error.Unsupported`**——不做静默降级，避免"看起来能用、实际生成错 SQL"。

const std = @import("std");
const Buf = @import("zzig").Buf;
const DataType = @import("types.zig").DataType;
const model = @import("model.zig");
const TableMeta = model.TableMeta;
const ColumnMeta = model.ColumnMeta;
const IndexMeta = model.IndexMeta;

/// MySQL 索引前缀长度（utf8mb4 下 191 字符 = 764 字节，兼容 767 字节前缀上限）。
pub const mysql_index_prefix_chars: i32 = 191;

pub const DatabaseKind = enum {
    sqlite,
    mysql,
    sqlserver,
    postgresql,
    kingbase,
    highgo,
    vastbase,
    oracle,
    duckdb,
    clickhouse,
    tdengine,
    influxdb,
    hana,
    firebird,
    db2,
    dameng,
    iris,
    access,
    mongodb,
    /// NovaDb（复用 MySQL 协议）
    nova,

    /// 连接串 `Provider=` 解析（忽略大小写，兼容 XCode 的常见写法）。
    pub fn fromProvider(provider: []const u8) ?DatabaseKind {
        const t = std.mem.trim(u8, provider, " \t\r\n");
        if (eq(t, "sqlite") or eq(t, "sqlite3")) return .sqlite;
        if (eq(t, "mysql") or eq(t, "mariadb")) return .mysql;
        if (eq(t, "sqlserver") or eq(t, "mssql")) return .sqlserver;
        if (eq(t, "postgresql") or eq(t, "postgres") or eq(t, "pgsql")) return .postgresql;
        if (eq(t, "kingbase") or eq(t, "金仓")) return .kingbase;
        if (eq(t, "highgo") or eq(t, "瀚高")) return .highgo;
        if (eq(t, "vastbase") or eq(t, "海量")) return .vastbase;
        if (eq(t, "oracle")) return .oracle;
        if (eq(t, "duckdb")) return .duckdb;
        if (eq(t, "clickhouse")) return .clickhouse;
        if (eq(t, "tdengine")) return .tdengine;
        if (eq(t, "influxdb") or eq(t, "influx")) return .influxdb;
        if (eq(t, "saphana") or eq(t, "hana")) return .hana;
        if (eq(t, "firebird")) return .firebird;
        if (eq(t, "db2")) return .db2;
        if (eq(t, "dameng") or eq(t, "dm")) return .dameng;
        if (eq(t, "iris")) return .iris;
        if (eq(t, "access") or eq(t, "oledb")) return .access;
        if (eq(t, "mongodb") or eq(t, "mongo")) return .mongodb;
        if (eq(t, "novadb") or eq(t, "nova")) return .nova;
        return null;
    }

    pub fn name(self: DatabaseKind) []const u8 {
        return switch (self) {
            .sqlite => "SQLite",
            .mysql => "MySql",
            .sqlserver => "SqlServer",
            .postgresql => "PostgreSQL",
            .kingbase => "KingBase",
            .highgo => "HighGo",
            .vastbase => "VastBase",
            .oracle => "Oracle",
            .duckdb => "DuckDB",
            .clickhouse => "ClickHouse",
            .tdengine => "TDengine",
            .influxdb => "InfluxDB",
            .hana => "SapHana",
            .firebird => "Firebird",
            .db2 => "Db2",
            .dameng => "DaMeng",
            .iris => "Iris",
            .access => "Access",
            .mongodb => "MongoDb",
            .nova => "NovaDb",
        };
    }

    pub fn isPostgresFamily(self: DatabaseKind) bool {
        return self == .postgresql or self == .kingbase or self == .highgo or self == .vastbase;
    }

    pub fn isFileBased(self: DatabaseKind) bool {
        return self == .sqlite or self == .duckdb or self == .access;
    }

    /// 是否已实现完整语义（第一轮范围之外的一律显式 Unsupported）。
    pub fn isImplemented(self: DatabaseKind) bool {
        return switch (self) {
            .sqlite, .mysql, .sqlserver, .oracle => true,
            else => self.isPostgresFamily(),
        };
    }

    /// 是否支持多行 VALUES（第一轮未实现批量写，但保留能力查询）。
    pub fn supportsMultiRowInsert(self: DatabaseKind) bool {
        return self != .influxdb and self != .mongodb;
    }

    /// 单条语句的参数上限（SQLite 3.32+ 默认 32766；MySQL 占位 65535）。
    pub fn maxStatementParams(self: DatabaseKind) usize {
        return switch (self) {
            .sqlite => 32766,
            .mysql => 65535,
            .sqlserver => 2100,
            .oracle => 65535,
            else => 32766,
        };
    }

    /// 标识符引用。
    pub fn pushQuoted(self: DatabaseKind, b: *Buf, ident: []const u8) !void {
        const style: struct { open: u8, close: u8, escape: u8 } = switch (self) {
            .mysql, .clickhouse, .tdengine => .{ .open = '`', .close = '`', .escape = '`' },
            .sqlserver, .access => .{ .open = '[', .close = ']', .escape = ']' },
            else => .{ .open = '"', .close = '"', .escape = '"' },
        };
        try b.addByte(style.open);
        for (ident) |c| {
            if (c == style.escape) try b.addByte(style.escape);
            try b.addByte(c);
        }
        try b.addByte(style.close);
    }

    pub fn quoteAlloc(self: DatabaseKind, gpa: std.mem.Allocator, ident: []const u8) ![]u8 {
        var b = Buf.init(gpa);
        defer b.deinit();
        try self.pushQuoted(&b, ident);
        return b.toOwnedSlice();
    }

    /// 参数占位符（`index` 从 0 开始）。
    pub fn pushPlaceholder(self: DatabaseKind, b: *Buf, index: usize) !void {
        switch (self) {
            .sqlserver => try b.fmt("@p{d}", .{index}),
            .oracle => try b.fmt(":{d}", .{index + 1}),
            else => {
                if (self.isPostgresFamily()) {
                    try b.fmt("${d}", .{index + 1});
                } else {
                    try b.add("?");
                }
            },
        }
    }

    pub fn placeholderAlloc(self: DatabaseKind, gpa: std.mem.Allocator, index: usize) ![]u8 {
        var b = Buf.init(gpa);
        defer b.deinit();
        try self.pushPlaceholder(&b, index);
        return b.toOwnedSlice();
    }

    /// 字段类型映射（CLR 类型 → 数据库字段类型）。
    pub fn fieldTypeAlloc(self: DatabaseKind, gpa: std.mem.Allocator, col: ColumnMeta) ![]u8 {
        if (!self.isImplemented()) return error.Unsupported;
        return switch (self) {
            .sqlite => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "bit"),
                .byte => gpa.dupe(u8, "tinyint"),
                .int16 => gpa.dupe(u8, "smallint"),
                .int32 => gpa.dupe(u8, if (col.identity) "integer" else "int"),
                .int64 => gpa.dupe(u8, "integer"),
                .single => gpa.dupe(u8, "single"),
                .double => gpa.dupe(u8, "real"),
                .decimal => gpa.dupe(u8, "decimal"),
                .string => if (col.length > 0) std.fmt.allocPrint(gpa, "nvarchar({d})", .{col.length}) else gpa.dupe(u8, "text"),
                .datetime => gpa.dupe(u8, "datetime"),
                .binary => gpa.dupe(u8, "binary"),
                .json => gpa.dupe(u8, "text"),
            },
            .mysql => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "TINYINT"),
                .byte => gpa.dupe(u8, "tinyint"),
                .int16 => gpa.dupe(u8, "smallint"),
                .int32 => gpa.dupe(u8, "int"),
                .int64 => gpa.dupe(u8, "bigint"),
                .single => gpa.dupe(u8, "float"),
                .double => gpa.dupe(u8, "double"),
                .decimal => blk: {
                    const spec = mysqlDecimalSpec(col);
                    break :blk std.fmt.allocPrint(gpa, "decimal({d},{d})", .{ spec.precision, spec.scale });
                },
                .string => if (col.length > 0 and col.length <= 16383)
                    std.fmt.allocPrint(gpa, "varchar({d})", .{col.length})
                else
                    gpa.dupe(u8, "longtext"),
                .datetime => datetimeSpec(gpa, "datetime", col.scale),
                .binary => gpa.dupe(u8, "longblob"),
                .json => gpa.dupe(u8, "JSON"),
            },
            .sqlserver => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "bit"),
                .byte => gpa.dupe(u8, "tinyint"),
                .int16 => gpa.dupe(u8, "smallint"),
                .int32 => gpa.dupe(u8, "int"),
                .int64 => gpa.dupe(u8, "bigint"),
                .single => gpa.dupe(u8, "real"),
                .double => gpa.dupe(u8, "float"),
                .decimal => std.fmt.allocPrint(gpa, "decimal({d},{d})", .{ col.precision, col.scale }),
                .string => if (col.length <= 0 or col.length > 4000)
                    gpa.dupe(u8, "nvarchar(max)")
                else
                    std.fmt.allocPrint(gpa, "nvarchar({d})", .{col.length}),
                .datetime => datetimeSpecMssql(gpa, col.scale),
                .binary => gpa.dupe(u8, "varbinary(max)"),
                .json => gpa.dupe(u8, "nvarchar(max)"),
            },
            .postgresql, .kingbase, .highgo, .vastbase => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "boolean"),
                .byte, .int16 => gpa.dupe(u8, "smallint"),
                .int32 => gpa.dupe(u8, "integer"),
                .int64 => gpa.dupe(u8, "bigint"),
                .single => gpa.dupe(u8, "real"),
                .double => gpa.dupe(u8, "double precision"),
                .decimal => std.fmt.allocPrint(gpa, "numeric({d},{d})", .{ col.precision, col.scale }),
                .string => if (col.length > 0)
                    std.fmt.allocPrint(gpa, "varchar({d})", .{col.length})
                else
                    gpa.dupe(u8, "text"),
                .datetime => datetimeSpec(gpa, "timestamp", col.scale),
                .binary => gpa.dupe(u8, "bytea"),
                .json => gpa.dupe(u8, "jsonb"),
            },
            .oracle => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "number(1)"),
                .byte => gpa.dupe(u8, "number(3)"),
                .int16 => gpa.dupe(u8, "number(5)"),
                .int32 => gpa.dupe(u8, "number(10)"),
                .int64 => gpa.dupe(u8, "number(19)"),
                .single => gpa.dupe(u8, "binary_float"),
                .double => gpa.dupe(u8, "binary_double"),
                .decimal => std.fmt.allocPrint(gpa, "number({d},{d})", .{ col.precision, col.scale }),
                .string => if (col.length <= 0 or col.length > 2000)
                    gpa.dupe(u8, "clob")
                else
                    std.fmt.allocPrint(gpa, "varchar2({d})", .{col.length}),
                .datetime => gpa.dupe(u8, "timestamp"),
                .binary => gpa.dupe(u8, "blob"),
                .json => gpa.dupe(u8, "clob"),
            },
            else => error.Unsupported,
        };
    }

    /// 自增列的类型改写（PostgreSQL 的 serial/serial8）。
    fn identityTypeAlloc(self: DatabaseKind, gpa: std.mem.Allocator, col: ColumnMeta) !?[]u8 {
        if (self.isPostgresFamily() and col.identity) {
            if (col.data_type == .int64) return try gpa.dupe(u8, "serial8");
            return try gpa.dupe(u8, "serial");
        }
        return null;
    }

    /// 自增列的列内联修饰（null 表示该方言不用内联写法）。
    fn identityClause(self: DatabaseKind) ?[]const u8 {
        return switch (self) {
            .mysql => " AUTO_INCREMENT",
            .sqlserver => " IDENTITY(1,1)",
            else => null,
        };
    }

    /// 最近一次自增 ID 的查询语句（诊断/脚本用）。
    pub fn lastIdentitySql(self: DatabaseKind) []const u8 {
        return switch (self) {
            .sqlite => "SELECT last_insert_rowid()",
            .mysql => "SELECT LAST_INSERT_ID()",
            .sqlserver => "SELECT SCOPE_IDENTITY()",
            .postgresql, .kingbase, .highgo, .vastbase => "SELECT lastval()",
            .oracle => "SELECT \"SEQ_<表名>\".CURRVAL FROM DUAL",
            else => "",
        };
    }

    /// 索引名（缺省 `ix_{表}_{列1}_{列2}`）。
    pub fn indexNameAlloc(self: DatabaseKind, gpa: std.mem.Allocator, table: *const TableMeta, idx: IndexMeta) ![]u8 {
        _ = self;
        if (idx.name) |n| return gpa.dupe(u8, n);
        var b = Buf.init(gpa);
        defer b.deinit();
        try b.fmt("ix_{s}", .{table.effectiveTableName()});
        for (idx.columns) |c| try b.fmt("_{s}", .{c});
        return b.toOwnedSlice();
    }

    /// 生成索引创建语句（null = 无列 / 该方言不支持该形式，可忽略）。
    pub fn createIndexAlloc(self: DatabaseKind, gpa: std.mem.Allocator, table: *const TableMeta, idx: IndexMeta) !?[]u8 {
        if (!self.isImplemented()) return error.Unsupported;

        if (idx.expression) |expr_raw| {
            const expr = std.mem.trim(u8, expr_raw, " \t\r\n");
            if (expr.len == 0 or self == .sqlserver) return null;
            const index_name = try self.indexNameAlloc(gpa, table, idx);
            defer gpa.free(index_name);

            var b = Buf.init(gpa);
            defer b.deinit();
            try b.add("CREATE ");
            if (idx.unique) try b.add("UNIQUE ");
            try b.add("INDEX ");
            try self.pushQuoted(&b, index_name);
            try b.add(" ON ");
            try self.pushQuoted(&b, table.effectiveTableName());
            if (self == .mysql) {
                try b.fmt(" (({s}))", .{expr});
            } else {
                try b.fmt(" ({s})", .{expr});
            }
            return try b.toOwnedSlice();
        }

        if (idx.columns.len == 0) return null;

        const index_name = try self.indexNameAlloc(gpa, table, idx);
        defer gpa.free(index_name);

        var b = Buf.init(gpa);
        defer b.deinit();
        try b.add("CREATE ");
        if (idx.unique) try b.add("UNIQUE ");
        try b.add("INDEX ");
        try self.pushQuoted(&b, index_name);
        try b.add(" ON ");
        try self.pushQuoted(&b, table.effectiveTableName());
        try b.add(" (");
        for (idx.columns, 0..) |column_name, i| {
            if (i > 0) try b.add(", ");
            if (table.column(column_name)) |col| {
                try self.pushQuoted(&b, table.effectiveColumnName(col));
                if (self == .mysql and mysqlNeedsIndexPrefix(col.*)) {
                    try b.fmt("({d})", .{mysql_index_prefix_chars});
                }
            } else {
                try self.pushQuoted(&b, column_name);
            }
        }
        try b.add(")");
        return try b.toOwnedSlice();
    }

    /// 生成建表语句（表 + 索引 + 序列）。
    pub fn createTableAlloc(self: DatabaseKind, gpa: std.mem.Allocator, table: *const TableMeta) ![][]u8 {
        if (!self.isImplemented()) return error.Unsupported;

        var stmts: std.ArrayList([]u8) = .empty;
        errdefer {
            for (stmts.items) |s| gpa.free(s);
            stmts.deinit(gpa);
        }

        var b = Buf.init(gpa);
        defer b.deinit();
        try b.add("CREATE TABLE ");
        try self.pushQuoted(&b, table.effectiveTableName());
        try b.add(" (\n");

        var inline_pk = false;
        for (table.columns, 0..) |col, i| {
            if (i > 0) try b.add(",\n");
            const cname = table.effectiveColumnName(@constCast(&col));
            try b.add("  ");
            try self.pushQuoted(&b, cname);
            try b.add(" ");

            const ident_type = try self.identityTypeAlloc(gpa, col);
            if (ident_type) |t| {
                defer gpa.free(t);
                try b.add(t);
            } else {
                const ftype = try self.fieldTypeAlloc(gpa, col);
                defer gpa.free(ftype);
                try b.add(ftype);
            }

            if (col.identity) {
                if (self == .sqlite) {
                    try b.add(" PRIMARY KEY AUTOINCREMENT");
                    inline_pk = true;
                } else if (self.identityClause()) |extra| {
                    try b.add(extra);
                }
            }
            const default_part = try columnDefaultSql(gpa, self, col);
            defer if (default_part) |d| gpa.free(d);

            const not_null = !col.nullable and !(col.identity and inline_pk);

            if (self == .oracle) {
                // Oracle 系要求 DEFAULT 出现在 NOT NULL 之前
                if (default_part) |d| try b.fmt(" DEFAULT {s}", .{d});
                if (not_null) try b.add(" NOT NULL");
            } else {
                if (not_null) try b.add(" NOT NULL");
                if (default_part) |d| try b.fmt(" DEFAULT {s}", .{d});
            }

            if (self == .sqlite and col.data_type == .string) {
                try b.add(" COLLATE NOCASE");
            }
            if (self == .mysql and col.description.len > 0) {
                try b.add(" COMMENT '");
                try pushEscapedMysql(&b, col.description);
                try b.add("'");
            }
        }

        // 表级主键（SQLite 自增列已内联，不再生成）
        if (!inline_pk) {
            var pk_count: usize = 0;
            var pk = Buf.init(gpa);
            defer pk.deinit();
            for (table.columns) |col| {
                if (!col.primary_key) continue;
                if (pk_count > 0) try pk.add(", ");
                try self.pushQuoted(&pk, table.effectiveColumnName(@constCast(&col)));
                pk_count += 1;
            }
            if (pk_count > 0) {
                try b.add(",\n  PRIMARY KEY (");
                try b.add(pk.slice());
                try b.add(")");
            }
        }

        try b.add("\n)");
        try stmts.append(gpa, try b.toOwnedSlice());

        for (table.indexes) |idx| {
            if (try self.createIndexAlloc(gpa, table, idx)) |sql| try stmts.append(gpa, sql);
        }

        // Oracle：自增由独立序列承担（XCode 约定 SEQ_{表名}）
        if (self == .oracle) {
            if (table.identity() != null) {
                const seq_sql = try std.fmt.allocPrint(gpa, "CREATE SEQUENCE \"SEQ_{s}\" START WITH 1 INCREMENT BY 1 CACHE 20", .{table.effectiveTableName()});
                try stmts.append(gpa, seq_sql);
            }
        }

        return try stmts.toOwnedSlice(gpa);
    }

    /// 生成「新增列」的 ALTER 语句。
    ///
    /// 安全策略：目标列 NOT NULL 且**没有默认值**时降级为可空列（历史数据无法通过约束检查）。
    pub fn addColumnAlloc(self: DatabaseKind, gpa: std.mem.Allocator, table: *const TableMeta, col: ColumnMeta) ![]u8 {
        if (!self.isImplemented()) return error.Unsupported;

        const ftype = try self.fieldTypeAlloc(gpa, col);
        defer gpa.free(ftype);

        var b = Buf.init(gpa);
        defer b.deinit();
        try b.add("ALTER TABLE ");
        try self.pushQuoted(&b, table.effectiveTableName());

        if (self == .sqlserver or self == .oracle) {
            try b.add(" ADD ");
        } else {
            try b.add(" ADD COLUMN ");
        }
        try self.pushQuoted(&b, table.effectiveColumnName(@constCast(&col)));
        try b.fmt(" {s}", .{ftype});

        const default_part = try columnDefaultSql(gpa, self, col);
        defer if (default_part) |d| gpa.free(d);

        const not_null = !col.nullable and default_part != null;
        if (self == .oracle) {
            if (default_part) |d| try b.fmt(" DEFAULT {s}", .{d});
            if (not_null) try b.add(" NOT NULL");
        } else {
            if (not_null) try b.add(" NOT NULL");
            if (default_part) |d| try b.fmt(" DEFAULT {s}", .{d});
        }
        if (self == .mysql and col.description.len > 0) {
            try b.add(" COMMENT '");
            try pushEscapedMysql(&b, col.description);
            try b.add("'");
        }
        return b.toOwnedSlice();
    }

    /// 删除列（仅 Full 档使用；SQLite 不支持列级删除语法差异，见 DH.NCode 各驱动实现）。
    pub fn dropColumnAlloc(self: DatabaseKind, gpa: std.mem.Allocator, table_name: []const u8, column_name: []const u8) !?[]u8 {
        if (!self.isImplemented()) return error.Unsupported;
        var b = Buf.init(gpa);
        defer b.deinit();
        try b.add("Alter Table ");
        try self.pushQuoted(&b, table_name);
        try b.add(" Drop Column ");
        try self.pushQuoted(&b, column_name);
        return try b.toOwnedSlice();
    }

    /// 删除索引（`table_name` 仅在 MySQL / SQL Server 语法里需要）。
    pub fn dropIndexAlloc(self: DatabaseKind, gpa: std.mem.Allocator, index_name: []const u8, table_name: ?[]const u8) !?[]u8 {
        if (!self.isImplemented()) return error.Unsupported;
        var b = Buf.init(gpa);
        defer b.deinit();
        switch (self) {
            .sqlserver => {
                const t = table_name orelse return null;
                try b.add("Drop Index ");
                try self.pushQuoted(&b, t);
                try b.add(".");
                try self.pushQuoted(&b, index_name);
            },
            .mysql => {
                const t = table_name orelse return null;
                try b.add("Drop Index ");
                try self.pushQuoted(&b, index_name);
                try b.add(" On ");
                try self.pushQuoted(&b, t);
            },
            else => {
                try b.add("Drop Index ");
                try self.pushQuoted(&b, index_name);
            },
        }
        return try b.toOwnedSlice();
    }

    /// 删除表（人工/工具用；自动迁移从不调用）。
    pub fn dropTableAlloc(self: DatabaseKind, gpa: std.mem.Allocator, table_name: []const u8) ![]u8 {
        if (!self.isImplemented()) return error.Unsupported;
        var b = Buf.init(gpa);
        defer b.deinit();
        try b.add("Drop Table ");
        try self.pushQuoted(&b, table_name);
        return b.toOwnedSlice();
    }

    /// 修改列类型（仅 Full 档；SQLite 不支持直接改列类型）。
    pub fn alterColumnAlloc(self: DatabaseKind, gpa: std.mem.Allocator, table: *const TableMeta, col: ColumnMeta) !?[]u8 {
        if (!self.isImplemented()) return error.Unsupported;
        if (self == .sqlite) return null;

        const ftype = try self.fieldTypeAlloc(gpa, col);
        defer gpa.free(ftype);

        var b = Buf.init(gpa);
        defer b.deinit();
        switch (self) {
            .mysql => {
                try b.add("Alter Table ");
                try self.pushQuoted(&b, table.effectiveTableName());
                try b.add(" Modify Column ");
                try self.pushQuoted(&b, table.effectiveColumnName(@constCast(&col)));
                try b.fmt(" {s}", .{ftype});
            },
            .sqlserver => {
                try b.add("Alter Table ");
                try self.pushQuoted(&b, table.effectiveTableName());
                try b.add(" Alter Column ");
                try self.pushQuoted(&b, table.effectiveColumnName(@constCast(&col)));
                try b.fmt(" {s}", .{ftype});
                if (!col.nullable) try b.add(" NOT NULL");
            },
            .postgresql, .kingbase, .highgo, .vastbase => {
                try b.add("ALTER TABLE ");
                try self.pushQuoted(&b, table.effectiveTableName());
                try b.add(" ALTER COLUMN ");
                try self.pushQuoted(&b, table.effectiveColumnName(@constCast(&col)));
                try b.fmt(" TYPE {s}", .{ftype});
            },
            .oracle => {
                try b.add("Alter Table ");
                try self.pushQuoted(&b, table.effectiveTableName());
                try b.add(" Modify ");
                try self.pushQuoted(&b, table.effectiveColumnName(@constCast(&col)));
                try b.fmt(" {s}", .{ftype});
            },
            else => return null,
        }
        return try b.toOwnedSlice();
    }

    /// 分页拼装：`sql` 不含排序与分页；`order_sql` 为完整 `ORDER BY ...`（可空）。
    pub fn applyPagingAlloc(
        self: DatabaseKind,
        gpa: std.mem.Allocator,
        sql: []const u8,
        order_sql: []const u8,
        offset: usize,
        size: usize,
    ) ![]u8 {
        if (!self.isImplemented()) return error.Unsupported;

        if (self == .oracle) {
            // ROWNUM 双层包装（兼容 11g）：整条语句重建，不能在前缀上追加
            var inner = Buf.init(gpa);
            defer inner.deinit();
            try inner.add(sql);
            if (order_sql.len > 0) {
                try inner.add(" ");
                try inner.add(order_sql);
            }
            return std.fmt.allocPrint(
                gpa,
                "SELECT * FROM (SELECT T0.*, ROWNUM AS rowNumber FROM ({s}) T0) WHERE rowNumber > {d} AND rowNumber <= {d}",
                .{ inner.slice(), offset, offset + size },
            );
        }

        var b = Buf.init(gpa);
        defer b.deinit();
        try b.add(sql);
        if (order_sql.len > 0) {
            try b.add(" ");
            try b.add(order_sql);
        }
        switch (self) {
            .sqlserver => {
                if (order_sql.len == 0) try b.add(" ORDER BY (SELECT NULL)");
                try b.fmt(" OFFSET {d} ROWS FETCH NEXT {d} ROWS ONLY", .{ offset, size });
            },
            else => try b.fmt(" LIMIT {d} OFFSET {d}", .{ size, offset }),
        }
        return b.toOwnedSlice();
    }

    /// XCode 约定的序列名。
    pub fn identitySequenceAlloc(gpa: std.mem.Allocator, table_name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "SEQ_{s}", .{table_name});
    }
};

const DecimalSpec = struct { precision: i32, scale: i32 };

/// MySQL DECIMAL 精度规则（对齐 DH.NCode：`Length` 有值时覆盖 `Precision`，上限 255）。
fn mysqlDecimalSpec(col: ColumnMeta) DecimalSpec {
    const scale: i32 = @max(col.scale, 0);
    var precision: i32 = if (col.length > 0)
        @min(col.length, 255)
    else if (col.precision > 0)
        col.precision
    else
        10;
    if (precision <= scale) precision = scale + 1;
    return .{ .precision = precision, .scale = scale };
}

/// 日期时间类型 + 小数秒位数：`Scale` 1..=6 生成 `datetime(3)` / `timestamp(3)`，否则原类型。
fn datetimeSpec(gpa: std.mem.Allocator, base: []const u8, scale: i32) ![]u8 {
    if (scale >= 1 and scale <= 6) return std.fmt.allocPrint(gpa, "{s}({d})", .{ base, scale });
    return gpa.dupe(u8, base);
}

fn datetimeSpecMssql(gpa: std.mem.Allocator, scale: i32) ![]u8 {
    if (scale >= 1 and scale <= 6) return std.fmt.allocPrint(gpa, "datetime2({d})", .{scale});
    return gpa.dupe(u8, "datetime");
}

fn pushEscapedMysql(b: *Buf, v: []const u8) !void {
    for (v) |c| {
        if (c == '\\') try b.add("\\\\");
        if (c == '\'') try b.add("''");
        try b.addByte(c);
    }
}

/// 默认值渲染：数值/布尔内联；其余作为字符串字面量。
fn renderDefault(gpa: std.mem.Allocator, kind: DatabaseKind, default: []const u8, col: ColumnMeta) ![]u8 {
    const trimmed = std.mem.trim(u8, default, " \t\r\n");

    if (col.data_type.isNumeric()) {
        _ = std.fmt.parseFloat(f64, trimmed) catch null;
        if (std.fmt.parseFloat(f64, trimmed)) |_| {
            return gpa.dupe(u8, trimmed);
        } else |_| {}
    }

    if (col.data_type == .boolean) {
        const is_true = eq(trimmed, "true") or std.mem.eql(u8, trimmed, "1");
        const is_false = eq(trimmed, "false") or std.mem.eql(u8, trimmed, "0");
        if (is_true or is_false) {
            const v = is_true;
            if (kind.isPostgresFamily()) return gpa.dupe(u8, if (v) "TRUE" else "FALSE");
            return gpa.dupe(u8, if (v) "1" else "0");
        }
        return gpa.dupe(u8, "0");
    }

    // 字符串型：已带引号不重复包裹
    var literal = Buf.init(gpa);
    defer literal.deinit();
    if ((trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') or
        (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"'))
    {
        try literal.add(trimmed);
    } else {
        try literal.add("'");
        for (trimmed) |c| {
            if (c == '\'') try literal.add("''");
            try literal.addByte(c);
        }
        try literal.add("'");
    }

    // MySQL 的 TEXT/BLOB 列不接受字面量默认值，必须写成表达式默认 `DEFAULT ('')`
    if (kind == .mysql and mysqlNeedsIndexPrefix(col)) {
        return std.fmt.allocPrint(gpa, "({s})", .{literal.slice()});
    }
    return literal.toOwnedSlice();
}

fn columnDefaultSql(gpa: std.mem.Allocator, kind: DatabaseKind, col: ColumnMeta) !?[]u8 {
    if (col.default_value) |d| {
        if (d.len > 0) return try renderDefault(gpa, kind, d, col);
    }
    if (kind == .oracle and col.data_type == .datetime and !col.nullable and !col.identity) {
        return try gpa.dupe(u8, "To_Date('0001-01-01','yyyy-mm-dd')");
    }
    return null;
}

/// 该列在 MySQL 里是不是 TEXT/BLOB 系列（建索引必须带前缀长度）。
fn mysqlNeedsIndexPrefix(col: ColumnMeta) bool {
    return switch (col.data_type) {
        .string => col.length <= 0 or col.length > 16383,
        .binary => true,
        else => false,
    };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ─────────────────────────────── 测试（黄金样本对齐 Rust 版） ───────────────────────────────

fn sampleTable() TableMeta {
    return .{
        .name = "Order",
        .table_name = "DH_Order",
        .columns = &[_]ColumnMeta{
            .{ .name = "Id", .data_type = .int32, .identity = true, .primary_key = true },
            .{ .name = "Code", .data_type = .string, .length = 50 },
            .{ .name = "Title", .data_type = .string },
            .{ .name = "Amount", .data_type = .decimal, .precision = 18, .scale = 4 },
            .{ .name = "Ok", .data_type = .boolean },
            .{ .name = "CreateTime", .data_type = .datetime },
        },
    };
}

test "标识符引用与占位符" {
    const a = std.testing.allocator;

    const s1 = try DatabaseKind.sqlite.quoteAlloc(a, "DH_Order");
    defer a.free(s1);
    try std.testing.expectEqualStrings("\"DH_Order\"", s1);

    const s2 = try DatabaseKind.mysql.quoteAlloc(a, "DH_Order");
    defer a.free(s2);
    try std.testing.expectEqualStrings("`DH_Order`", s2);

    const s3 = try DatabaseKind.sqlserver.quoteAlloc(a, "DH_Order");
    defer a.free(s3);
    try std.testing.expectEqualStrings("[DH_Order]", s3);

    const s4 = try DatabaseKind.sqlite.quoteAlloc(a, "a\"b");
    defer a.free(s4);
    try std.testing.expectEqualStrings("\"a\"\"b\"", s4);

    const p1 = try DatabaseKind.sqlite.placeholderAlloc(a, 0);
    defer a.free(p1);
    try std.testing.expectEqualStrings("?", p1);

    const p2 = try DatabaseKind.sqlserver.placeholderAlloc(a, 2);
    defer a.free(p2);
    try std.testing.expectEqualStrings("@p2", p2);

    const p3 = try DatabaseKind.postgresql.placeholderAlloc(a, 0);
    defer a.free(p3);
    try std.testing.expectEqualStrings("$1", p3);

    const p4 = try DatabaseKind.oracle.placeholderAlloc(a, 1);
    defer a.free(p4);
    try std.testing.expectEqualStrings(":2", p4);
}

test "字段类型映射（Rust 版黄金断言）" {
    const a = std.testing.allocator;
    const t = sampleTable();

    const id_sqlite = try DatabaseKind.sqlite.fieldTypeAlloc(a, t.column("Id").?.*);
    defer a.free(id_sqlite);
    try std.testing.expectEqualStrings("integer", id_sqlite);

    const id_mysql = try DatabaseKind.mysql.fieldTypeAlloc(a, t.column("Id").?.*);
    defer a.free(id_mysql);
    try std.testing.expectEqualStrings("int", id_mysql);

    const code_sqlite = try DatabaseKind.sqlite.fieldTypeAlloc(a, t.column("Code").?.*);
    defer a.free(code_sqlite);
    try std.testing.expectEqualStrings("nvarchar(50)", code_sqlite);

    const title_sqlite = try DatabaseKind.sqlite.fieldTypeAlloc(a, t.column("Title").?.*);
    defer a.free(title_sqlite);
    try std.testing.expectEqualStrings("text", title_sqlite);

    const title_mysql = try DatabaseKind.mysql.fieldTypeAlloc(a, t.column("Title").?.*);
    defer a.free(title_mysql);
    try std.testing.expectEqualStrings("longtext", title_mysql);

    const title_mssql = try DatabaseKind.sqlserver.fieldTypeAlloc(a, t.column("Title").?.*);
    defer a.free(title_mssql);
    try std.testing.expectEqualStrings("nvarchar(max)", title_mssql);

    const amount_mssql = try DatabaseKind.sqlserver.fieldTypeAlloc(a, t.column("Amount").?.*);
    defer a.free(amount_mssql);
    try std.testing.expectEqualStrings("decimal(18,4)", amount_mssql);

    const amount_pg = try DatabaseKind.postgresql.fieldTypeAlloc(a, t.column("Amount").?.*);
    defer a.free(amount_pg);
    try std.testing.expectEqualStrings("numeric(18,4)", amount_pg);

    const ok_mysql = try DatabaseKind.mysql.fieldTypeAlloc(a, t.column("Ok").?.*);
    defer a.free(ok_mysql);
    try std.testing.expectEqualStrings("TINYINT", ok_mysql);

    const ok_sqlite = try DatabaseKind.sqlite.fieldTypeAlloc(a, t.column("Ok").?.*);
    defer a.free(ok_sqlite);
    try std.testing.expectEqualStrings("bit", ok_sqlite);
}

test "SQLite 建表与 XCode 约定一致" {
    const a = std.testing.allocator;
    const t = sampleTable();
    const stmts = try DatabaseKind.sqlite.createTableAlloc(a, &t);
    defer {
        for (stmts) |s| a.free(s);
        a.free(stmts);
    }
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const sql = stmts[0];

    try std.testing.expect(std.mem.indexOf(u8, sql, "\"Id\" integer PRIMARY KEY AUTOINCREMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"Code\" nvarchar(50) NOT NULL COLLATE NOCASE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"Title\" text NOT NULL COLLATE NOCASE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"Amount\" decimal NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"Ok\" bit NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"CreateTime\" datetime NOT NULL") != null);
    // 自增列已内联主键，不再生成表级主键
    try std.testing.expect(std.mem.indexOf(u8, sql, "PRIMARY KEY (") == null);
}

test "SQL Server 建表：表级主键 + IDENTITY" {
    const a = std.testing.allocator;
    const t = sampleTable();
    const stmts = try DatabaseKind.sqlserver.createTableAlloc(a, &t);
    defer {
        for (stmts) |s| a.free(s);
        a.free(stmts);
    }
    const sql = stmts[0];
    try std.testing.expect(std.mem.indexOf(u8, sql, "[Id] int IDENTITY(1,1) NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "PRIMARY KEY ([Id])") != null);
}

test "索引生成（SQLite 缺省名）" {
    const a = std.testing.allocator;
    var t = sampleTable();
    t.indexes = &[_]IndexMeta{
        .{ .columns = &[_][]const u8{"Code"}, .unique = true },
    };
    const stmts = try DatabaseKind.sqlite.createTableAlloc(a, &t);
    defer {
        for (stmts) |s| a.free(s);
        a.free(stmts);
    }
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX \"ix_DH_Order_Code\" ON \"DH_Order\" (\"Code\")",
        stmts[1],
    );
}

test "MySQL longtext 索引自动加前缀长度" {
    const a = std.testing.allocator;
    var t = sampleTable();
    t.indexes = &[_]IndexMeta{
        .{ .columns = &[_][]const u8{"Code"}, .unique = true },
        .{ .columns = &[_][]const u8{"Title"}, .unique = true },
    };
    const stmts = try DatabaseKind.mysql.createTableAlloc(a, &t);
    defer {
        for (stmts) |s| a.free(s);
        a.free(stmts);
    }
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(a);
    for (stmts) |s| {
        try joined.appendSlice(a, s);
        try joined.append(a, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "(`Code`)") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "(`Title`(191))") != null);
}

test "分页语法（SQLite）" {
    const a = std.testing.allocator;
    const sql = try DatabaseKind.sqlite.applyPagingAlloc(a, "SELECT * FROM T", "ORDER BY \"Id\"", 20, 10);
    defer a.free(sql);
    try std.testing.expectEqualStrings("SELECT * FROM T ORDER BY \"Id\" LIMIT 10 OFFSET 20", sql);
}

test "SQL Server 分页需要 ORDER BY 兜底" {
    const a = std.testing.allocator;
    const sql = try DatabaseKind.sqlserver.applyPagingAlloc(a, "SELECT * FROM T", "", 0, 10);
    defer a.free(sql);
    try std.testing.expectEqualStrings(
        "SELECT * FROM T ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY",
        sql,
    );
}

test "删列 / 删索引 / 删表 与各驱动一致" {
    const a = std.testing.allocator;

    const d1 = (try DatabaseKind.sqlite.dropColumnAlloc(a, "DH_Order", "Extra")).?;
    defer a.free(d1);
    try std.testing.expectEqualStrings("Alter Table \"DH_Order\" Drop Column \"Extra\"", d1);

    const d2 = (try DatabaseKind.sqlserver.dropIndexAlloc(a, "ix_a", "DH_Order")).?;
    defer a.free(d2);
    try std.testing.expectEqualStrings("Drop Index [DH_Order].[ix_a]", d2);

    const d3 = (try DatabaseKind.mysql.dropIndexAlloc(a, "ix_a", "DH_Order")).?;
    defer a.free(d3);
    try std.testing.expectEqualStrings("Drop Index `ix_a` On `DH_Order`", d3);

    const d4 = (try DatabaseKind.sqlite.dropIndexAlloc(a, "ix_a", null)).?;
    defer a.free(d4);
    try std.testing.expectEqualStrings("Drop Index \"ix_a\"", d4);

    const d5 = try DatabaseKind.sqlite.dropTableAlloc(a, "DH_Order");
    defer a.free(d5);
    try std.testing.expectEqualStrings("Drop Table \"DH_Order\"", d5);
}

test "SQLite 不支持改列类型" {
    const a = std.testing.allocator;
    const t = sampleTable();
    try std.testing.expect((try DatabaseKind.sqlite.alterColumnAlloc(a, &t, t.column("Code").?.*)) == null);
}

test "默认值渲染" {
    const a = std.testing.allocator;

    var col = ColumnMeta{ .name = "Ok", .data_type = .boolean, .default_value = "True" };
    const pg_sql = (try DatabaseKind.postgresql.addColumnAlloc(a, &sampleTable(), col));
    defer a.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "DEFAULT TRUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "NOT NULL") != null);

    col.default_value = null;
    const sqlite_sql = try DatabaseKind.sqlite.addColumnAlloc(a, &sampleTable(), col);
    defer a.free(sqlite_sql);
    // 无默认值时 NOT NULL 降级为可空
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "NOT NULL") == null);
}

test "未实现的方言显式报错" {
    const a = std.testing.allocator;
    const t = sampleTable();
    try std.testing.expectError(error.Unsupported, DatabaseKind.clickhouse.createTableAlloc(a, &t));
    try std.testing.expect(!DatabaseKind.mongodb.isImplemented());
}

test "Provider 解析" {
    try std.testing.expectEqual(DatabaseKind.sqlite, DatabaseKind.fromProvider("SQLite").?);
    try std.testing.expectEqual(DatabaseKind.mysql, DatabaseKind.fromProvider("mysql").?);
    try std.testing.expectEqual(DatabaseKind.postgresql, DatabaseKind.fromProvider("PostgreSQL").?);
    try std.testing.expectEqual(DatabaseKind.sqlserver, DatabaseKind.fromProvider("MSSQL").?);
    try std.testing.expect(DatabaseKind.fromProvider("unknown-db") == null);
}
