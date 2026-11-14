//! 连接与结构迁移（对应 DH.NCode `DAL` / Rust `Pek.RCode/src/dal.rs` 的第一轮子集）。
//!
//! - 连接串与 XCode 一致：`Data Source=..\Data\DG.db;Provider=SQLite;ShowSql=false;Migration=On`
//! - `syncSchema` 只做**增量安全**动作：缺表建表、缺列补列、缺索引建索引；
//!   **不删列、不改列类型、不删索引**（C# 的 `Full` 档删除/改列本轮未实现，显式报告）
//! - 迁移档位：`Off` 不做任何 DDL、`ReadOnly` 只生成不执行、`On`/`Full` 执行增量

const std = @import("std");
const model = @import("model.zig");
const EntityModel = model.EntityModel;
const Migration = model.Migration;
const dialect = @import("dialect.zig");
const DatabaseKind = dialect.DatabaseKind;
const sqlite = @import("zzig").sqlite;
const mysql = @import("zzig").mysql;
const postgres = @import("zzig").postgres;
const tds = @import("zzig").tds;
const tdengine = @import("zzig").tdengine;
const influxdb = @import("zzig").influxdb;
const clickhouse = @import("zzig").clickhouse;
const mongodb = @import("zzig").mongodb;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const dbtable = @import("dbtable.zig");
const TableRef = dbtable.TableRef;
const readwrite = @import("readwrite.zig");
const shards = @import("shards.zig");
const interceptor = @import("interceptor.zig");
const pool = @import("pool.zig");
const sqlbuild = @import("sqlbuild.zig");
const Value = @import("zzig").db.Value;

pub const ConnectionOptions = struct {
    provider: DatabaseKind = .sqlite,
    data_source: []const u8 = "",
    migration: ?Migration = null,
    /// 连接串 `ShowSQL=True/False`：`null` = 未指定，跟随全局 `Setting.show_sql`
    show_sql: ?bool = null,
    read_only: bool = false,
    pooling: ?bool = null,
    /// MySQL 专属（`Provider=MySQL` 时才用）：服务器 / 端口 / 账号 / 库名
    server: []const u8 = "",
    port: u16 = 3306,
    user: []const u8 = "",
    password: []const u8 = "",
    database: []const u8 = "",
    /// SQL Server 命名管道路径（`\\.\pipe\...`）。非空时忽略 server/port——LocalDB 只能走管道。
    pipe_name: []const u8 = "",
    /// MySQL TLS 档位（`SslMode`）：缺省 `preferred`（服务端支持就加密）
    ssl_mode: mysql.SslMode = .preferred,
    /// 根证书文件（`SslCa`/`CertificateFile`），`verify_ca`/`verify_full` 用；空 = 系统根证书
    ssl_ca: []const u8 = "",
    /// 压缩协议（`Compression=True`）：缺省关闭（与 MySqlConnector 的 `UseCompression` 缺省一致）
    compress: bool = false,
    // ── SQLite 并发设置（对应 PRAGMA；MySQL/PG 忽略）────────
    /// `JournalMode=WAL|DELETE|MEMORY|OFF`：`null` = **不设置**（SQLite 原生 `delete`）。
    /// 实测见 `docs/决策记录.md` 第（三十九）节：单行一事务下 WAL 反而慢 2×；
    /// 只有「长写事务同时要别人能读」才值得显式开 WAL，网络盘一律开不得
    journal_mode: ?[]const u8 = null,
    /// `Synchronous=Normal|Full|Off`（也认 0/1/2）：`null` = **不设置**（原生 `full`）
    synchronous: ?[]const u8 = null,
    /// `CacheSize=-64000`：`null` = 用库默认（负数=KB，正数=页数）
    cache_size: ?i32 = null,
    // ── InfluxDB 专属（`Provider=InfluxDB` 时才用）───────────
    /// v2 令牌（`Token=`；也可写 `Password=`）
    token: []const u8 = "",
    /// v2 组织（`Org=` / `Organization=`）
    org: []const u8 = "",
    /// v2 桶（`Bucket=`）。配了 bucket 就走 v2，否则走 v1 的 `Database`
    bucket: []const u8 = "",
    /// MongoDB 鉴权库（`AuthSource=`；空 = 用 `Database`，惯例是 `admin`）
    auth_source: []const u8 = "",
    /// HTTP 驱动（TDengine / InfluxDB）的请求超时（毫秒；0 = 不限）
    timeout_ms: u64 = 30_000,
    /// 未识别的键值（原样保留，便于诊断/向前兼容）
    extra: []model.KeyValue = &.{},

    /// 释放自持内存（`data_source` / MySQL 字段 / `extra`）。
    pub fn deinit(self: *ConnectionOptions, gpa: std.mem.Allocator) void {
        if (self.data_source.len > 0) gpa.free(self.data_source);
        if (self.server.len > 0) gpa.free(self.server);
        if (self.user.len > 0) gpa.free(self.user);
        if (self.password.len > 0) gpa.free(self.password);
        if (self.database.len > 0) gpa.free(self.database);
        if (self.ssl_ca.len > 0) gpa.free(self.ssl_ca);
        if (self.token.len > 0) gpa.free(self.token);
        if (self.org.len > 0) gpa.free(self.org);
        if (self.bucket.len > 0) gpa.free(self.bucket);
        if (self.auth_source.len > 0) gpa.free(self.auth_source);
        if (self.extra.len > 0) gpa.free(self.extra);
        if (self.journal_mode) |v| gpa.free(v);
        if (self.synchronous) |v| gpa.free(v);
        self.journal_mode = null;
        self.synchronous = null;
        self.data_source = "";
        self.server = "";
        self.user = "";
        self.password = "";
        self.database = "";
        self.ssl_ca = "";
        self.pipe_name = "";
        self.token = "";
        self.org = "";
        self.bucket = "";
        self.auth_source = "";
        self.extra = &.{};
    }
};

/// 解析连接串（键名忽略大小写，值保留原样）。
///
/// 认得的键：`Provider` / `Data Source`（别名 `DataSource`/`Filename`）/
/// `Migration` / `ShowSql` / `Readonly` / `Pooling`；其余键进 `extra`。
pub fn parseConnectionString(gpa: std.mem.Allocator, conn_str: []const u8) !ConnectionOptions {
    var opts = ConnectionOptions{};
    // 任何中途失败都要把已复制的字段还回去（`deinit` 对空字段是安全的）
    errdefer opts.deinit(gpa);
    var extra: std.ArrayList(model.KeyValue) = .empty;
    errdefer extra.deinit(gpa);

    var it = std.mem.splitScalar(u8, conn_str, ';');
    while (it.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t\r\n");
        if (segment.len == 0) continue;
        const eq_pos = std.mem.indexOfScalar(u8, segment, '=') orelse continue;
        const key = std.mem.trim(u8, segment[0..eq_pos], " \t\r\n");
        const value = std.mem.trim(u8, segment[eq_pos + 1 ..], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(key, "Provider")) {
            opts.provider = DatabaseKind.fromProvider(value) orelse return error.Unsupported;
        } else if (std.ascii.eqlIgnoreCase(key, "Data Source") or
            std.ascii.eqlIgnoreCase(key, "DataSource") or
            std.ascii.eqlIgnoreCase(key, "Filename") or
            std.ascii.eqlIgnoreCase(key, "DataBase"))
        {
            // **必须复制**：连接串通常来自临时缓冲，Dal 生命周期远长于它
            opts.data_source = try gpa.dupe(u8, value);
            if (std.ascii.eqlIgnoreCase(key, "DataBase")) {
                opts.database = try gpa.dupe(u8, value);
            }
        } else if (std.ascii.eqlIgnoreCase(key, "Server") or std.ascii.eqlIgnoreCase(key, "Host")) {
            // ADO.NET 习惯：`Server=np:\\.\pipe\...` 表示走命名管道（LocalDB 专用）
            if (std.ascii.startsWithIgnoreCase(value, "np:") or std.ascii.startsWithIgnoreCase(value, "\\\\.\\pipe\\")) {
                opts.pipe_name = try gpa.dupe(u8, value);
                opts.server = try gpa.dupe(u8, "(pipe)");
            } else {
                opts.server = try gpa.dupe(u8, value);
            }
        } else if (std.ascii.eqlIgnoreCase(key, "Pipe") or std.ascii.eqlIgnoreCase(key, "PipeName")) {
            opts.pipe_name = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Port")) {
            opts.port = std.fmt.parseInt(u16, value, 10) catch 3306;
        } else if (std.ascii.eqlIgnoreCase(key, "Uid") or std.ascii.eqlIgnoreCase(key, "User") or
            std.ascii.eqlIgnoreCase(key, "User Id") or std.ascii.eqlIgnoreCase(key, "UserId") or
            std.ascii.eqlIgnoreCase(key, "UserID") or std.ascii.eqlIgnoreCase(key, "Username"))
        {
            opts.user = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Pwd") or std.ascii.eqlIgnoreCase(key, "Password")) {
            opts.password = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "SslMode") or std.ascii.eqlIgnoreCase(key, "Ssl Mode") or
            std.ascii.eqlIgnoreCase(key, "SSLMode"))
        {
            // 认不出的取值不能静默当成缺省：那是「以为加密实际明文」的根源
            opts.ssl_mode = mysql.SslMode.parse(value) orelse {
                std.debug.print(
                    "[zcode] 连接串 SslMode={s} 无法识别（可用：None/Disabled/Preferred/Required/VerifyCA/VerifyFull）\n",
                    .{value},
                );
                return error.InvalidSslMode;
            };
        } else if (std.ascii.eqlIgnoreCase(key, "SslCa") or std.ascii.eqlIgnoreCase(key, "Ssl CA") or
            std.ascii.eqlIgnoreCase(key, "CertificateFile") or std.ascii.eqlIgnoreCase(key, "SslCert"))
        {
            opts.ssl_ca = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Compression") or std.ascii.eqlIgnoreCase(key, "Compress") or
            std.ascii.eqlIgnoreCase(key, "UseCompression"))
        {
            opts.compress = parseBool(value);
        } else if (std.ascii.eqlIgnoreCase(key, "Migration")) {
            opts.migration = Migration.parse(value);
        } else if (std.ascii.eqlIgnoreCase(key, "ShowSql")) {
            opts.show_sql = parseBool(value);
        } else if (std.ascii.eqlIgnoreCase(key, "Readonly") or std.ascii.eqlIgnoreCase(key, "ReadOnly")) {
            opts.read_only = parseBool(value);
        } else if (std.ascii.eqlIgnoreCase(key, "Pooling")) {
            opts.pooling = parseBool(value);
        } else if (std.ascii.eqlIgnoreCase(key, "JournalMode")) {
            opts.journal_mode = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Synchronous")) {
            // 允许 0/1/2 数字写法（SQLite 原生约定）与 OFF/NORMAL/FULL 文本
            opts.synchronous = try gpa.dupe(u8, if (std.mem.eql(u8, value, "0"))
                "OFF"
            else if (std.mem.eql(u8, value, "1"))
                "NORMAL"
            else if (std.mem.eql(u8, value, "2"))
                "FULL"
            else
                value);
        } else if (std.ascii.eqlIgnoreCase(key, "CacheSize")) {
            opts.cache_size = std.fmt.parseInt(i32, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(key, "Token")) {
            // InfluxDB v2 令牌（`Authorization: Token xxx`）
            opts.token = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Org") or std.ascii.eqlIgnoreCase(key, "Organization")) {
            opts.org = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Bucket")) {
            opts.bucket = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "AuthSource")) {
            // MongoDB 鉴权库（缺省用 Database，惯例 admin）
            opts.auth_source = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Timeout") or std.ascii.eqlIgnoreCase(key, "TimeoutMs")) {
            // HTTP 驱动（TDengine / InfluxDB）的请求超时（毫秒）
            opts.timeout_ms = std.fmt.parseInt(u64, value, 10) catch opts.timeout_ms;
        } else {
            try extra.append(gpa, .{ .key = key, .value = value });
        }
    }
    opts.extra = try extra.toOwnedSlice(gpa);
    return opts;
}

fn parseBool(v: []const u8) bool {
    return std.ascii.eqlIgnoreCase(v, "true") or std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "yes");
}

/// 测试用：在临时目录下生成一个唯一库文件路径（调用方负责 free + 删文件）。
fn tempDbPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    return @import("zzig").File.UniqueTempName(a, tag, ".db");
}

pub const SchemaReport = struct {
    tables_created: usize = 0,
    columns_added: usize = 0,
    indexes_created: usize = 0,
    tables_skipped: usize = 0,
    /// 仅 `Migration=Full`：删除模型里已不存在的列
    columns_dropped: usize = 0,
    /// 仅 `Migration=Full`：删除模型里已不存在的索引
    indexes_dropped: usize = 0,
    /// 仅 `Migration=Full`：改了类型/长度的列（SQLite 走整表重建）
    columns_altered: usize = 0,
    /// 生成但未执行（`Migration=ReadOnly`）
    executed: bool = true,

    pub fn describeAlloc(self: SchemaReport, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            gpa,
            "结构同步：建表 {d} / 补列 {d} / 改列 {d} / 建索引 {d} / 删列 {d} / 删索引 {d} / 跳过 {d}{s}",
            .{
                self.tables_created,  self.columns_added,   self.columns_altered,
                self.indexes_created, self.columns_dropped, self.indexes_dropped,
                self.tables_skipped,
                if (self.executed) "" else "（只读：未执行）",
            },
        );
    }
};

// ── 服务端版本探测的打包编码（供 `Dal.probe_code` 用）──────────────────────

const probe_unset: u64 = 0;
const probe_failed: u64 = 1;

/// `[flavor:8][major:16][minor:16][patch:16]` + 1（让 0 永远留给「未探测」）。
fn packServerVersion(v: dialect.ServerVersion) u64 {
    const flavor: u64 = @backingInt(v.flavor) & 0xFF;
    return 1 + (flavor << 48) + (@as(u64, v.major) << 32) + (@as(u64, v.minor) << 16) + @as(u64, v.patch);
}

