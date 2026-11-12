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
    /// SQL Server Compact Edition
    sqlce,
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
        if (eq(t, "sqlce") or eq(t, "sqlce35") or eq(t, "sqlserverce")) return .sqlce;
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
            .sqlce => "SqlCe",
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

    /// 是否已实现完整语义。
    ///
    /// 注：`mongodb`（文档库，无 SQL）与 `influxdb`（Line Protocol）没有 DDL/分页语义，
    /// 因此它们永远返回 `false`；其余 SQL 方言均已按 C# 驱动里的类型表/分页实现对齐。
    pub fn isImplemented(self: DatabaseKind) bool {
        return switch (self) {
            .mongodb, .influxdb => false,
            else => true,
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
            .sqlserver, .access, .sqlce => .{ .open = '[', .close = ']', .escape = ']' },
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
            .oracle, .dameng => try b.fmt(":{d}", .{index + 1}),
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
            // 达孟（C# `DaMeng.cs` 的 _DataTypes）：Oracle 系语法，占位符 `:n`
            .dameng => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "BIT"),
                .byte => gpa.dupe(u8, "TINYINT"),
                .int16 => gpa.dupe(u8, "SMALLINT"),
                .int32 => gpa.dupe(u8, "INT"),
                .int64 => gpa.dupe(u8, "BIGINT"),
                .single => gpa.dupe(u8, "REAL"),
                .double => gpa.dupe(u8, "DOUBLE"),
                .decimal => if (col.precision > 0)
                    std.fmt.allocPrint(gpa, "DEC({d},{d})", .{ col.precision, col.scale })
                else
                    gpa.dupe(u8, "DEC"),
                .string => if (col.length > 0 and col.length < 4000)
                    std.fmt.allocPrint(gpa, "VARCHAR({d})", .{col.length})
                else
                    gpa.dupe(u8, "TEXT"),
                .datetime => gpa.dupe(u8, "DATETIME"),
                .binary => gpa.dupe(u8, "BLOB"),
                .json => gpa.dupe(u8, "TEXT"),
            },
            // DB2（C# `DB2.cs`）：数字/字符串走 Oracle 风格类型名，时间只有 DATE
            .db2 => switch (col.data_type) {
                .boolean, .byte => gpa.dupe(u8, "NUMBER(1,0)"),
                .int16 => gpa.dupe(u8, "NUMBER(5,0)"),
                .int32 => gpa.dupe(u8, "NUMBER(10,0)"),
                .int64 => gpa.dupe(u8, "NUMBER(20,0)"),
                .single => gpa.dupe(u8, "BINARY_FLOAT"),
                .double => gpa.dupe(u8, "BINARY_DOUBLE"),
                .decimal => if (col.precision > 0)
                    std.fmt.allocPrint(gpa, "NUMBER({d},{d})", .{ col.precision, col.scale })
                else
                    gpa.dupe(u8, "NUMBER"),
                .string => if (col.length > 0)
                    std.fmt.allocPrint(gpa, "VARCHAR2({d})", .{col.length})
                else
                    gpa.dupe(u8, "CLOB"),
                .datetime => gpa.dupe(u8, "DATE"),
                .binary => if (col.length > 0)
                    std.fmt.allocPrint(gpa, "RAW({d})", .{col.length})
                else
                    gpa.dupe(u8, "BLOB"),
                .json => gpa.dupe(u8, "CLOB"),
            },
            // Firebird（C# `Firebird.cs`）：无布尔/无 Guid，Bool 用 SMALLINT
            .firebird => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "SMALLINT"),
                .byte => gpa.dupe(u8, "SMALLINT"),
                .int16 => gpa.dupe(u8, "SMALLINT"),
                .int32 => gpa.dupe(u8, "INT"),
                .int64 => gpa.dupe(u8, "BIGINT"),
                .single => gpa.dupe(u8, "FLOAT"),
                .double => gpa.dupe(u8, "DOUBLE"),
                .decimal => if (col.precision > 0)
                    std.fmt.allocPrint(gpa, "DECIMAL({d},{d})", .{ col.precision, col.scale })
                else
                    gpa.dupe(u8, "DECIMAL"),
                .string => if (col.length > 0)
                    std.fmt.allocPrint(gpa, "NVARCHAR({d})", .{col.length})
                else
                    gpa.dupe(u8, "BLOB SUB_TYPE TEXT"),
                .datetime => gpa.dupe(u8, "TIMESTAMP"),
                .binary => gpa.dupe(u8, "BLOB"),
                .json => gpa.dupe(u8, "BLOB SUB_TYPE TEXT"),
            },
            // HANA / IRIS / NovaDb（C# 三份 _DataTypes 几乎一致：MySQL 风格类型名）
            .hana, .iris, .nova => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "TINYINT"),
                .byte => gpa.dupe(u8, "TINYINT"),
                .int16 => gpa.dupe(u8, "SMALLINT"),
                .int32 => gpa.dupe(u8, "INT"),
                .int64 => gpa.dupe(u8, "BIGINT"),
                .single => gpa.dupe(u8, "FLOAT"),
                .double => gpa.dupe(u8, "DOUBLE"),
                .decimal => if (col.precision > 0)
                    std.fmt.allocPrint(gpa, "DECIMAL({d},{d})", .{ col.precision, col.scale })
                else
                    gpa.dupe(u8, "DECIMAL"),
                .string => if (col.length > 0 and col.length < 5000)
                    std.fmt.allocPrint(gpa, "VARCHAR({d})", .{col.length})
                else
                    gpa.dupe(u8, "LONGTEXT"),
                .datetime => gpa.dupe(u8, "DATETIME"),
                .binary => gpa.dupe(u8, "BLOB"),
                .json => gpa.dupe(u8, "LONGTEXT"),
            },
            // Access / SqlCe（C# 两份：SqlServer 家族类型名，标识符用 []）
            .access => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "bit"),
                .byte => gpa.dupe(u8, "tinyint"),
                .int16 => gpa.dupe(u8, "smallint"),
                .int32 => gpa.dupe(u8, "int"),
                .int64 => gpa.dupe(u8, "integer"),
                .single => gpa.dupe(u8, "single"),
                .double => gpa.dupe(u8, "real"),
                .decimal => gpa.dupe(u8, "money"),
                .string => if (col.length > 0)
                    std.fmt.allocPrint(gpa, "nvarchar({d})", .{col.length})
                else
                    gpa.dupe(u8, "ntext"),
                .datetime => gpa.dupe(u8, "datetime"),
                .binary => gpa.dupe(u8, "binary"),
                .json => gpa.dupe(u8, "ntext"),
            },
            .sqlce => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "bit"),
                .byte => gpa.dupe(u8, "tinyint"),
                .int16 => gpa.dupe(u8, "smallint"),
                .int32 => gpa.dupe(u8, "int"),
                .int64 => gpa.dupe(u8, "bigint"),
                .single => gpa.dupe(u8, "real"),
                .double => gpa.dupe(u8, "float"),
                .decimal => gpa.dupe(u8, "money"),
                .string => if (col.length > 0)
                    std.fmt.allocPrint(gpa, "nvarchar({d})", .{col.length})
                else
                    gpa.dupe(u8, "ntext"),
                .datetime => gpa.dupe(u8, "datetime"),
                .binary => gpa.dupe(u8, "varbinary(8000)"),
                .json => gpa.dupe(u8, "ntext"),
            },
            // DuckDB / ClickHouse：C# 侧没有静态类型表（走驱动自己的 schema），
            // 这里按两者的**原生类型名**给出（DuckDB 兼容 PG 类型名，ClickHouse 用 String/Int*）
            .duckdb => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "BOOLEAN"),
                .byte => gpa.dupe(u8, "TINYINT"),
                .int16 => gpa.dupe(u8, "SMALLINT"),
                .int32 => gpa.dupe(u8, "INTEGER"),
                .int64 => gpa.dupe(u8, "BIGINT"),
                .single => gpa.dupe(u8, "REAL"),
                .double => gpa.dupe(u8, "DOUBLE"),
                .decimal => if (col.precision > 0)
                    std.fmt.allocPrint(gpa, "DECIMAL({d},{d})", .{ col.precision, col.scale })
                else
                    gpa.dupe(u8, "DECIMAL(18,4)"),
                .string => gpa.dupe(u8, "VARCHAR"),
                .datetime => gpa.dupe(u8, "TIMESTAMP"),
                .binary => gpa.dupe(u8, "BLOB"),
                .json => gpa.dupe(u8, "JSON"),
            },
            .clickhouse => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "UInt8"),
                .byte => gpa.dupe(u8, "UInt8"),
                .int16 => gpa.dupe(u8, "Int16"),
                .int32 => gpa.dupe(u8, "Int32"),
                .int64 => gpa.dupe(u8, "Int64"),
                .single => gpa.dupe(u8, "Float32"),
                .double => gpa.dupe(u8, "Float64"),
                .decimal => if (col.precision > 0)
                    std.fmt.allocPrint(gpa, "Decimal({d}, {d})", .{ col.precision, col.scale })
                else
                    gpa.dupe(u8, "Decimal(18, 4)"),
                .string => gpa.dupe(u8, "String"),
                .datetime => gpa.dupe(u8, "DateTime"),
                .binary => gpa.dupe(u8, "String"),
                .json => gpa.dupe(u8, "String"),
            },
            // TDengine（C# `Tdengine.cs` 的 _DataTypes）：无布尔以外的复杂类型，时间固定 TIMESTAMP
            .tdengine => switch (col.data_type) {
                .boolean => gpa.dupe(u8, "BOOL"),
                .byte => gpa.dupe(u8, "TINYINT"),
                .int16 => gpa.dupe(u8, "SMALLINT"),
                .int32 => gpa.dupe(u8, "INT"),
                .int64 => gpa.dupe(u8, "BIGINT"),
                .single => gpa.dupe(u8, "FLOAT"),
                .double, .decimal => gpa.dupe(u8, "DOUBLE"),
                .string => if (col.length > 0)
                    std.fmt.allocPrint(gpa, "NCHAR({d})", .{col.length})
                else
                    gpa.dupe(u8, "NCHAR(64)"),
                .datetime => gpa.dupe(u8, "TIMESTAMP"),
                .binary => gpa.dupe(u8, "BINARY(64)"),
                .json => gpa.dupe(u8, "NCHAR(256)"),
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
    ///
    /// 来源：`DaMeng.cs`（`IDENTITY NOT NULL`）、`Hana/IRIS/NovaDb`（`AUTO_INCREMENT`）、
    /// `Access.cs`（`AUTOINCREMENT(1,1)`）、`SqlCe.cs`（`IDENTITY(1,1)`）；
    /// DB2 / Firebird / DuckDB 用的是标准 SQL 的 identity 子句。
    fn identityClause(self: DatabaseKind) ?[]const u8 {
        return switch (self) {
            .mysql, .hana, .iris, .nova => " AUTO_INCREMENT",
            .sqlserver, .sqlce => " IDENTITY(1,1)",
            .dameng => " IDENTITY",
            .db2, .duckdb => " GENERATED ALWAYS AS IDENTITY",
            .firebird => " GENERATED BY DEFAULT AS IDENTITY",
            .access => " AUTOINCREMENT(1,1)",
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

    /// 修改列类型（仅 Full 档；SQLite 不支持直接改列类型，返回 null 由上层整表重建）。
    ///
    /// **MySQL / SQL Server / Oracle 的 `MODIFY` / `ALTER COLUMN` 是「整列定义替换」**：
    /// 漏写 `NOT NULL` 会把非空约束悄悄去掉，漏写 `DEFAULT` 会丢默认值
    /// （本轮在 MySQL 8.0.29 真库上实测：只写类型 → 列变成 `DEFAULT NULL`）。
    /// 所以这里必须把可空性（和 MySQL/Oracle 的默认值、注释）一并带上。
    pub fn alterColumnAlloc(self: DatabaseKind, gpa: std.mem.Allocator, table: *const TableMeta, col: ColumnMeta) !?[]u8 {
        if (!self.isImplemented()) return error.Unsupported;
        if (self == .sqlite) return null;

        const ftype = try self.fieldTypeAlloc(gpa, col);
        defer gpa.free(ftype);

        const default_part = try columnDefaultSql(gpa, self, col);
        defer if (default_part) |d| gpa.free(d);

        var b = Buf.init(gpa);
        defer b.deinit();
        switch (self) {
            .mysql => {
                try b.add("Alter Table ");
                try self.pushQuoted(&b, table.effectiveTableName());
                try b.add(" Modify Column ");
                try self.pushQuoted(&b, table.effectiveColumnName(@constCast(&col)));
                try b.fmt(" {s}", .{ftype});
                if (col.nullable) try b.add(" NULL") else try b.add(" NOT NULL");
                if (default_part) |d| try b.fmt(" DEFAULT {s}", .{d});
                if (col.description.len > 0) {
                    try b.add(" COMMENT '");
                    try pushEscapedMysql(&b, col.description);
                    try b.add("'");
                }
            },
            .sqlserver => {
                try b.add("Alter Table ");
                try self.pushQuoted(&b, table.effectiveTableName());
                try b.add(" Alter Column ");
                try self.pushQuoted(&b, table.effectiveColumnName(@constCast(&col)));
                try b.fmt(" {s}", .{ftype});
                // SQL Server 的 ALTER COLUMN 不接受 DEFAULT（要另用 ADD CONSTRAINT）
                if (col.nullable) try b.add(" NULL") else try b.add(" NOT NULL");
            },
            .postgresql, .kingbase, .highgo, .vastbase => {
                // PG 的 `ALTER COLUMN TYPE` 只改类型，可空性是独立属性（不在这里动）
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
                if (default_part) |d| try b.fmt(" DEFAULT {s}", .{d});
                if (col.nullable) try b.add(" NULL") else try b.add(" NOT NULL");
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

        // ROWNUM 双层包装（Oracle / 达孟 兼容 11g 写法）
        if (self == .oracle or self == .dameng) {
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
            // DB2（C# `DB2.cs`）：rownum 双层；首页无排序时用单层 rownum 优化
            .db2 => {
                const inner = try b.toOwnedSlice();
                defer gpa.free(inner);
                var out = Buf.init(gpa);
                defer out.deinit();
                if (offset == 0 and std.mem.indexOf(u8, inner, "order by") == null and order_sql.len == 0) {
                    try out.fmt("Select * From ({s}) T0 Where rownum<={d}", .{ inner, size });
                } else {
                    try out.fmt("Select * From (Select T0.*, rownum as rowNumber From ({s}) T0) T1 Where rowNumber>{d} And rowNumber<={d}", .{ inner, offset, offset + size });
                }
                return out.toOwnedSlice();
            },
            // Firebird（C# `Firebird.cs`）：`ROWS a TO b`（1 基，闭区间）
            .firebird => {
                const inner = try b.toOwnedSlice();
                defer gpa.free(inner);
                if (offset == 0) {
                    return std.fmt.allocPrint(gpa, "{s} ROWS 1 TO {d}", .{ inner, size });
                }
                return std.fmt.allocPrint(gpa, "{s} ROWS {d} TO {d}", .{ inner, offset + 1, offset + size });
            },
            // Access / SqlCe：只有 TOP，没有 OFFSET 语义
            .access, .sqlce => {
                if (offset != 0) {
                    std.debug.print(
                        "[zcode] {s} 不支持 OFFSET 分页（只有 TOP），offset={d}；请改用 MSSplit 的 TOP 算法或换库\n",
                        .{ self.name(), offset },
                    );
                    return error.Unsupported;
                }
                const inner = try b.toOwnedSlice();
                defer gpa.free(inner);
                if (std.mem.startsWith(u8, inner, "Select ")) {
                    var out = Buf.init(gpa);
                    defer out.deinit();
                    try out.fmt("Select Top {d} {s}", .{ size, inner["Select ".len..] });
                    return out.toOwnedSlice();
                }
                return std.fmt.allocPrint(gpa, "Select Top {d} * From ({s}) T0", .{ size, inner });
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

test "文档库/时序库之外一律可生成 SQL（原「未实现方言」已补齐）" {
    const a = std.testing.allocator;
    const t = sampleTable();

    // ClickHouse 现在能建表（类型名走原生 ClickHouse 类型）
    const ddl = try DatabaseKind.clickhouse.createTableAlloc(a, &t);
    defer {
        for (ddl) |stmt| a.free(stmt);
        a.free(ddl);
    }
    try std.testing.expect(ddl.len > 0);

    // 只有「不是 SQL 库」的两家保持未实现：MongoDB（文档库）、InfluxDB（Line Protocol）
    try std.testing.expect(!DatabaseKind.mongodb.isImplemented());
    try std.testing.expect(!DatabaseKind.influxdb.isImplemented());
    try std.testing.expectError(error.Unsupported, DatabaseKind.mongodb.createTableAlloc(a, &t));
}

test "新补方言：类型名 / 占位符 / 分页（对照 C# 各驱动的 _DataTypes）" {
    const a = std.testing.allocator;

    const col = ColumnMeta{ .name = "C", .data_type = .int32 };
    const sc = ColumnMeta{ .name = "S", .data_type = .string, .length = 50 };
    const dc = ColumnMeta{ .name = "D", .data_type = .decimal, .precision = 18, .scale = 4 };

    const cases = [_]struct { kind: DatabaseKind, int32: []const u8, string50: []const u8, decimal: []const u8 }{
        .{ .kind = .dameng, .int32 = "INT", .string50 = "VARCHAR(50)", .decimal = "DEC(18,4)" },
        .{ .kind = .db2, .int32 = "NUMBER(10,0)", .string50 = "VARCHAR2(50)", .decimal = "NUMBER(18,4)" },
        .{ .kind = .firebird, .int32 = "INT", .string50 = "NVARCHAR(50)", .decimal = "DECIMAL(18,4)" },
        .{ .kind = .hana, .int32 = "INT", .string50 = "VARCHAR(50)", .decimal = "DECIMAL(18,4)" },
        .{ .kind = .iris, .int32 = "INT", .string50 = "VARCHAR(50)", .decimal = "DECIMAL(18,4)" },
        .{ .kind = .nova, .int32 = "INT", .string50 = "VARCHAR(50)", .decimal = "DECIMAL(18,4)" },
        .{ .kind = .access, .int32 = "int", .string50 = "nvarchar(50)", .decimal = "money" },
        .{ .kind = .sqlce, .int32 = "int", .string50 = "nvarchar(50)", .decimal = "money" },
        .{ .kind = .duckdb, .int32 = "INTEGER", .string50 = "VARCHAR", .decimal = "DECIMAL(18,4)" },
        .{ .kind = .clickhouse, .int32 = "Int32", .string50 = "String", .decimal = "Decimal(18, 4)" },
        .{ .kind = .tdengine, .int32 = "INT", .string50 = "NCHAR(50)", .decimal = "DOUBLE" },
    };
    for (cases) |c| {
        const i32_type = try c.kind.fieldTypeAlloc(a, col);
        defer a.free(i32_type);
        try std.testing.expectEqualStrings(c.int32, i32_type);

        const s_type = try c.kind.fieldTypeAlloc(a, sc);
        defer a.free(s_type);
        try std.testing.expectEqualStrings(c.string50, s_type);

        const d_type = try c.kind.fieldTypeAlloc(a, dc);
        defer a.free(d_type);
        try std.testing.expectEqualStrings(c.decimal, d_type);
    }

    // 占位符：达梦走 `:n`（Oracle 口径）
    var b = Buf.init(a);
    defer b.deinit();
    try DatabaseKind.dameng.pushPlaceholder(&b, 0);
    try std.testing.expectEqualStrings(":1", b.slice());

    // 分页：DB2 rownum 双层、Firebird `ROWS a TO b`、Access 只支持首页 TOP
    const db2_page = try DatabaseKind.db2.applyPagingAlloc(a, "Select * From T", "Order By Id", 10, 5);
    defer a.free(db2_page);
    try std.testing.expect(std.mem.indexOf(u8, db2_page, "rownum") != null);

    const fb_page = try DatabaseKind.firebird.applyPagingAlloc(a, "Select * From T", "", 10, 5);
    defer a.free(fb_page);
    try std.testing.expectEqualStrings("Select * From T ROWS 11 TO 15", fb_page);

    const access_page = try DatabaseKind.access.applyPagingAlloc(a, "Select * From T", "", 0, 5);
    defer a.free(access_page);
    try std.testing.expectEqualStrings("Select Top 5 * From T", access_page);
    try std.testing.expectError(error.Unsupported, DatabaseKind.access.applyPagingAlloc(a, "Select * From T", "", 5, 5));
}

test "Provider 解析" {
    try std.testing.expectEqual(DatabaseKind.sqlite, DatabaseKind.fromProvider("SQLite").?);
    try std.testing.expectEqual(DatabaseKind.mysql, DatabaseKind.fromProvider("mysql").?);
    try std.testing.expectEqual(DatabaseKind.postgresql, DatabaseKind.fromProvider("PostgreSQL").?);
    try std.testing.expectEqual(DatabaseKind.sqlserver, DatabaseKind.fromProvider("MSSQL").?);
    try std.testing.expect(DatabaseKind.fromProvider("unknown-db") == null);
}