fn unpackServerVersion(code: u64) ?dialect.ServerVersion {
    if (code < 2) return null;
    const raw = code - 1;
    return .{
        .major = @intCast((raw >> 32) & 0xFFFF),
        .minor = @intCast((raw >> 16) & 0xFFFF),
        .patch = @intCast(raw & 0xFFFF),
        .flavor = @fromBackingInt(@intCast(@as(u8, @intCast((raw >> 48) & 0xFF)))),
    };
}

pub const Dal = struct {
    gpa: std.mem.Allocator,
    model: EntityModel,
    opts: ConnectionOptions,
    /// SQLite 动态库句柄（`Provider=MySQL` 时为 null，MySQL 走纯协议不需外部库）
    lib: ?sqlite.Lib = null,
    /// DuckDB 动态库句柄（`Provider=DuckDB` 时用；生命周期与 Dal 一致）
    duck_lib: ?@import("zzig").duckdb.Lib = null,
    /// 整表实体缓存注册表（写操作后按表名使缓存失效）
    cache_hooks: std.ArrayListUnmanaged(CacheHook) = .empty,
    /// 读写分离策略（忽略表 / 全局切主库）
    strategy: readwrite.Strategy,
    /// 只读副本（从库）连接参数；为空时读操作走主库
    replicas: std.ArrayListUnmanaged(ConnectionOptions) = .empty,
    /// 副本轮询下标
    rr_index: usize = 0,
    /// 分表策略注册表（按模型表名）
    shard_routes: std.ArrayListUnmanaged(ShardRoute) = .empty,
    /// 额外挂载的命名连接（跨库分片 / 多库共存用）
    connections: std.ArrayListUnmanaged(NamedConn) = .empty,
    /// 写入拦截器链（不拥有，由调用方创建与销毁）
    chain: ?*interceptor.Chain = null,
    /// 跨进程缓存版本协调器（可选，类型擦除——避免 `dal` ← `dbcache` 循环依赖）
    remote_cache: ?RemoteCache = null,
    /// 服务端版本探测缓存（**整套 Dal 只探一次**，之后纯内存读，零往返）。
    ///
    /// `0` = 未探测；`1` = 探测过但失败（走保守档）；`≥2` = `1 + 打包(major,minor,patch,flavor)`。
    /// 用**单个** atomic 而不是「version + flavor 两个字段」：多线程同时读时才不会读到
    /// 「版本是新的、flavor 还是旧的」这种撕裂组合。
    probe_code: std.atomic.Value(u64) = std.atomic.Value(u64).init(probe_unset),
    /// 「版本未知 → 保守档」只告警一次，避免高频路径刷日志
    probe_warned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// 跨进程缓存版本协调器（`dbcache.CacheInvalidator` 的注入面）。
    ///
    /// 多系统共用同一张表时，本地缓存必须能感知**别的进程**的写入：
    /// - 写方：本 Dal 任何写操作 → `bump`（递增分布式版本号）
    /// - 读方：`Cache` / `SingleCache` 定时 `poll` 后比对 `localVersion`，变了就过期本地缓存
    ///
    /// 注意：`bump` 实现**不得**回调 `Dal.invalidateCaches`（本地已由本 Dal 失效，会无限递归）。
    pub const RemoteCache = struct {
        ctx: *anyopaque,
        bump: *const fn (ctx: *anyopaque, table_name: []const u8) void,
        /// 本地已知版本（**纯内存**，不得有网络开销）
        local_version: *const fn (ctx: *anyopaque, table_name: []const u8) i64,
        /// 拉一次远端版本；返回变更表数
        poll: *const fn (ctx: *anyopaque) usize,
        /// 登记表：首次读时记下当前版本，避免第一轮误判为「变化」
        attach: *const fn (ctx: *anyopaque, table_name: []const u8) void,
    };

    /// 一条分表路由：表名 + 策略（表名/模板字符串由 Dal 持有）
    pub const ShardRoute = struct {
        table_name: []const u8,
        policy: shards.TimePolicy,
    };

    /// 额外挂载的命名连接（对应 `ConnPolicy` 指向的另一个库）
    pub const NamedConn = struct {
        name: []const u8,
        opts: ConnectionOptions,
    };

    /// 缓存注册项：类型擦除的回调（连接名 + 表名 + 失效函数）。
    ///
    /// - `invalidate`：**整体**失效（整表缓存只能整体失效；不知道影响哪几行时也是它）
    /// - `invalidate_key`：**精确**失效单行（单对象缓存；`null` = 该缓存不支持精确失效）
    /// - `conn_name`：连接名（空 = 主连接），与表名一起构成缓存作用域 ——
    ///   分库场景下不同库可能存在**同名表**，只按表名匹配会串缓存
    pub const CacheHook = struct {
        table_name: []const u8,
        ctx: *anyopaque,
        invalidate: *const fn (ctx: *anyopaque) void,
        invalidate_key: ?*const fn (ctx: *anyopaque, key: i64) void = null,
        conn_name: []const u8 = "",
    };

    /// 从 `Model.xml` 文件打开。
    pub fn open(gpa: std.mem.Allocator, conn_str: []const u8, model_path: []const u8) !Dal {
        var m = try EntityModel.load(gpa, model_path);
        errdefer m.deinit();
        return initWithModel(gpa, conn_str, m);
    }

    /// 用已解析的模型打开（模型所有权转移给 Dal；**失败时由本函数释放**）。
    pub fn initWithModel(gpa: std.mem.Allocator, conn_str: []const u8, m_in: EntityModel) !Dal {
        var opts_owned = try parseConnectionString(gpa, conn_str);
        errdefer freeOptions(gpa, &opts_owned);

        // 校验失败时模型必须释放：调用方已把所有权交出来，不能再指望它 deinit
        const m = m_in;
        errdefer {
            var owned = m;
            owned.deinit();
        }

        switch (opts_owned.provider) {
            .sqlite => {
                if (opts_owned.data_source.len == 0) return error.NoConnection;
                const lib = try sqlite.Lib.load(gpa);
                return Dal{
                    .gpa = gpa,
                    .model = m,
                    .opts = opts_owned,
                    .lib = lib,
                    .strategy = readwrite.Strategy.init(gpa),
                };
            },
            .mysql, .nova => {
                // MySQL 连接串的 "host" 可能写在 Server / Data Source 任一键里
                if (opts_owned.server.len == 0 and opts_owned.data_source.len > 0) {
                    opts_owned.server = try gpa.dupe(u8, opts_owned.data_source);
                }
                if (opts_owned.server.len == 0) return error.NoConnection;
                if (opts_owned.database.len == 0) return error.NoDatabase;
                return Dal{
                    .gpa = gpa,
                    .model = m,
                    .opts = opts_owned,
                    .strategy = readwrite.Strategy.init(gpa),
                };
            },
            .postgresql, .kingbase, .highgo, .vastbase => {
                if (opts_owned.server.len == 0 and opts_owned.data_source.len > 0) {
                    opts_owned.server = try gpa.dupe(u8, opts_owned.data_source);
                }
                if (opts_owned.server.len == 0) return error.NoConnection;
                if (opts_owned.database.len == 0) return error.NoDatabase;
                // 端口缺省以方言为准（PG 5432），不能沿用 MySQL 的 3306
                // 金仓 / 瀚高 / 海量都是 PG 协议分支，端口同 5432
                if (opts_owned.port == 3306) opts_owned.port = postgres.default_port;
                return Dal{
                    .gpa = gpa,
                    .model = m,
                    .opts = opts_owned,
                    .strategy = readwrite.Strategy.init(gpa),
                };
            },
            .sqlserver => {
                if (opts_owned.server.len == 0 and opts_owned.data_source.len > 0) {
                    opts_owned.server = try gpa.dupe(u8, opts_owned.data_source);
                }
                // 命名管道（LocalDB）不需要 server
                if (opts_owned.server.len == 0 and opts_owned.pipe_name.len == 0) return error.NoConnection;
                if (opts_owned.database.len == 0) return error.NoDatabase;
                // 端口缺省以方言为准（SQL Server 1433）
                if (opts_owned.port == 3306) opts_owned.port = tds.default_port;
                return Dal{
                    .gpa = gpa,
                    .model = m,
                    .opts = opts_owned,
                    .strategy = readwrite.Strategy.init(gpa),
                };
            },
            .tdengine => {
                if (opts_owned.server.len == 0 and opts_owned.data_source.len > 0) {
                    opts_owned.server = try gpa.dupe(u8, opts_owned.data_source);
                }
                if (opts_owned.server.len == 0) return error.NoConnection;
                // 端口缺省以方言为准（TDengine REST 6041）
                if (opts_owned.port == 3306) opts_owned.port = tdengine.default_port;
                return Dal{
                    .gpa = gpa,
                    .model = m,
                    .opts = opts_owned,
                    .strategy = readwrite.Strategy.init(gpa),
                };
            },
            .influxdb => {
                if (opts_owned.server.len == 0 and opts_owned.data_source.len > 0) {
                    opts_owned.server = try gpa.dupe(u8, opts_owned.data_source);
                }
                if (opts_owned.server.len == 0) return error.NoConnection;
                // v2 用 bucket / v1 用 database：两者都没配就无法定位数据
                if (opts_owned.bucket.len == 0 and opts_owned.database.len == 0) return error.NoDatabase;
                if (opts_owned.port == 3306) opts_owned.port = influxdb.default_port;
                return Dal{
                    .gpa = gpa,
                    .model = m,
                    .opts = opts_owned,
                    .strategy = readwrite.Strategy.init(gpa),
                };
            },
            .clickhouse => {
                if (opts_owned.server.len == 0 and opts_owned.data_source.len > 0) {
                    opts_owned.server = try gpa.dupe(u8, opts_owned.data_source);
                }
                if (opts_owned.server.len == 0) return error.NoConnection;
                // 端口缺省以方言为准（ClickHouse HTTP 8123）
                if (opts_owned.port == 3306) opts_owned.port = clickhouse.default_port;
                return Dal{
                    .gpa = gpa,
                    .model = m,
                    .opts = opts_owned,
                    .strategy = readwrite.Strategy.init(gpa),
                };
            },
            .mongodb => {
                if (opts_owned.server.len == 0 and opts_owned.data_source.len > 0) {
                    opts_owned.server = try gpa.dupe(u8, opts_owned.data_source);
                }
                if (opts_owned.server.len == 0) return error.NoConnection;
                // 端口缺省以方言为准（MongoDB 27017）
                if (opts_owned.port == 3306) opts_owned.port = mongodb.default_port;
                return Dal{
                    .gpa = gpa,
                    .model = m,
                    .opts = opts_owned,
                    .strategy = readwrite.Strategy.init(gpa),
                };
            },
            .duckdb => {
                if (opts_owned.data_source.len == 0) return error.NoConnection;
                // 嵌入式：先把库找好（缺库就立即报，不拖到第一次查询）
                var d = Dal{
                    .gpa = gpa,
                    .model = m,
                    .opts = opts_owned,
                    .strategy = readwrite.Strategy.init(gpa),
                };
                d.duck_lib = @import("zzig").duckdb.Lib.load(gpa) catch |e| {
                    std.debug.print("[zcode] DuckDB 不可用（{s}）：请把 duckdb.dll 放到 exe 同目录或 PATH\n", .{@errorName(e)});
                    return e;
                };
                return d;
            },
            else => return error.Unsupported,
        }
    }

    pub fn deinit(self: *Dal) void {
        self.cache_hooks.deinit(self.gpa);
        self.strategy.deinit();
        for (self.replicas.items) |*o| o.deinit(self.gpa);
        self.replicas.deinit(self.gpa);
        for (self.shard_routes.items) |*route| {
            self.gpa.free(route.table_name);
            if (route.policy.field.len > 0) self.gpa.free(route.policy.field);
            if (route.policy.base_conn.len > 0) self.gpa.free(route.policy.base_conn);
            if (route.policy.base_table.len > 0) self.gpa.free(route.policy.base_table);
            if (route.policy.conn_policy) |tpl| self.gpa.free(tpl);
            if (route.policy.table_policy) |tpl| self.gpa.free(tpl);
        }
        self.shard_routes.deinit(self.gpa);
        for (self.connections.items) |*c| {
            self.gpa.free(c.name);
            c.opts.deinit(self.gpa);
        }
        self.connections.deinit(self.gpa);
        if (self.lib) |*lib| lib.deinit();
        if (self.duck_lib) |*lib| lib.module.close(self.gpa);
        self.opts.deinit(self.gpa);
        self.model.deinit();
    }

    /// 注册整表缓存（由 `cache.Cache(T).init` 调用）。
    pub fn registerCache(self: *Dal, hook: CacheHook) !void {
        try self.cache_hooks.append(self.gpa, hook);
    }

    /// 注销整表缓存（按 ctx 指针匹配；同一缓存若误注册多次也会一次清干净）。
    pub fn unregisterCache(self: *Dal, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < self.cache_hooks.items.len) {
            if (self.cache_hooks.items[i].ctx == ctx) {
                _ = self.cache_hooks.swapRemove(i);
                continue; // 不前进：swapRemove 把末尾元素换到了 i
            }
            i += 1;
        }
    }

    /// 写后失效：只通知与该表匹配的缓存（不带连接/主键，等价于整体失效）。
    pub fn invalidateCaches(self: *Dal, table_name: []const u8) void {
        self.invalidateCachesOn(table_name, null, null);
    }

    /// 写后失效（带连接名与主键）。
    ///
    /// - `conn_name == null`：不知道连接，按表名匹配所有作用域（兼容旧调用）
    /// - `key != null`：优先走缓存的**精确失效**（单对象缓存只删那一条，不清整表）；
    ///   不支持精确失效的缓存（整表缓存）退回整体失效
    pub fn invalidateCachesOn(self: *Dal, table_name: []const u8, conn_name: ?[]const u8, key: ?i64) void {
        // 早退：没有任何缓存、也没挂跨进程版本协调器时零开销
        if (self.cache_hooks.items.len == 0 and self.remote_cache == null) return;

        // 调用方给的可能是**实体名**（`Small`）也可能是**物理表名**（`BH_Small`），
        // 而 `TableRef` 的写通知一律用物理名 —— 这里归一后两种都比一次，
        // 否则「实体名 ≠ 物理名」的表在写完之后缓存永远不失效（实测踩过）。
        const phys = if (self.model.table(table_name)) |t| t.effectiveTableName() else table_name;
        for (self.cache_hooks.items) |hook| {
            if (!std.ascii.eqlIgnoreCase(hook.table_name, phys) and
                !std.ascii.eqlIgnoreCase(hook.table_name, table_name)) continue;

            if (conn_name) |cn| {
                // 钩子未声明连接名（空）= 通配，兼容不关心分库的缓存（字段缓存等）；
                // 声明了就必须一致，否则「分库同名表」会互相串缓存。
                if (hook.conn_name.len > 0 and !std.ascii.eqlIgnoreCase(hook.conn_name, cn)) continue;
            }

            if (key) |k| {
                if (hook.invalidate_key) |f| {
                    f(hook.ctx, k);
                    continue;
                }
            }
            hook.invalidate(hook.ctx);
        }

        // 多系统共用表：把「这张表变了」广播给其它进程（本地已失效，这里只递增版本号）
        if (self.remote_cache) |rc| rc.bump(rc.ctx, phys);
    }

    // ── 行数：恒定成本判定 / 大表统计估算 ──────────────────────

    /// 「至多 `limit` 行」的计数：`min(实际行数, limit)`，**成本与表大小无关**。
    ///
    /// 用来判定「这张表是否超过某阈值」（如整表缓存上限），不要在大表上直接 `COUNT(*)`。
    pub fn countUpTo(self: *Dal, s: *Session, table_name: []const u8, limit: u64) !i64 {
        const sql = try sqlbuild.countUpTo(self.gpa, self.opts.provider, self.physicalName(table_name), limit);
        defer sql.deinit(self.gpa);
        const v = try s.queryScalar(sql.text, sql.params);
        if (v) |value| return value.asI64() orelse 0;
        return 0;
    }

    /// 精确 `COUNT(*)`（大表上很慢，业务侧优先用 `countTotal`）。
    pub fn countRows(self: *Dal, s: *Session, table_name: []const u8) !i64 {
        var ref = try self.table(table_name);
        return ref.count(s, null);
    }

    /// 表总行数：小表精确、大表走统计估算（消费 `Setting.full_count_floor`）。
    ///
    /// 1. 先用 `countUpTo(floor+1)`：`<= floor` 说明是小表，**直接就是精确值**（成本 ≤ floor 行）；
    /// 2. 超过 floor → 读数据库统计（`sqlite_stat1` / `information_schema` / `pg_class` / …）；
    /// 3. 统计拿不到 → 打警告退回精确 `COUNT(*)`（此时慢是可预期的，提示去 ANALYZE）。
    pub fn countTotal(self: *Dal, s: *Session, table_name: []const u8) !i64 {
        const floor = @import("setting.zig").current().full_count_floor;
        const phys = self.physicalName(table_name);
        if (floor > 0) {
            const up = try self.countUpTo(s, table_name, @as(u64, @intCast(floor)) + 1);
            if (up <= floor) return up;
            if (try self.countApprox(s, phys)) |est| {
                if (est > 0) return est;
            }
            std.debug.print(
                "[zcode] 大表 {s} 缺少统计信息（SQLite 先 ANALYZE / MySQL 开 innodb_stats_on_metadata 或 ANALYZE TABLE），" ++
                    "退回精确 COUNT(*)，可能很慢\n",
                .{phys},
            );
        }
        return self.countRows(s, table_name);
    }

    /// 从数据库统计信息取近似行数；拿不到返回 `null`（不同方言实现不同）。
    pub fn countApprox(self: *Dal, s: *Session, table_name: []const u8) !?i64 {
        // 占位符必须按方言生成（PG 是 `$1`、SQL Server 是 `@p0`），不能硬写 `?`。
        // 前缀走运行期切片，占位符用 `pushPlaceholder` 追加（`allocPrint` 要求格式串 comptime 已知）。
        const prefix: ?[]const u8 = switch (self.opts.provider) {
            // stat 形如 "1234 5 3"，取第一段；多索引多行 → 取 MAX 避免重复累加
            .sqlite => "SELECT MAX(CAST(substr(stat, 1, instr(stat || ' ', ' ') - 1) AS INTEGER)) FROM sqlite_stat1 WHERE tbl = ",
            .mysql => "SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ",
            .postgresql => "SELECT reltuples::bigint FROM pg_class WHERE relname = ",
            .sqlserver => "SELECT SUM(p.rows) FROM sys.partitions p JOIN sys.objects o ON p.object_id = o.object_id WHERE o.name = ",
            .oracle => "SELECT NUM_ROWS FROM USER_TABLES WHERE TABLE_NAME = ",
            else => null,
        };
        const pre = prefix orelse return null;

        const Buf = @import("zzig").Buf;
        var b = Buf.init(self.gpa);
        defer b.deinit();
        try b.add(pre);
        try self.opts.provider.pushPlaceholder(&b, 0);
        if (self.opts.provider == .postgresql) try b.add(" AND relkind IN ('r', 'p') ORDER BY reltuples DESC LIMIT 1");
        if (self.opts.provider == .sqlserver) try b.add(" AND p.index_id IN (0, 1)");
        const text = try b.toOwnedSlice();
        defer self.gpa.free(text);

        var params: [1]Value = .{.{ .text = table_name }};
        const v = s.queryScalar(text, &params) catch |e| {
            // 统计表不存在 / 无权限（SQLite 没跑过 ANALYZE 等）属正常情况，不当错误抛出
            std.debug.print("[zcode] 读取 {s} 的统计信息失败（{s}），按「无统计」处理\n", .{ table_name, @errorName(e) });
            return null;
        };
        if (v) |value| {
            if (value.asI64()) |n| {
                if (n >= 0) return n;
            }
        }
        return null;
    }

    /// 实体名 → 物理表名（未知表原样返回）。
    pub fn physicalName(self: *const Dal, name: []const u8) []const u8 {
        if (self.model.table(name)) |t| return t.effectiveTableName();
        return name;
    }

    // ── 读写分离 ────────────────────────────────────────────────

    /// 读写分离策略（可直接改忽略表 / 全局切主库）。
    pub fn readStrategy(self: *Dal) *readwrite.Strategy {
        return &self.strategy;
    }

    /// 挂载只读副本（从库）连接串；解析失败或方言不一致时整体失败，不半途生效。
    pub fn attachReplicas(self: *Dal, conn_strs: []const []const u8) !void {
        var staged: std.ArrayListUnmanaged(ConnectionOptions) = .empty;
        errdefer {
            for (staged.items) |*o| o.deinit(self.gpa);
            staged.deinit(self.gpa);
        }

        for (conn_strs) |cs| {
            var o = try parseConnectionString(self.gpa, cs);
            if (o.provider != self.opts.provider) {
                std.debug.print(
                    "[zcode] 读写分离：从库方言 {s} 与主库 {s} 不一致，拒绝挂载（{s}）\n",
                    .{ @tagName(o.provider), @tagName(self.opts.provider), cs },
                );
                o.deinit(self.gpa);
                return error.Unsupported;
            }
            try staged.append(self.gpa, o);
        }

        for (self.replicas.items) |*o| o.deinit(self.gpa);
        self.replicas.deinit(self.gpa);
        self.replicas = staged;
        self.rr_index = 0;
    }

    pub fn replicaCount(self: *const Dal) usize {
        return self.replicas.items.len;
    }

    /// 临时全量切主库（对应 C# `SuspendReadOnly` / `ResumeReadOnly` 的场景）。
    pub fn setPrimaryOnly(self: *Dal, value: bool) void {
        self.strategy.setPrimaryOnly(value);
    }

    pub fn isPrimaryOnly(self: *const Dal) bool {
        return self.strategy.isPrimaryOnly();
    }

    /// 取只读会话：有从库且策略允许时轮询从库，否则回落到主库。
    pub fn readSession(self: *Dal) !Session {
        return self.readSessionFor("");
    }

    /// 按表取只读会话（忽略表 / 全局切主库走主库）。
    ///
    /// 语义：**从库会话强制只读**（连接串没写 `Readonly=true` 也一样）；
    /// 回落到主库时返回**普通会话**（可写）——与 C# `DAL.Reads` “没有从库就降级主库” 一致。
    pub fn readSessionFor(self: *Dal, table_name: []const u8) !Session {
        const use_replica = self.replicas.items.len > 0 and
            (table_name.len == 0 or self.strategy.allowsReplica(table_name));
        if (!use_replica) return self.openSession();

        const idx = self.rr_index % self.replicas.items.len;
        self.rr_index = (self.rr_index + 1) % self.replicas.items.len;
        var s = try self.openSessionWith(&self.replicas.items[idx]);
        // 从库会话一律只读：连接串没写 `Readonly=true` 也不能往从库写
        s.read_only = true;
        return s;
    }

    /// 用指定连接参数打开会话（内部使用；对外请用 `openSession` / `readSessionFor`）。
    pub fn openSessionWith(self: *Dal, opts: *const ConnectionOptions) !Session {
        var s = try self.openDriverSession(opts);
        s.read_only = opts.read_only;
        s.show_sql = opts.show_sql;
        // 方言能力探测：整套 Dal **只探一次**（已探测时这里只是两个 atomic 读）
        self.probeVersionOnce(opts);
        return s;
    }

    /// 真正建连接并按方言分派（不做 read_only / show_sql / 版本探测等公共处理）。
    fn openDriverSession(self: *Dal, opts: *const ConnectionOptions) !Session {
        switch (opts.provider) {
            .sqlite => {
                const lib_ptr = if (self.lib) |*l| l else return error.Unsupported;
                // 并发相关 PRAGMA 随连接串走：多线程/多进程共用同一个库时，WAL 是读写不互斥的前提
                const db = try sqlite.Db.openWithOptions(lib_ptr, opts.data_source, .{
                    .journal_mode = opts.journal_mode,
                    .synchronous = opts.synchronous,
                    .cache_size = opts.cache_size,
                    .read_only = opts.read_only,
                });
                return Session.init(self.gpa, .sqlite, db);
            },
            .mysql, .nova => {
                const conn = try mysql.Conn.open(self.gpa, .{
                    .host = opts.server,
                    .port = opts.port,
                    .user = opts.user,
                    .password = opts.password,
                    .database = opts.database,
                    .ssl_mode = opts.ssl_mode,
                    .ssl_ca = opts.ssl_ca,
                    .compress = opts.compress,
                });
                return Session.initWithDriver(self.gpa, opts.provider, .{ .mysql = conn });
            },
            .postgresql, .kingbase, .highgo, .vastbase => {
                const conn = try postgres.Conn.open(self.gpa, .{
                    .host = opts.server,
                    .port = opts.port,
                    .user = opts.user,
                    .password = opts.password,
                    .database = opts.database,
                });
                return Session.initWithDriver(self.gpa, opts.provider, .{ .postgres = conn });
            },
            .sqlserver => {
                const conn = try tds.Conn.open(self.gpa, .{
                    .host = opts.server,
                    .port = opts.port,
                    .user = opts.user,
                    .password = opts.password,
                    .database = opts.database,
                    .pipe_name = opts.pipe_name,
                });
                return Session.initWithDriver(self.gpa, .sqlserver, .{ .sqlserver = conn });
            },
            .tdengine => {
                const conn = try tdengine.Conn.open(self.gpa, .{
                    .host = opts.server,
                    .port = opts.port,
                    .user = if (opts.user.len > 0) opts.user else "root",
                    .password = opts.password,
                    .database = opts.database,
                    .base_url = if (std.ascii.startsWithIgnoreCase(opts.server, "http")) opts.server else "",
                    .timeout_ms = opts.timeout_ms,
                });
                return Session.initWithDriver(self.gpa, .tdengine, .{ .tdengine = conn });
            },
            .influxdb => {
                const use_url = std.ascii.startsWithIgnoreCase(opts.server, "http");
                const conn = try influxdb.Conn.open(self.gpa, .{
                    .url = if (use_url) opts.server else "",
                    .host = if (use_url) "127.0.0.1" else opts.server,
                    .port = opts.port,
                    .tls = std.ascii.startsWithIgnoreCase(opts.server, "https"),
                    .token = if (opts.token.len > 0) opts.token else opts.password,
                    .org = opts.org,
                    .bucket = opts.bucket,
                    .database = opts.database,
                    .timeout_ms = opts.timeout_ms,
                });
                return Session.initWithDriver(self.gpa, .influxdb, .{ .influxdb = conn });
            },
            .clickhouse => {
                const use_url = std.ascii.startsWithIgnoreCase(opts.server, "http");
                const conn = try clickhouse.Conn.open(self.gpa, .{
                    .base_url = if (use_url) opts.server else "",
                    .host = if (use_url) "127.0.0.1" else opts.server,
                    .port = opts.port,
                    .tls = std.ascii.startsWithIgnoreCase(opts.server, "https"),
                    .user = if (opts.user.len > 0) opts.user else "default",
                    .password = opts.password,
                    .database = opts.database,
                    .timeout_ms = opts.timeout_ms,
                });
                return Session.initWithDriver(self.gpa, .clickhouse, .{ .clickhouse = conn });
            },
            .mongodb => {
                // 连接串可写 `mongodb://host:port/db`（Server 键直接给 URL）或分散键
                const conn = try mongodb.Conn.open(self.gpa, .{
                    .host = opts.server,
                    .port = opts.port,
                    .user = opts.user,
                    .password = opts.password,
                    .database = if (opts.database.len > 0) opts.database else "test",
                    .auth_source = opts.auth_source,
                });
                return Session.initWithDriver(self.gpa, .mongodb, .{ .mongodb = conn });
            },
            .duckdb => {
                const lib = if (self.duck_lib) |*l| l else return error.Unsupported;
                const db = try @import("zzig").duckdb.Db.open(self.gpa, lib, .{ .path = opts.data_source });
                return Session.initWithDriver(self.gpa, .duckdb, .{ .duckdb = db });
            },
            else => return error.Unsupported,
        }
    }

    // ── 连接池 ──────────────────────────────────────────────────

    /// 建一个绑定本 Dal 的连接池（连接参数与 `openSession` 一致）。
    ///
    /// 注意：`:memory:`（SQLite 内存库）**不要用池**——每个连接是独立数据库，
    /// 复用会让不同调用方看到不同的库。用 `supportsPooling()` 判断。
    pub fn makePool(self: *Dal, opts: pool.Options) pool.SessionPool {
        return pool.SessionPool.init(self.gpa, .{ .ctx = @ptrCast(self), .open = poolFactoryOpen }, opts);
    }

    fn poolFactoryOpen(ctx: *anyopaque) anyerror!Session {
        const self: *Dal = @ptrCast(@alignCast(ctx));
        return self.openSession();
    }

    /// 是否适合池化：SQLite 内存库不适合（每个连接一个独立库）。
    pub fn supportsPooling(self: *const Dal) bool {
        return switch (self.opts.provider) {
            .sqlite => !std.mem.eql(u8, self.opts.data_source, ":memory:"),
            .mysql, .postgresql, .sqlserver, .tdengine, .influxdb, .clickhouse, .mongodb, .nova, .kingbase, .highgo, .vastbase => true,
            else => false,
        };
    }

    // ── 分表 / 分库 ─────────────────────────────────────────────

    /// 注册分表策略（按模型表名；同名覆盖）。`policy` 里的字符串会**复制**一份。
    pub fn addShardPolicy(self: *Dal, table_name: []const u8, policy: shards.TimePolicy) !void {
        const owned = shards.TimePolicy{
            .gpa = self.gpa,
            .field = try self.gpa.dupe(u8, policy.field),
            .base_conn = try self.gpa.dupe(u8, policy.base_conn),
            .base_table = try self.gpa.dupe(u8, policy.base_table),
            .conn_policy = if (policy.conn_policy) |tpl| try self.gpa.dupe(u8, tpl) else null,
            .table_policy = if (policy.table_policy) |tpl| try self.gpa.dupe(u8, tpl) else null,
            .step_ms = policy.step_ms,
            .level = policy.level,
        };

        for (self.shard_routes.items) |*route| {
            if (std.ascii.eqlIgnoreCase(route.table_name, table_name)) {
                // 覆盖：先释放旧的
                self.gpa.free(route.table_name);
                self.gpa.free(route.policy.field);
                self.gpa.free(route.policy.base_conn);
                self.gpa.free(route.policy.base_table);
                if (route.policy.conn_policy) |tpl| self.gpa.free(tpl);
                if (route.policy.table_policy) |tpl| self.gpa.free(tpl);
                route.* = .{ .table_name = try self.gpa.dupe(u8, table_name), .policy = owned };
                return;
            }
        }
        try self.shard_routes.append(self.gpa, .{
            .table_name = try self.gpa.dupe(u8, table_name),
            .policy = owned,
        });
    }

    pub fn shardPolicyFor(self: *Dal, table_name: []const u8) ?*shards.TimePolicy {
        // 注册时可能用**实体名**（`Log`）也可能用**物理表名**（`DH_Log`），
        // 查找时两者都认（与 `EntityModel.table` 同口径），否则调用方传哪个都会有一半查不到。
        const meta = self.model.table(table_name);
        for (self.shard_routes.items) |*route| {
            if (std.ascii.eqlIgnoreCase(route.table_name, table_name)) return &route.policy;
            if (meta) |t| {
                if (std.ascii.eqlIgnoreCase(route.table_name, t.name)) return &route.policy;
                if (std.ascii.eqlIgnoreCase(route.table_name, t.effectiveTableName())) return &route.policy;
            }
        }
        return null;
    }

    /// 按字段值定位分片表句柄。返回的 `ShardModel` 由调用方释放。
    ///
    /// 跨库分片（`ConnPolicy` 指向别的连接）需先用 `attachConnection` 挂上该连接，
    /// 并用 `sessionForConn(model.conn_name)` 取会话；**没挂就报错**，不会静默写到主库。
    pub fn tableShard(self: *Dal, table_name: []const u8, value: @import("zzig").db.Value) !struct { table: TableRef, model: shards.ShardModel } {
        const sm = try self.shardOfTable(table_name, value);
        return .{ .table = try self.tableShardOn(table_name, sm), .model = sm };
    }

    /// 只算分片（不开会话、不建表）：返回的 `ShardModel` 由调用方释放。
    pub fn shardOfTable(self: *Dal, table_name: []const u8, value: @import("zzig").db.Value) !shards.ShardModel {
        const policy = self.shardPolicyFor(table_name) orelse return error.NoShardPolicy;
        return (try policy.shardOf(value)) orelse error.NoShardPolicy;
    }

    /// 按分片模型取表句柄（表名已替换；连接由调用方用 `sessionForConn` 选择）。
    pub fn tableShardOn(self: *Dal, base_table: []const u8, shard_model: shards.ShardModel) !TableRef {
        const is_main = std.ascii.eqlIgnoreCase(shard_model.conn_name, self.connName());
        if (!is_main and self.connectionIndex(shard_model.conn_name) == null) {
            std.debug.print(
                "[zcode] 分表：连接 {s} 未挂载（表 {s}）。跨库分片需先 attachConnection(名称, 连接串)\n",
                .{ shard_model.conn_name, shard_model.table_name },
            );
            return error.UnknownConnection;
        }
        const t = self.model.table(base_table) orelse return error.TableNotFound;
        var ref = TableRef.init(self.gpa, self.opts.provider, t);
        ref.table_name = shard_model.table_name;
        // 分库分片：表名已按分片替换，连接名也必须是**该分片所在库**，否则缓存作用域会串
        ref.conn_name = shard_model.conn_name;
        ref.features = self.featuresFor(self.opts.provider);
        ref.setWriteNotifier(@ptrCast(self), onTableWrite);
        ref.setInterceptorChain(self.chain);
        return ref;
    }

    /// 挂载一个命名连接（用于跨库分片 / 多库共存）。同名覆盖，幂等。
    pub fn attachConnection(self: *Dal, name: []const u8, conn_str: []const u8) !void {
        var opts = try parseConnectionString(self.gpa, conn_str);
        errdefer opts.deinit(self.gpa);

        if (opts.provider != self.opts.provider) {
            std.debug.print(
                "[zcode] 附加连接 {s} 的方言 {s} 与主库 {s} 不一致，拒绝挂载\n",
                .{ name, @tagName(opts.provider), @tagName(self.opts.provider) },
            );
            opts.deinit(self.gpa);
            return error.Unsupported;
        }

        for (self.connections.items) |*c| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) {
                c.opts.deinit(self.gpa);
                c.opts = opts;
                return;
            }
        }
        try self.connections.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name), .opts = opts });
    }

    pub fn connectionCount(self: *const Dal) usize {
        return self.connections.items.len;
    }

    fn connectionIndex(self: *const Dal, name: []const u8) ?usize {
        if (name.len == 0 or std.ascii.eqlIgnoreCase(name, self.connName())) return null;
        for (self.connections.items, 0..) |c, i| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) return i;
        }
        return null;
    }

    /// 取指定连接名对应的会话：主连接（名称为空或等于模型 `ConnName`）走 `openSession`，
    /// 其余必须已 `attachConnection`。
    pub fn sessionForConn(self: *Dal, name: []const u8) !Session {
        if (name.len == 0 or std.ascii.eqlIgnoreCase(name, self.connName())) return self.openSession();
        const idx = self.connectionIndex(name) orelse {
            std.debug.print("[zcode] 连接 {s} 未挂载，无法开会话\n", .{name});
            return error.UnknownConnection;
        };
        var s = try self.openSessionWith(&self.connections.items[idx].opts);
        s.conn_name = self.connections.items[idx].name;
        return s;
    }

    /// 分片表自动建表：表不存在时按基础表结构建表（含索引）。
    /// 返回 1 = 已新建，0 = 已存在。
    pub fn ensureShardTable(self: *Dal, base_table: []const u8, shard_model: shards.ShardModel) !usize {
        const base = self.model.table(base_table) orelse return error.TableNotFound;
        const exists = blk: {
            var s = try self.sessionForConn(shard_model.conn_name);
            defer s.deinit();
            break :blk try tableExists(&s, self.opts.provider, shard_model.table_name);
        };
        if (exists) return 0;

        var s = try self.sessionForConn(shard_model.conn_name);
        defer s.deinit();

        // 用基础表结构 + 分片表名建表（索引名会随表名变化，避免与基础表撞名）
        var meta = base.*;
        const owned_name = shard_model.table_name;
        meta.table_name = owned_name;
        const stmts = try self.opts.provider.createTableAlloc(self.gpa, &meta);
        defer {
            for (stmts) |stmt| self.gpa.free(stmt);
            self.gpa.free(stmts);
        }
        for (stmts) |stmt| {
            _ = s.execute(stmt, &.{}) catch |e| {
                std.debug.print(
                    "[zcode] 分片建表失败：{s}#{s}\n  SQL: {s}\n  错误: {s}\n",
                    .{ shard_model.conn_name, shard_model.table_name, stmt, s.lastError() },
                );
                return e;
            };
        }
        return 1;
    }

    /// 当前连接名（模型 `<Option><ConnName>`，缺省空串）。
    pub fn connName(self: *const Dal) []const u8 {
        return self.model.options.connName() orelse "";
    }

    /// 某张表**实际归属**的连接名：表级 `ConnName` 优先、模型级兜底。
    ///
    /// 两级都没配时返回主连接名（`connName()`，可能为空串）。
    /// 这是业务代码唯一可以问“这张表在哪个库”的入口——**不要在调用方另拼连接名**。
    pub fn tableConnName(self: *const Dal, table_name: []const u8) ![]const u8 {
        const t = self.model.table(table_name) orelse return error.TableNotFound;
        return self.model.tableConn(t) orelse self.connName();
    }

    /// 按表归属的连接开会话（`Log` 表在 `Log` 库、其余在 `Membership` 库这种场景）。
    ///
    /// 跨库表要求先用 `attachConnection` 挂上该连接；没挂会报 `error.UnknownConnection`，
    /// **不会**静默回到主库。
    pub fn openSessionForTable(self: *Dal, table_name: []const u8) !Session {
        const conn = try self.tableConnName(table_name);
        return self.sessionForConn(conn);
    }

    // ── 直接执行 SQL（对应 C# `DAL.Execute(sql)` 的直执行入口）──────────────
    //
    // 口径：**SQL 里一律用 `?` 写占位符**，本层按连接方言自动改写
    // （PG `$1`、SQL Server `@p0`、Oracle/达梦 `:1`，SQLite/MySQL 保持不变），
    // 字符串/标识符/注释里的 `?` 不会被误改。参数一律走绑定，不做字符串拼接。

    /// 直接执行一条 SQL（主连接），返回影响行数。
    pub fn exec(self: *Dal, sql: []const u8, params: []const @import("zzig").db.Value) !usize {
        var s = try self.openSession();
        defer s.deinit();
        const rewritten = try self.opts.provider.rewritePlaceholdersAlloc(self.gpa, sql);
        defer self.gpa.free(rewritten);
        return s.execute(rewritten, params);
    }

    /// 直接查询（主连接）。返回的行集指向会话内存，**本函数返回副本**，调用方用 `gpa` 释放。
    pub fn queryAlloc(self: *Dal, gpa: std.mem.Allocator, sql: []const u8, params: []const @import("zzig").db.Value) ![]@import("session.zig").Row {
        var s = try self.openSession();
        defer s.deinit();
        const rewritten = try self.opts.provider.rewritePlaceholdersAlloc(self.gpa, sql);
        defer self.gpa.free(rewritten);
        const rows = try s.queryRows(rewritten, params);
        // 行指向会话内存，必须**深拷贝**后再返回（只 dupe(Row) 会留悬垂字符串）
        return @import("session.zig").dupRowsAlloc(gpa, rows);
    }

    /// 按**表归属的连接**直接执行（分库时指向该表所在的库；对应 C# 里按 `Meta.Session` 走）。
    pub fn execOnTable(self: *Dal, table_name: []const u8, sql: []const u8, params: []const @import("zzig").db.Value) !usize {
        var s = try self.openSessionForTable(table_name);
        defer s.deinit();
        const rewritten = try self.opts.provider.rewritePlaceholdersAlloc(self.gpa, sql);
        defer self.gpa.free(rewritten);
        return s.execute(rewritten, params);
    }

    /// 按**表归属的连接**直接查询（返回副本，调用方释放）。
    pub fn queryOnTableAlloc(self: *Dal, gpa: std.mem.Allocator, table_name: []const u8, sql: []const u8, params: []const @import("zzig").db.Value) ![]@import("session.zig").Row {
        var s = try self.openSessionForTable(table_name);
        defer s.deinit();
        const rewritten = try self.opts.provider.rewritePlaceholdersAlloc(self.gpa, sql);
        defer self.gpa.free(rewritten);
        const rows = try s.queryRows(rewritten, params);
        return @import("session.zig").dupRowsAlloc(gpa, rows);
    }

    /// 在**已有会话**上直接执行 SQL（方言改写 + 绑定）。
    ///
    /// 事务内必须用这个：`exec` / `execOnTable` 会**新开会话**，那等于另一个连接/事务，
    /// 写进去的数据不会随调用方的事务回滚。
    pub fn execIn(self: *Dal, s: *Session, sql: []const u8, params: []const @import("zzig").db.Value) !usize {
        const rewritten = try self.opts.provider.rewritePlaceholdersAlloc(self.gpa, sql);
        defer self.gpa.free(rewritten);
        return s.execute(rewritten, params);
    }

    // ── 多表事务 ────────────────────────────────────────────────
    //
    // 口径：**一个事务只能落在一个连接上**。同库多表完全没问题（同一会话、同一事务），
    // 跨库多表**没有分布式事务**——这里选择「明确报错」而不是：
    //   - 静默拆成两个独立事务（一半成功一半失败，最难查）；
    //   - 假装"自动分库"（两阶段提交需要协调者，本库没有，也不该偷偷做）。

    /// 校验一组表是否同属一个连接；不同则打印可定位的诊断并返回 `error.CrossDatabaseTransaction`。
    ///
    /// 返回归属的连接名（表都没配 `ConnName` 时返回主连接名，可能是空串）。
    pub fn connectionOfTables(self: *Dal, table_names: []const []const u8) ![]const u8 {
        if (table_names.len == 0) return self.connName();

        var first: []const u8 = "";
        var first_table: []const u8 = "";
        for (table_names, 0..) |tn, i| {
            const conn = try self.tableConnName(tn);
            if (i == 0) {
                first = conn;
                first_table = tn;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(conn, first)) continue;
            std.debug.print(
                "[zcode] 跨库事务被拒绝：表 {s} 归属连接 {s}，表 {s} 归属连接 {s}。\n" ++
                    "  一个事务只能在一个连接上执行；跨库写入需要业务补偿（Outbox / 两阶段），本库不做隐式拆分。\n",
                .{ first_table, first, tn, conn },
            );
            return error.CrossDatabaseTransaction;
        }
        return first;
    }

    /// 为「一组表」在**已有会话**上开启事务（同库多表）。
    ///
    /// - 表分属不同连接 → `error.CrossDatabaseTransaction`（附诊断，不静默拆库）；
    /// - 调用方必须保证 `s` 就是该连接的会话（先用 `sessionForConn(conn)` 开）。
    ///
    /// 用法：
    /// ```zig
    /// var s = try dal.beginForTables("User", "Role");  // 见下方便捷函数
    /// ```
    /// 注意：**不要**把 `Session` 按值返回给调用方——它内含 arena，复制会导致
    /// 两个副本共享同一份缓冲链，`deinit` 时崩溃。所以这里只接受 `*Session`。
    pub fn beginTransactionForTables(self: *Dal, s: *Session, table_names: []const []const u8) !void {
        _ = try self.connectionOfTables(table_names);
        _ = try s.beginTransaction(.default);
    }

    // ── 写入拦截器 ──────────────────────────────────────────────

    /// 挂上写入拦截器链（不接管所有权）。此后 `table()` 取到的表句柄都会应用它。
    pub fn setInterceptorChain(self: *Dal, chain: ?*interceptor.Chain) void {
        self.chain = chain;
    }

    // ── 服务端版本与方言能力 ────────────────────────────────────
    //
    // 目的只有一个：**让新语法默认被用起来，同时不把老库写炸**。
    // MySQL 8.0.19+ 的行别名、PG 的 `RETURNING` 都属此类（详见 `dialect.Features`）。
    //
    // 探测纪律：
    // - **每条 Dal 只探一次**（`probe_code` 是 atomic，探过就不再发 SQL）；
    // - 探测失败（无权限 / 中间件挡住 `SELECT VERSION()`）→ 记 `probe_failed` 走保守档，
    //   **不影响连接可用性**，只告警一次；
    // - SQL Server 不探：`@@VERSION` 返回的是 "Microsoft SQL Server 2022 (RTM) - 16.0..."，
    //   首个数字是发布年份，解析会错；它也不用这两个能力，保守档即可。

    /// 探测服务端版本（幂等；已探测过直接返回）。
    ///
    /// **用独立临时会话探测，绝不碰即将返回给调用方的那个会话**：
    /// `Session` 的 SQLite 语句缓存里，`Stmt` 持有 `*Db` 指针，而 `Session` 是**按值返回**
    /// 的（返回时地址会变）。若在 `openSessionWith` 里用主会话 prepare 一次再 `return s`，
    /// 缓存里的 `Stmt` 就指向失效地址，`deinit` 时 `finalize` 段错误（2026-11-13 实测踩到）。
    ///
    /// 代价：**整套 Dal 只多开一次连接**（不是每次开会话），SQLite 是本地微秒级，
    /// MySQL/PG 多一次握手——只在第一次发生，换来「新语法自动生效 + 老库自动降级」。
    fn probeVersionOnce(self: *Dal, opts: *const ConnectionOptions) void {
        if (self.probe_code.load(.acquire) != probe_unset) return;

        const sql = switch (opts.provider) {
            .sqlite => "SELECT sqlite_version()",
            .mysql => "SELECT VERSION()",
            .nova => "SELECT VERSION()",
            .postgresql, .kingbase, .highgo, .vastbase => "SHOW server_version",
            // TDengine 有服务器版本函数；ClickHouse 有 `version()`；InfluxDB 没有 SQL（本类不探）
            .tdengine => "SELECT SERVER_VERSION()",
            .clickhouse => "SELECT version()",
            .duckdb => "SELECT version()",
            else => {
                // SQL Server 的 `@@VERSION` 形如 `Microsoft SQL Server 2022 (RTM) - 16.0.1000.6`，
                // 首个数字是发布年份，解析必错；它也不用这两个能力，直接保守档。
                self.probe_code.store(probe_failed, .release);
                return;
            },
        };

        var tmp = self.openDriverSession(opts) catch |e| {
            self.probe_code.store(probe_failed, .release);
            std.debug.print(
                "[zcode] 服务端版本探测失败（{s} 建临时会话）：{s}\n" ++
                    "  后续按保守档生成 SQL（不用 MySQL 行别名 / PG RETURNING），功能正常但少数优化不生效。\n",
                .{ opts.provider.name(), @errorName(e) },
            );
            return;
        };
        defer tmp.deinit();

        const value = tmp.queryScalar(sql, &.{}) catch |e| {
            self.probe_code.store(probe_failed, .release);
            std.debug.print(
                "[zcode] 服务端版本探测失败（{s}）：{s}；{s}\n" ++
                    "  后续按保守档生成 SQL（不用 MySQL 行别名 / PG RETURNING），功能正常但少数优化不生效。\n",
                .{ sql, @errorName(e), tmp.lastError() },
            );
            return;
        };
        const raw = if (value) |v| v.asText() else null;
        const text = raw orelse {
            self.probe_code.store(probe_failed, .release);
            std.debug.print("[zcode] 服务端版本探测失败（{s}）返回空值，按保守档处理\n", .{sql});
            return;
        };
        const parsed = dialect.ServerVersion.parse(text) orelse {
            self.probe_code.store(probe_failed, .release);
            std.debug.print(
                "[zcode] 服务端版本串无法解析：{s}（来自 {s}），按保守档处理\n",
                .{ text, sql },
            );
            return;
        };
        // 版本串多半只有数字（`8.0.29` / `3.54.1` / `16.2 (Debian ...)`），产品分支要靠**连接串声明的
        // provider** 补齐；但串里已经写明 `MariaDB` / `Percona` 时以串为准（那决定了行别名能不能用）。
        var resolved = parsed;
        if (resolved.flavor == .unknown) {
            resolved.flavor = switch (opts.provider) {
                .sqlite => .sqlite,
                .mysql, .nova => .mysql,
                .postgresql, .kingbase, .highgo, .vastbase => .postgresql,
                .tdengine => .tdengine,
                else => .unknown,
            };
        }
        self.probe_code.store(packServerVersion(resolved), .release);
    }

    /// 已探测到的服务端版本（未探测或探测失败返回 `null`）。
    pub fn serverVersion(self: *const Dal) ?dialect.ServerVersion {
        return unpackServerVersion(self.probe_code.load(.acquire));
    }

    /// 当前主连接生效的方言能力（探测失败 → 保守档 + 一次性告警）。
    pub fn features(self: *Dal) dialect.Features {
        return self.featuresFor(self.opts.provider);
    }

    /// 指定方言的生效能力。**只有探测到的版本与请求的方言同源时才采信**：
    /// 否则（还没连过库 / 探测失败）一律保守档。
    pub fn featuresFor(self: *Dal, kind: DatabaseKind) dialect.Features {
        if (kind != self.opts.provider) return dialect.Features.unknownVersion(kind);
        const code = self.probe_code.load(.acquire);
        if (unpackServerVersion(code)) |v| return dialect.Features.forVersion(kind, v);
        if (code == probe_failed and !self.probe_warned.swap(true, .acquire)) {
            std.debug.print(
                "[zcode] {s}：服务端版本未知，方言能力按保守档（{s}）\n",
                .{ kind.name(), (dialect.Features.conservative.describeAlloc(self.gpa) catch "行别名=关 / RETURNING=关") },
            );
        }
        return dialect.Features.unknownVersion(kind);
    }

    /// 一行诊断：`MySQL 8.0.29 MySQL（行别名=开 / RETURNING=关）`。
    /// 运维第一眼要看的就是「到底连的哪个版本、开了哪些能力」。
    pub fn describeServerAlloc(self: *Dal) ![]u8 {
        const f = self.features();
        const feats = try f.describeAlloc(self.gpa);
        defer self.gpa.free(feats);
        if (self.serverVersion()) |v| {
            const ver = try v.describeAlloc(self.gpa);
            defer self.gpa.free(ver);
            return std.fmt.allocPrint(self.gpa, "{s}（{s}）", .{ ver, feats });
        }
        return std.fmt.allocPrint(self.gpa, "版本未知（{s}）", .{feats});
    }

    fn freeOptions(gpa: std.mem.Allocator, opts: *ConnectionOptions) void {
        opts.deinit(gpa);
    }

    /// 打开一个写会话；`Readonly=true` 时打开只读会话（写入在调用点报错）。
    ///
    /// 会话会带上 SQL 日志配置：连接名（日志前缀）+ 连接串 `ShowSQL`（`null` 则跟随全局设置）。
    pub fn openSession(self: *Dal) !Session {
        var s = try self.openSessionRaw();
        s.show_sql = self.opts.show_sql;
        s.conn_name = self.connName();
        return s;
    }

    fn openSessionRaw(self: *Dal) !Session {
        // **不要**另写一套打开逻辑：`openSessionRaw` 早先直接调 `sqlite.Db.open`（不带 PRAGMA），
        // 导致连接串里的 `JournalMode` / `Synchronous` / `CacheSize` 只在从库 / 命名连接上生效，
        // 主连接反而被忽略。统一收敛到 `openSessionWith`（全 null 时与 `Db.open` 完全等价）。
        return self.openSessionWith(&self.opts);
    }

    /// 取表句柄（按实体名或物理表名）。
    pub fn table(self: *Dal, name: []const u8) !TableRef {
        const t = self.model.table(name) orelse return error.TableNotFound;
        var ref = TableRef.init(self.gpa, self.opts.provider, t);
        ref.conn_name = self.tableConnName(t.name) catch self.connName();
        ref.features = self.featuresFor(self.opts.provider);
        ref.setWriteNotifier(@ptrCast(self), onTableWrite);
        ref.setInterceptorChain(self.chain);
        return ref;
    }

    fn onTableWrite(ctx: *anyopaque, table_name: []const u8, conn_name: []const u8, key: ?i64) void {
        const self: *Dal = @ptrCast(@alignCast(ctx));
        self.invalidateCachesOn(table_name, conn_name, key);
    }

    /// 实际生效的迁移档位（连接串优先，其次模型 `<Option><Migration>`，缺省 `On`）。
    pub fn effectiveMigration(self: *const Dal) Migration {
        if (self.opts.migration) |m| return m;
        if (self.model.options.migration()) |m| return m;
        return .on;
    }

    /// 结构同步（增量、非破坏）。SQLite 实现：
    /// 1. 表不存在 → 建表（含索引）
    /// 2. 表存在 → `PRAGMA table_info` 对比，缺列则 `ALTER TABLE ... ADD COLUMN`
    /// 3. 索引不存在 → `CREATE INDEX`
    pub fn syncSchema(self: *Dal, s_main: *Session) !SchemaReport {
        var report = SchemaReport{};

        // 跨库表的会话由本函数按 Model.xml 的连接规则自行打开并关闭（不借用调用方的会话）。
        var owned: ?Session = null;
        defer if (owned) |*o| o.deinit();

        const global = self.effectiveMigration();
        if (global == .off) {
            report.tables_skipped = self.model.tables.len;
            report.executed = false;
            return report;
        }
        report.executed = global.canExecute();

        for (self.model.tables) |*t| {
            // ── 连接路由：**表级 `ConnName` 优先、模型级兜底**（唯一规则在 `EntityModel.tableConn`）——
            // 不在这里重新拼连接名，也不允许“没挂连接就建到主库”这种静默降级。
            const conn = self.model.tableConn(t);
            const on_main = conn == null or std.ascii.eqlIgnoreCase(conn.?, self.connName());

            if (owned) |*o| {
                o.deinit();
                owned = null;
            }
            var cur: *Session = s_main;
            if (!on_main) {
                const cs = self.sessionForConn(conn.?) catch |e| {
                    std.debug.print(
                        "[sync_schema] 表 {s} 归属连接 {s}，但该连接未挂载（拒绝静默建到主库）。\n" ++
                            "  请先用 attachConnection(\"{s}\", 连接串) 挂上，或确认 Model.xml 的表级 ConnName 是否正确。\n",
                        .{ t.name, conn.?, conn.? },
                    );
                    return e;
                };
                owned = cs;
                cur = &owned.?;
            }
            // 循环体内沿用原变量名：后续所有 DDL 都作用在“本表自己的连接”上
            const s = cur;

            // 表级档位只能更保守（C# `ResolveMigration` 的 min 语义）
            const migration = global.tighten(t.migration);
            if (migration == .off) {
                report.tables_skipped += 1;
                continue;
            }
            if (t.is_view) {
                report.tables_skipped += 1;
                continue;
            }
            const execute_ddl = migration.canExecute();
            const exists = try tableExists(s, self.opts.provider, t.effectiveTableName());
            if (!exists) {
                const stmts = try self.opts.provider.createTableAlloc(self.gpa, t);
                defer {
                    for (stmts) |stmt| self.gpa.free(stmt);
                    self.gpa.free(stmts);
                }
                if (execute_ddl) {
                    for (stmts) |stmt| {
                        _ = s.execute(stmt, &.{}) catch |e| {
                            std.debug.print("[sync_schema] 建表失败：{s}\n  SQL: {s}\n  错误: {s}\n", .{ t.name, stmt, s.lastError() });
                            return e;
                        };
                    }
                }
                report.tables_created += 1;
                // 建表语句里已含索引，口径与「表已存在」分支保持一致
                for (t.indexes) |idx| {
                    if (try self.opts.provider.createIndexAlloc(self.gpa, t, idx)) |idx_sql| {
                        self.gpa.free(idx_sql);
                        report.indexes_created += 1;
                    }
                }
                continue;
            }

            // 已存在：补列
            const existing = try existingColumns(s, self.gpa, self.opts.provider, t.effectiveTableName());
            defer freeColumnNames(self.gpa, existing);

            for (t.columns) |col| {
                if (containsIgnoreCase(existing, t.effectiveColumnName(@constCast(&col)))) continue;
                const sql = try self.opts.provider.addColumnAlloc(self.gpa, t, col);
                defer self.gpa.free(sql);
                if (execute_ddl) {
                    _ = s.execute(sql, &.{}) catch |e| {
                        std.debug.print("[sync_schema] 补列失败：{s}.{s}\n  SQL: {s}\n  错误: {s}\n", .{ t.name, col.name, sql, s.lastError() });
                        return e;
                    };
                }
                report.columns_added += 1;
            }

            // 索引：按名字幂等比对
            for (t.indexes) |idx| {
                const idx_sql_opt = try self.opts.provider.createIndexAlloc(self.gpa, t, idx);
                if (idx_sql_opt == null) continue;
                const idx_sql = idx_sql_opt.?;
                defer self.gpa.free(idx_sql);

                const idx_name = try self.opts.provider.indexNameAlloc(self.gpa, t, idx);
                defer self.gpa.free(idx_name);
                if (try indexExists(s, self.opts.provider, idx_name)) continue;

                if (execute_ddl) {
                    _ = s.execute(idx_sql, &.{}) catch |e| {
                        std.debug.print("[sync_schema] 建索引失败：{s}.{s}\n  SQL: {s}\n  错误: {s}\n", .{ t.name, idx_name, idx_sql, s.lastError() });
                        return e;
                    };
                }
                report.indexes_created += 1;
            }

            // Full：删除模型里已不存在的列与索引（**只有 Full 档允许删除**）
            // 顺序：**先删索引再删列**——否则引用该列的索引会让 DROP COLUMN 报
            //「error in index ... after drop column: no such column」
            if (!migration.onlyCreate()) {
                try self.alterChangedColumns(s, t, execute_ddl, &report);
                try self.dropExtraIndexes(s, t, execute_ddl, &report);
                try self.dropExtraColumns(s, t, existing, execute_ddl, &report);
            }
        }
        return report;
    }

    /// 删除「库里有、模型里没有」的列（`Migration=Full`）。
    fn dropExtraColumns(
        self: *Dal,
        s: *Session,
        t: *const model.TableMeta,
        existing: []const []const u8,
        execute_ddl: bool,
        report: *SchemaReport,
    ) !void {
        const quoted_table = try self.opts.provider.quoteAlloc(self.gpa, t.effectiveTableName());
        defer self.gpa.free(quoted_table);

        for (existing) |col_name| {
            if (modelHasColumn(t, col_name)) continue;

            const quoted_col = try self.opts.provider.quoteAlloc(self.gpa, col_name);
            defer self.gpa.free(quoted_col);
            const sql = try std.fmt.allocPrint(self.gpa, "ALTER TABLE {s} DROP COLUMN {s}", .{ quoted_table, quoted_col });
            defer self.gpa.free(sql);

            if (execute_ddl) {
                _ = s.execute(sql, &.{}) catch |e| {
                    std.debug.print(
                        "[sync_schema] 删列失败：{s}.{s}\n  SQL: {s}\n  错误: {s}\n  （SQLite 需 3.35+，且不能删主键/被索引列）\n",
                        .{ t.name, col_name, sql, s.lastError() },
                    );
                    return e;
                };
            }
            report.columns_dropped += 1;
        }
    }

    /// 删除「库里有、模型里没有」的索引（`Migration=Full`）。
    fn dropExtraIndexes(
        self: *Dal,
        s: *Session,
        t: *const model.TableMeta,
        execute_ddl: bool,
        report: *SchemaReport,
    ) !void {
        const existing = try existingIndexes(s, self.gpa, self.opts.provider, t.effectiveTableName());
        defer freeColumnNames(self.gpa, existing);

        for (existing) |idx_name| {
            // SQLite 的隐式索引（sqlite_autoindex_*）不能删
            if (std.ascii.startsWithIgnoreCase(idx_name, "sqlite_autoindex")) continue;
            if (try self.modelHasIndex(t, idx_name)) continue;

            const sql = switch (self.opts.provider) {
                .sqlite => blk: {
                    const quoted = try self.opts.provider.quoteAlloc(self.gpa, idx_name);
                    defer self.gpa.free(quoted);
                    break :blk try std.fmt.allocPrint(self.gpa, "DROP INDEX {s}", .{quoted});
                },
                .mysql => blk: {
                    const quoted_table = try self.opts.provider.quoteAlloc(self.gpa, t.effectiveTableName());
                    defer self.gpa.free(quoted_table);
                    const quoted_idx = try self.opts.provider.quoteAlloc(self.gpa, idx_name);
                    defer self.gpa.free(quoted_idx);
                    break :blk try std.fmt.allocPrint(self.gpa, "ALTER TABLE {s} DROP INDEX {s}", .{ quoted_table, quoted_idx });
                },
                .sqlserver => blk: {
                    const quoted_table = try self.opts.provider.quoteAlloc(self.gpa, t.effectiveTableName());
                    defer self.gpa.free(quoted_table);
                    const quoted_idx = try self.opts.provider.quoteAlloc(self.gpa, idx_name);
                    defer self.gpa.free(quoted_idx);
                    break :blk try std.fmt.allocPrint(self.gpa, "DROP INDEX {s} ON {s}", .{ quoted_idx, quoted_table });
                },
                else => return error.Unsupported,
            };
            defer self.gpa.free(sql);

            if (execute_ddl) {
                _ = s.execute(sql, &.{}) catch |e| {
                    std.debug.print("[sync_schema] 删索引失败：{s}.{s}\n  SQL: {s}\n  错误: {s}\n", .{ t.name, idx_name, sql, s.lastError() });
                    return e;
                };
            }
            report.indexes_dropped += 1;
        }
    }

    /// `Migration=Full` 档：把库里类型/长度与模型不一致的列改过来。
    ///
    /// - MySQL / SQL Server / Oracle / PostgreSQL 系：`ALTER TABLE ... MODIFY/ALTER COLUMN`
    /// - SQLite：没有 `ALTER COLUMN`，只能**整表重建**（见 `rebuildSqliteTable`）
    /// - **可空性不自动改**（存量 NULL 会让约束失败），只打日志提醒
    fn alterChangedColumns(self: *Dal, s: *Session, t: *const model.TableMeta, execute_ddl: bool, report: *SchemaReport) !void {
        const infos = existingColumnInfos(s, self.gpa, self.opts.provider, t.effectiveTableName()) catch |e| {
            std.debug.print(
                "[sync_schema] 读取 {s} 的现有列类型失败（{s}），本轮跳过改列比对\n",
                .{ t.name, @errorName(e) },
            );
            return;
        };
        defer freeExistingColumns(self.gpa, infos);

        var sqlite_needs_rebuild = false;
        var changed: usize = 0;

        for (t.columns) |col| {
            const col_name = t.effectiveColumnName(@constCast(&col));
            const db_col = findExistingColumn(infos, col_name) orelse continue;
            // 自增列的类型由数据库自己维护（如 SQLite 的 integer PRIMARY KEY），不强改
            if (col.identity) continue;

            const model_type = try self.opts.provider.fieldTypeAlloc(self.gpa, col);
            defer self.gpa.free(model_type);
            if (typesEquivalent(model_type, db_col.type_text)) {
                if (!col.nullable and db_col.nullable) {
                    std.debug.print(
                        "[sync_schema] 注意：{s}.{s} 模型要求 NOT NULL，库里可空（驱动 {s}，现有类型 {s}）；" ++
                            "可空性不自动改（存量 NULL 会让约束失败）\n",
                        .{ t.name, col_name, @tagName(self.opts.provider), db_col.type_text },
                    );
                }
                continue;
            }

            if (self.opts.provider == .sqlite) {
                sqlite_needs_rebuild = true;
                changed += 1;
                continue;
            }

            const alter_sql = (try self.opts.provider.alterColumnAlloc(self.gpa, t, col)) orelse continue;
            defer self.gpa.free(alter_sql);
            if (execute_ddl) {
                _ = s.execute(alter_sql, &.{}) catch |e| {
                    std.debug.print("[sync_schema] 改列失败：{s}.{s}\n  SQL: {s}\n  错误: {s}\n", .{ t.name, col_name, alter_sql, s.lastError() });
                    return e;
                };
            }
            changed += 1;
        }

        if (sqlite_needs_rebuild) {
            if (execute_ddl) {
                try self.rebuildSqliteTable(s, t);
            } else {
                std.debug.print(
                    "[sync_schema] 只读档：{s} 有 {d} 列需要改类型（SQLite 需整表重建），未执行\n",
                    .{ t.name, changed },
                );
            }
        }
        report.columns_altered += changed;
    }

    /// SQLite 改列 = 整表重建（SQLite 没有 `ALTER COLUMN`）。
    ///
    /// 在事务内：`ALTER TABLE t RENAME TO t_zcode_old` → 按模型 `CREATE TABLE t`（含索引）
    /// → `INSERT INTO t (共同列) SELECT (共同列) FROM t_zcode_old` → `DROP TABLE t_zcode_old`。
    ///
    /// 约定：只复制**两边都有的列**（Full 档允许丢列）；自增主键值原样搬过去。
    /// **仅在 `Migration=Full` 时才会走到这里**——库里若有视图/触发器引用该表，
    /// SQLite 重命名会把它们改指向临时表，重建后需要人工复查。
    fn rebuildSqliteTable(self: *Dal, s: *Session, t: *const model.TableMeta) !void {
        const table_name = t.effectiveTableName();
        const quoted_table = try self.opts.provider.quoteAlloc(self.gpa, table_name);
        defer self.gpa.free(quoted_table);

        const old_name = try std.fmt.allocPrint(self.gpa, "{s}_zcode_old", .{table_name});
        defer self.gpa.free(old_name);
        const quoted_old = try self.opts.provider.quoteAlloc(self.gpa, old_name);
        defer self.gpa.free(quoted_old);

        std.debug.print("[sync_schema] SQLite 改列：整表重建 {s}（临时表 {s}）\n", .{ table_name, old_name });

        // 上一次重建残留的临时表先清掉，否则 RENAME 会撞名
        if (try tableExists(s, .sqlite, old_name)) {
            const drop_leftover = try std.fmt.allocPrint(self.gpa, "DROP TABLE {s}", .{quoted_old});
            defer self.gpa.free(drop_leftover);
            std.debug.print("[sync_schema] 发现遗留临时表 {s}，先删除\n", .{old_name});
            _ = try s.execute(drop_leftover, &.{});
        }

        const infos = try existingColumnInfos(s, self.gpa, .sqlite, table_name);
        defer freeExistingColumns(self.gpa, infos);

        // 共同列（按模型列顺序拼，两边都有的才复制）
        var cols: std.ArrayList(u8) = .empty;
        defer cols.deinit(self.gpa);
        for (t.columns) |col| {
            const col_name = t.effectiveColumnName(@constCast(&col));
            if (findExistingColumn(infos, col_name) == null) continue;
            const quoted_col = try self.opts.provider.quoteAlloc(self.gpa, col_name);
            defer self.gpa.free(quoted_col);
            if (cols.items.len > 0) try cols.appendSlice(self.gpa, ", ");
            try cols.appendSlice(self.gpa, quoted_col);
        }

        const began = !s.inTransaction();
        if (began) _ = try s.beginTransaction(.default);
        errdefer if (began) {
            _ = s.rollback(true) catch 0;
        };

        const rename_sql = try std.fmt.allocPrint(self.gpa, "ALTER TABLE {s} RENAME TO {s}", .{ quoted_table, quoted_old });
        defer self.gpa.free(rename_sql);
        _ = s.execute(rename_sql, &.{}) catch |e| {
            std.debug.print("[sync_schema] 重建重命名失败：{s}\n  SQL: {s}\n  错误: {s}\n", .{ t.name, rename_sql, s.lastError() });
            return e;
        };

        const stmts = try self.opts.provider.createTableAlloc(self.gpa, t);
        defer {
            for (stmts) |stmt| self.gpa.free(stmt);
            self.gpa.free(stmts);
        }

        // 顺序很关键：**先只建表**，把数据搬过去、删掉旧表（索引随旧表一起消失），再建索引。
        // SQLite 的索引名是「库内全局唯一」的：旧表还在时建同名索引会
        // 直接报 `index ix_xxx already exists`（本轮实测）。
        _ = s.execute(stmts[0], &.{}) catch |e| {
            std.debug.print("[sync_schema] 重建建表失败：{s}\n  SQL: {s}\n  错误: {s}\n", .{ t.name, stmts[0], s.lastError() });
            return e;
        };

        if (cols.items.len > 0) {
            const copy_sql = try std.fmt.allocPrint(
                self.gpa,
                "INSERT INTO {s} ({s}) SELECT {s} FROM {s}",
                .{ quoted_table, cols.items, cols.items, quoted_old },
            );
            defer self.gpa.free(copy_sql);
            _ = s.execute(copy_sql, &.{}) catch |e| {
                std.debug.print("[sync_schema] 重建复制数据失败：{s}\n  SQL: {s}\n  错误: {s}\n", .{ t.name, copy_sql, s.lastError() });
                return e;
            };
        }

        const drop_sql = try std.fmt.allocPrint(self.gpa, "DROP TABLE {s}", .{quoted_old});
        defer self.gpa.free(drop_sql);
        _ = try s.execute(drop_sql, &.{});

        // 旧表已删（连同它的索引），现在才能建同名索引
        for (stmts[1..]) |stmt| {
            _ = s.execute(stmt, &.{}) catch |e| {
                std.debug.print("[sync_schema] 重建建索引失败：{s}\n  SQL: {s}\n  错误: {s}\n", .{ t.name, stmt, s.lastError() });
                return e;
            };
        }

        if (began) _ = try s.commit();
    }

    /// 该表在模型里是否声明了同名索引（按生成后的索引名比对）。
    fn modelHasIndex(self: *Dal, t: *const model.TableMeta, idx_name: []const u8) !bool {
        for (t.indexes) |idx| {
            const name = try self.opts.provider.indexNameAlloc(self.gpa, t, idx);
            defer self.gpa.free(name);
            if (std.ascii.eqlIgnoreCase(name, idx_name)) return true;
        }
        return false;
    }
};

/// 模型里是否存在该列（按物理列名忽略大小写）。
fn modelHasColumn(t: *const model.TableMeta, name: []const u8) bool {
    for (t.columns) |*c| {
        if (std.ascii.eqlIgnoreCase(t.effectiveColumnName(c), name)) return true;
    }
    return false;
}

/// 读取现有索引名（SQLite：`PRAGMA index_list`；MySQL：`information_schema.statistics`）。
fn existingIndexes(s: *Session, gpa: std.mem.Allocator, kind: DatabaseKind, table_name: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);

    switch (kind) {
        .sqlite => {
            const quoted = try DatabaseKind.sqlite.quoteAlloc(gpa, table_name);
            defer gpa.free(quoted);
            const sql = try std.fmt.allocPrint(gpa, "PRAGMA index_list({s})", .{quoted});
            defer gpa.free(sql);

            const rows = try s.queryRows(sql, &.{});
            for (rows) |row| {
                if (row.get("name")) |v| {
                    if (v.asText()) |text| try list.append(gpa, try gpa.dupe(u8, text));
                }
            }
        },
        .mysql => {
            const rows = try s.queryRows(
                "SELECT DISTINCT index_name FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ?",
                &.{.{ .text = table_name }},
            );
            for (rows) |row| {
                if (row.values.len == 0) continue;
                if (row.values[0].asText()) |text| {
                    if (std.ascii.eqlIgnoreCase(text, "PRIMARY")) continue;
                    try list.append(gpa, try gpa.dupe(u8, text));
                }
            }
        },
        .sqlserver => {
            // `sys.indexes` 只看用户索引（`is_primary_key = 0` / `is_unique_constraint = 0`）
            const rows = try s.queryRows(
                "SELECT i.name FROM sys.indexes i WHERE i.object_id = OBJECT_ID(@p0) AND i.name IS NOT NULL " ++
                    "AND i.is_primary_key = 0 AND i.is_unique_constraint = 0",
                &.{.{ .text = table_name }},
            );
            for (rows) |row| {
                if (row.values.len == 0) continue;
                if (row.values[0].asText()) |text| try list.append(gpa, try gpa.dupe(u8, text));
            }
        },
        .postgresql, .kingbase, .highgo, .vastbase => {
            const rows = try s.queryRows(
                "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND tablename = $1",
                &.{.{ .text = table_name }},
            );
            for (rows) |row| {
                if (row.values.len == 0) continue;
                if (row.values[0].asText()) |text| try list.append(gpa, try gpa.dupe(u8, text));
            }
        },
        else => return error.Unsupported,
    }
    return list.toOwnedSlice(gpa);
}

fn tableExists(s: *Session, kind: DatabaseKind, name: []const u8) !bool {
    const rows = switch (kind) {
        .sqlite => try s.queryRows(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            &.{.{ .text = name }},
        ),
        .mysql => try s.queryRows(
            "SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ? LIMIT 1",
            &.{.{ .text = name }},
        ),
        .sqlserver => try s.queryRows(
            "SELECT TOP 1 1 FROM information_schema.tables WHERE table_name = @p0",
            &.{.{ .text = name }},
        ),
        .postgresql, .kingbase, .highgo, .vastbase => try s.queryRows(
            "SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1 LIMIT 1",
            &.{.{ .text = name }},
        ),
        else => return error.Unsupported,
    };
    return rows.len > 0;
}

fn indexExists(s: *Session, kind: DatabaseKind, name: []const u8) !bool {
    const rows = switch (kind) {
        .sqlite => try s.queryRows(
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ? LIMIT 1",
            &.{.{ .text = name }},
        ),
        .mysql => try s.queryRows(
            "SELECT 1 FROM information_schema.statistics WHERE table_schema = DATABASE() AND index_name = ? LIMIT 1",
            &.{.{ .text = name }},
        ),
        .sqlserver => try s.queryRows(
            "SELECT TOP 1 1 FROM sys.indexes WHERE name = @p0",
            &.{.{ .text = name }},
        ),
        .postgresql, .kingbase, .highgo, .vastbase => try s.queryRows(
            "SELECT 1 FROM pg_indexes WHERE schemaname = current_schema() AND indexname = $1 LIMIT 1",
            &.{.{ .text = name }},
        ),
        else => return error.Unsupported,
    };
    return rows.len > 0;
}

/// 读取现有列名（SQLite：`PRAGMA table_info` 第 2 列；MySQL：`information_schema.columns` 第 1 列）。
fn existingColumns(s: *Session, gpa: std.mem.Allocator, kind: DatabaseKind, table_name: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);

    switch (kind) {
        .sqlite => {
            const quoted = try @import("dialect.zig").DatabaseKind.sqlite.quoteAlloc(gpa, table_name);
            defer gpa.free(quoted);
            const sql = try std.fmt.allocPrint(gpa, "PRAGMA table_info({s})", .{quoted});
            defer gpa.free(sql);

            const rows = try s.queryRows(sql, &.{});
            for (rows) |row| {
                if (row.get("name")) |v| {
                    if (v.asText()) |text| try list.append(gpa, try gpa.dupe(u8, text));
                }
            }
        },
        .mysql => {
            // 注意：MySQL 8 的 information_schema 列名返回大写，因此按列序号取，不依赖列名
            const rows = try s.queryRows(
                "SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ?",
                &.{.{ .text = table_name }},
            );
            for (rows) |row| {
                if (row.values.len == 0) continue;
                if (row.values[0].asText()) |text| try list.append(gpa, try gpa.dupe(u8, text));
            }
        },
        .sqlserver => {
            const rows = try s.queryRows(
                "SELECT column_name FROM information_schema.columns WHERE table_name = @p0",
                &.{.{ .text = table_name }},
            );
            for (rows) |row| {
                if (row.values.len == 0) continue;
                if (row.values[0].asText()) |text| try list.append(gpa, try gpa.dupe(u8, text));
            }
        },
        // PG 系：与 `tableExists` 同一口径（限当前 schema，避免同名表跨 schema 串味）
        .postgresql, .kingbase, .highgo, .vastbase => {
            const rows = try s.queryRows(
                "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1",
                &.{.{ .text = table_name }},
            );
            for (rows) |row| {
                if (row.values.len == 0) continue;
                if (row.values[0].asText()) |text| try list.append(gpa, try gpa.dupe(u8, text));
            }
        },
        else => return error.Unsupported,
    }
    return list.toOwnedSlice(gpa);
}

fn freeColumnNames(gpa: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

fn containsIgnoreCase(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.ascii.eqlIgnoreCase(h, needle)) return true;
    }
    return false;
}

// ── 改列比对：现有列类型探测 ────────────────────────────────────────────────

/// 现有列的类型信息（`Migration=Full` 的改列比对用）。
const ExistingColumn = struct {
    name: []const u8,
    type_text: []const u8,
    nullable: bool,
};

fn freeExistingColumns(gpa: std.mem.Allocator, cols: []ExistingColumn) void {
    for (cols) |c| {
        gpa.free(c.name);
        gpa.free(c.type_text);
    }
    gpa.free(cols);
}

fn findExistingColumn(cols: []const ExistingColumn, name: []const u8) ?ExistingColumn {
    for (cols) |c| {
        if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    }
    return null;
}

/// 读取现有列的类型文本（各类库的来源不同，但都归成「基础名(参数)」形态）。
fn existingColumnInfos(s: *Session, gpa: std.mem.Allocator, kind: DatabaseKind, table_name: []const u8) ![]ExistingColumn {
    var list: std.ArrayList(ExistingColumn) = .empty;
    errdefer {
        for (list.items) |c| {
            gpa.free(c.name);
            gpa.free(c.type_text);
        }
        list.deinit(gpa);
    }

    switch (kind) {
        .sqlite => {
            const quoted = try DatabaseKind.sqlite.quoteAlloc(gpa, table_name);
            defer gpa.free(quoted);
            const sql = try std.fmt.allocPrint(gpa, "PRAGMA table_info({s})", .{quoted});
            defer gpa.free(sql);
            const rows = try s.queryRows(sql, &.{});
            for (rows) |row| {
                const name = row.get("name") orelse continue;
                const type_text = row.get("type") orelse continue;
                const notnull = row.get("notnull") orelse continue;
                try list.append(gpa, .{
                    .name = try gpa.dupe(u8, name.asText() orelse ""),
                    .type_text = try gpa.dupe(u8, type_text.asText() orelse ""),
                    .nullable = (notnull.asI64() orelse 0) == 0,
                });
            }
        },
        .mysql => {
            // MySQL 8 的 information_schema 列名返回大写 → 按序号取
            const rows = try s.queryRows(
                "SELECT column_name, column_type, is_nullable FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ?",
                &.{.{ .text = table_name }},
            );
            for (rows) |row| {
                if (row.values.len < 3) continue;
                const name = row.values[0].asText() orelse continue;
                const type_text = row.values[1].asText() orelse continue;
                const nullable = if (row.values[2].asText()) |v| std.ascii.eqlIgnoreCase(v, "YES") else false;
                try list.append(gpa, .{
                    .name = try gpa.dupe(u8, name),
                    .type_text = try gpa.dupe(u8, type_text),
                    .nullable = nullable,
                });
            }
        },
        .sqlserver => {
            const rows = try s.queryRows(
                "SELECT column_name, data_type, character_maximum_length, numeric_precision, numeric_scale, is_nullable " ++
                    "FROM information_schema.columns WHERE table_name = @p0",
                &.{.{ .text = table_name }},
            );
            for (rows) |row| {
                if (row.values.len < 6) continue;
                const name = row.values[0].asText() orelse continue;
                const data_type = row.values[1].asText() orelse continue;
                const nullable = if (row.values[5].asText()) |v| std.ascii.eqlIgnoreCase(v, "YES") else false;
                try list.append(gpa, .{
                    .name = try gpa.dupe(u8, name),
                    .type_text = try composeTypeText(gpa, data_type, row.values[2].asI64(), row.values[3].asI64(), row.values[4].asI64()),
                    .nullable = nullable,
                });
            }
        },
        .postgresql, .kingbase, .highgo, .vastbase => {
            const rows = try s.queryRows(
                "SELECT column_name, data_type, character_maximum_length, numeric_precision, numeric_scale, is_nullable " ++
                    "FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1",
                &.{.{ .text = table_name }},
            );
            for (rows) |row| {
                if (row.values.len < 6) continue;
                const name = row.values[0].asText() orelse continue;
                const data_type = row.values[1].asText() orelse continue;
                const nullable = if (row.values[5].asText()) |v| std.ascii.eqlIgnoreCase(v, "YES") else false;
                try list.append(gpa, .{
                    .name = try gpa.dupe(u8, name),
                    .type_text = try composeTypeText(gpa, data_type, row.values[2].asI64(), row.values[3].asI64(), row.values[4].asI64()),
                    .nullable = nullable,
                });
            }
        },
        else => return error.Unsupported,
    }
    return list.toOwnedSlice(gpa);
}

/// 把 information_schema 的 `data_type` + 长度/精度拼回「基础名(参数)」。
/// `character_maximum_length < 0` 是 SQL Server 的 `(max)`；`precision/scale` 只对数值型用。
fn composeTypeText(
    gpa: std.mem.Allocator,
    data_type: []const u8,
    char_len: ?i64,
    precision: ?i64,
    scale: ?i64,
) ![]u8 {
    if (char_len) |cl| {
        if (cl < 0) return std.fmt.allocPrint(gpa, "{s}(max)", .{data_type});
        return std.fmt.allocPrint(gpa, "{s}({d})", .{ data_type, cl });
    }
    if (precision) |p| {
        if (scale) |sc| return std.fmt.allocPrint(gpa, "{s}({d},{d})", .{ data_type, p, sc });
        return std.fmt.allocPrint(gpa, "{s}({d})", .{ data_type, p });
    }
    return gpa.dupe(u8, data_type);
}

/// 归一到「类名 + 括号参数」用于比较：小写、压空白、括号内不留空格。
fn normalizeTypeInto(buf: []u8, text: []const u8) []const u8 {
    var out: usize = 0;
    var in_paren = false;
    var last_space = false;
    for (std.mem.trim(u8, text, " \t\r\n")) |ch| {
        var c = ch;
        if (c == '(') in_paren = true;
        if (c == ')') in_paren = false;
        if (c == ' ' or c == '\t') {
            if (in_paren) continue;
            if (last_space) continue;
            last_space = true;
        } else {
            last_space = false;
        }
        if (c >= 'A' and c <= 'Z') c = c + 32;
        if (out >= buf.len) break;
        buf[out] = c;
        out += 1;
    }
    return buf[0..out];
}

/// 拆成「基础名」与「括号参数」（参数含括号本身）。
fn splitType(text: []const u8) struct { base: []const u8, args: []const u8 } {
    if (std.mem.indexOfScalar(u8, text, '(')) |i| {
        return .{ .base = std.mem.trim(u8, text[0..i], " "), .args = text[i..] };
    }
    return .{ .base = text, .args = "" };
}

/// 不同库对同一类型的叫法归并（PostgreSQL 的 `integer` / `character varying` 尤其明显）。
fn canonicalBaseType(base: []const u8) []const u8 {
    const pairs = [_][2][]const u8{
        .{ "integer", "int" },
        .{ "int4", "int" },
        .{ "int8", "bigint" },
        .{ "int2", "smallint" },
        .{ "character varying", "varchar" },
        .{ "varchar2", "varchar" },
        .{ "nvarchar2", "nvarchar" },
        .{ "character", "char" },
        .{ "timestamp without time zone", "timestamp" },
        .{ "numeric", "decimal" },
        .{ "number", "decimal" },
        .{ "bool", "boolean" },
        .{ "float8", "double precision" },
        .{ "float4", "real" },
    };
    for (pairs) |p| {
        if (std.ascii.eqlIgnoreCase(base, p[0])) return p[1];
    }
    return base;
}

/// 类型文本是否等价。
///
/// 规则：**基础名（归并同义词后）必须相同**；参数只在**两边都写了**的时候才比 ——
/// MySQL 的 `bit(1)` / `int(11)` 这类显示宽度、`tinyint` 与 `tinyint(1)` 的口径差异
/// 都不该被当成「类型变了」而反复 ALTER（反复 ALTER 是真实的生产事故源）。
fn typesEquivalent(model_type: []const u8, db_type: []const u8) bool {
    // 超长类型文本（真实库里几乎不会出现）直接判等价：宁可少改一次，也不要因截断
    // 造成「每轮同步都判定不一致」→ 反复 ALTER（那是会破坏生产的循环）
    var mbuf: [192]u8 = undefined;
    var dbuf: [192]u8 = undefined;
    if (model_type.len >= mbuf.len or db_type.len >= dbuf.len) return true;
    const m = splitType(normalizeTypeInto(&mbuf, model_type));
    const d = splitType(normalizeTypeInto(&dbuf, db_type));
    if (!std.ascii.eqlIgnoreCase(canonicalBaseType(m.base), canonicalBaseType(d.base))) return false;
    if (m.args.len == 0 or d.args.len == 0) return true;
    return std.mem.eql(u8, m.args, d.args);
}

test "连接串解析" {
    const a = std.testing.allocator;
    var opts = try parseConnectionString(a, "Data Source=..\\Data\\DG.db;Provider=SQLite;ShowSql=true;Migration=On;Pooling=false;Foo=Bar");
    defer opts.deinit(a);

    try std.testing.expectEqual(DatabaseKind.sqlite, opts.provider);
    try std.testing.expectEqualStrings("..\\Data\\DG.db", opts.data_source);
    try std.testing.expectEqual(true, opts.show_sql.?);
    try std.testing.expectEqual(Migration.on, opts.migration.?);
    try std.testing.expectEqual(false, opts.pooling.?);
    try std.testing.expectEqual(@as(usize, 1), opts.extra.len);
    try std.testing.expectEqualStrings("Foo", opts.extra[0].key);
}

test "连接串缺 Provider 时默认 SQLite，未知 Provider 报错" {
    const a = std.testing.allocator;
    var opts = try parseConnectionString(a, "Data Source=:memory:");
    defer opts.deinit(a);

    try std.testing.expectEqual(DatabaseKind.sqlite, opts.provider);
    try std.testing.expectError(error.Unsupported, parseConnectionString(a, "Data Source=x;Provider=NoSuchDb"));
}

test "连接串：时序库 / 国产库 Provider 与 InfluxDB 专属键" {
    const a = std.testing.allocator;

    var td = try parseConnectionString(a, "Provider=TDengine;Server=127.0.0.1;User=root;Password=taosdata;Database=power");
    defer td.deinit(a);
    try std.testing.expectEqual(DatabaseKind.tdengine, td.provider);
    try std.testing.expectEqualStrings("root", td.user);

    var inf = try parseConnectionString(a, "Provider=InfluxDB;Server=http://127.0.0.1:8086;Token=tok;Org=myorg;Bucket=mybucket;Timeout=5000");
    defer inf.deinit(a);
    try std.testing.expectEqual(DatabaseKind.influxdb, inf.provider);
    try std.testing.expectEqualStrings("tok", inf.token);
    try std.testing.expectEqualStrings("myorg", inf.org);
    try std.testing.expectEqualStrings("mybucket", inf.bucket);
    try std.testing.expectEqual(@as(u64, 5000), inf.timeout_ms);

    // 国产库：金仓 / 瀚高 / 海量走 PG 协议，NovaDb 走 MySQL 协议（Provider 别名也要认）
    try std.testing.expectEqual(DatabaseKind.kingbase, DatabaseKind.fromProvider("Kingbase") orelse .sqlite);
    try std.testing.expectEqual(DatabaseKind.highgo, DatabaseKind.fromProvider("瀚高") orelse .sqlite);
    try std.testing.expectEqual(DatabaseKind.vastbase, DatabaseKind.fromProvider("VastBase") orelse .sqlite);
    try std.testing.expectEqual(DatabaseKind.nova, DatabaseKind.fromProvider("NovaDB") orelse .sqlite);

    // MongoDB：文档库，鉴权库用 AuthSource（缺省 admin）
    var mg = try parseConnectionString(a, "Provider=MongoDB;Server=127.0.0.1;User=u;Password=p;Database=app;AuthSource=admin");
    defer mg.deinit(a);
    try std.testing.expectEqual(DatabaseKind.mongodb, mg.provider);
    try std.testing.expectEqualStrings("app", mg.database);
    try std.testing.expectEqualStrings("admin", mg.auth_source);

    // 没有 bucket 也没有 database 的 InfluxDB 连接串无法定位数据 → 明确报错
    const m = try EntityModel.parse(a, "<EntityModel><Tables/></EntityModel>");
    try std.testing.expectError(error.NoDatabase, Dal.initWithModel(a, "Provider=InfluxDB;Server=127.0.0.1", m));

    // DuckDB：嵌入式，缺 duckdb 动态库时**立即**报错（不拖到第一次查询）
    const m2 = try EntityModel.parse(a, "<EntityModel><Tables/></EntityModel>");
    const duck = Dal.initWithModel(a, "Data Source=:memory:;Provider=DuckDB", m2);
    if (duck) |d| {
        var dal_ok = d;
        dal_ok.deinit(); // 本机装了 duckdb.dll：能建就好，随后正常释放
    } else |e| {
        try std.testing.expectEqual(@import("zzig").duckdb.Error.DuckDbNotAvailable, e);
    }
}

test "sync_schema 幂等（临时文件库）" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "sync");
    defer a.free(db_path);
    defer @import("zzig").File.DeleteQuiet(db_path);

    const xml =
        \\<EntityModel><Tables><Table Name="JiLiYu" TableName="DH_JiLiYu">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Code" DataType="String" Length="50" />
        \\  </Columns>
        \\  <Indexes><Index Columns="Code" Unique="True" /></Indexes>
        \\</Table></Tables></EntityModel>
    ;

    const m = try EntityModel.parse(a, xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);

    var dal = try Dal.initWithModel(a, conn, m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const r1 = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 1), r1.tables_created);
    try std.testing.expectEqual(@as(usize, 1), r1.indexes_created);

    // 二次同步：幂等
    const r2 = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 0), r2.tables_created);
    try std.testing.expectEqual(@as(usize, 0), r2.columns_added);
    try std.testing.expectEqual(@as(usize, 0), r2.indexes_created);

    // 表已可写入
    const t = try dal.table("JiLiYu");
    const id = try t.insert(&s, &[_]@import("sqlbuild.zig").Field{
        .{ .name = "Code", .value = .{ .text = "k1" } },
    });
    try std.testing.expectEqual(@as(i64, 1), id);
    try std.testing.expectEqual(@as(i64, 1), try t.count(&s, null));
}

test "Migration=Off 不做任何 DDL" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "off");
    defer a.free(db_path);
    defer @import("zzig").File.DeleteQuiet(db_path);

    const xml =
        \\<EntityModel><Tables><Table Name="T">
        \\  <Columns><Column Name="Id" DataType="Int32" PrimaryKey="True" /></Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m = try EntityModel.parse(a, xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite;Migration=Off", .{db_path});
    defer a.free(conn);

    var dal = try Dal.initWithModel(a, conn, m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const r = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 1), r.tables_skipped);
    try std.testing.expect(!r.executed);
}

test "类型等价判定：同义词归并、参数只在两边都写时比较" {
    // 完全一致
    try std.testing.expect(typesEquivalent("nvarchar(50)", "NVARCHAR(50)"));
    try std.testing.expect(typesEquivalent("decimal(18,2)", "DECIMAL(18, 2)"));
    // 一边没写参数 → 等价（MySQL 的显示宽度不该触发 ALTER）
    try std.testing.expect(typesEquivalent("bit", "bit(1)"));
    try std.testing.expect(typesEquivalent("tinyint", "tinyint(1)"));
    // 同义词归并（PostgreSQL 的 information_schema 叫法与 DDL 不同）
    try std.testing.expect(typesEquivalent("varchar(50)", "character varying(50)"));
    try std.testing.expect(typesEquivalent("int", "integer"));
    try std.testing.expect(typesEquivalent("decimal(18,2)", "numeric(18,2)"));
    try std.testing.expect(typesEquivalent("timestamp", "timestamp without time zone"));
    try std.testing.expect(typesEquivalent("double precision", "float8"));
    // 真的变了
    try std.testing.expect(!typesEquivalent("nvarchar(20)", "nvarchar(50)"));
    try std.testing.expect(!typesEquivalent("nvarchar(50)", "text"));
    try std.testing.expect(!typesEquivalent("int", "bigint"));
    try std.testing.expect(!typesEquivalent("decimal(18,2)", "decimal(18,4)"));
}

test "Migration=Full：SQLite 改列类型走整表重建，数据与索引保留" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "alter");
    defer a.free(db_path);
    defer @import("zzig").File.DeleteQuiet(db_path);

    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite;Migration=Full", .{db_path});
    defer a.free(conn);

    // 先用「Code 只有 20 长」的模型建表并写入一行
    {
        const xml =
            \\<EntityModel><Tables><Table Name="AlterT">
            \\  <Columns>
            \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
            \\    <Column Name="Code" DataType="String" Length="20" />
            \\  </Columns>
            \\  <Indexes><Index Columns="Code" /></Indexes>
            \\</Table></Tables></EntityModel>
        ;
        const m1 = try EntityModel.parse(a, xml);
        var dal1 = try Dal.initWithModel(a, conn, m1);
        defer dal1.deinit();
        var s1 = try dal1.openSession();
        defer s1.deinit();
        const r1 = try dal1.syncSchema(&s1);
        try std.testing.expectEqual(@as(usize, 1), r1.tables_created);

        const t1 = try dal1.table("AlterT");
        _ = try t1.insert(&s1, &[_]@import("sqlbuild.zig").Field{
            .{ .name = "Code", .value = .{ .text = "keep-me" } },
        });
    }

    // 再用「Code 变成 50 长」的模型同步：Full 档应改列
    {
        const xml =
            \\<EntityModel><Tables><Table Name="AlterT">
            \\  <Columns>
            \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
            \\    <Column Name="Code" DataType="String" Length="50" />
            \\  </Columns>
            \\  <Indexes><Index Columns="Code" /></Indexes>
            \\</Table></Tables></EntityModel>
        ;
        const m2 = try EntityModel.parse(a, xml);
        var dal2 = try Dal.initWithModel(a, conn, m2);
        defer dal2.deinit();
        var s2 = try dal2.openSession();
        defer s2.deinit();

        const r2 = try dal2.syncSchema(&s2);
        try std.testing.expectEqual(@as(usize, 1), r2.columns_altered);
        try std.testing.expectEqual(@as(usize, 0), r2.tables_created);

        // 列类型已经变成 nvarchar(50)，且 NOT NULL 约束在重建后被保留
        const infos = try existingColumnInfos(&s2, a, .sqlite, "AlterT");
        defer freeExistingColumns(a, infos);
        const code = findExistingColumn(infos, "Code").?;
        try std.testing.expectEqualStrings("nvarchar(50)", code.type_text);
        try std.testing.expect(!code.nullable);

        // 数据没丢，索引也重建了
        const t2 = try dal2.table("AlterT");
        try std.testing.expectEqual(@as(i64, 1), try t2.count(&s2, null));
        const rows = try s2.queryRows("SELECT Code FROM AlterT", &.{});
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqualStrings("keep-me", rows[0].values[0].text);

        const idx = try existingIndexes(&s2, a, .sqlite, "AlterT");
        defer freeColumnNames(a, idx);
        try std.testing.expectEqual(@as(usize, 1), idx.len);
        try std.testing.expectEqualStrings("ix_AlterT_Code", idx[0]);

        // 临时表已清理干净
        try std.testing.expect(!try tableExists(&s2, .sqlite, "AlterT_zcode_old"));

        // 再同步一次：幂等（不该反复重建）
        const r3 = try dal2.syncSchema(&s2);
        try std.testing.expectEqual(@as(usize, 0), r3.columns_altered);
    }
}

test "Migration=On 不改列类型（只创建语义）" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "ononly");
    defer a.free(db_path);
    defer @import("zzig").File.DeleteQuiet(db_path);

    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite;Migration=On", .{db_path});
    defer a.free(conn);

    {
        const xml =
            \\<EntityModel><Tables><Table Name="OnT">
            \\  <Columns>
            \\    <Column Name="Id" DataType="Int32" PrimaryKey="True" />
            \\    <Column Name="Code" DataType="String" Length="20" />
            \\  </Columns>
            \\</Table></Tables></EntityModel>
        ;
        const m1 = try EntityModel.parse(a, xml);
        var dal1 = try Dal.initWithModel(a, conn, m1);
        defer dal1.deinit();
        var s1 = try dal1.openSession();
        defer s1.deinit();
        _ = try dal1.syncSchema(&s1);
    }

    {
        const xml =
            \\<EntityModel><Tables><Table Name="OnT">
            \\  <Columns>
            \\    <Column Name="Id" DataType="Int32" PrimaryKey="True" />
            \\    <Column Name="Code" DataType="String" Length="50" />
            \\  </Columns>
            \\</Table></Tables></EntityModel>
        ;
        const m2 = try EntityModel.parse(a, xml);
        var dal2 = try Dal.initWithModel(a, conn, m2);
        defer dal2.deinit();
        var s2 = try dal2.openSession();
        defer s2.deinit();
        const r = try dal2.syncSchema(&s2);
        try std.testing.expectEqual(@as(usize, 0), r.columns_altered);

        const infos = try existingColumnInfos(&s2, a, .sqlite, "OnT");
        defer freeExistingColumns(a, infos);
        // 仍是建表时的 20 长（On 档不动结构）
        try std.testing.expectEqualStrings("nvarchar(20)", findExistingColumn(infos, "Code").?.type_text);
    }
}
