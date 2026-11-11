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
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const dbtable = @import("dbtable.zig");
const TableRef = dbtable.TableRef;
const readwrite = @import("readwrite.zig");
const shards = @import("shards.zig");
const interceptor = @import("interceptor.zig");
const pool = @import("pool.zig");

pub const ConnectionOptions = struct {
    provider: DatabaseKind = .sqlite,
    data_source: []const u8 = "",
    migration: ?Migration = null,
    show_sql: bool = false,
    read_only: bool = false,
    pooling: ?bool = null,
    /// MySQL 专属（`Provider=MySQL` 时才用）：服务器 / 端口 / 账号 / 库名
    server: []const u8 = "",
    port: u16 = 3306,
    user: []const u8 = "",
    password: []const u8 = "",
    database: []const u8 = "",
    /// 未识别的键值（原样保留，便于诊断/向前兼容）
    extra: []model.KeyValue = &.{},

    /// 释放自持内存（`data_source` / MySQL 字段 / `extra`）。
    pub fn deinit(self: *ConnectionOptions, gpa: std.mem.Allocator) void {
        if (self.data_source.len > 0) gpa.free(self.data_source);
        if (self.server.len > 0) gpa.free(self.server);
        if (self.user.len > 0) gpa.free(self.user);
        if (self.password.len > 0) gpa.free(self.password);
        if (self.database.len > 0) gpa.free(self.database);
        if (self.extra.len > 0) gpa.free(self.extra);
        self.data_source = "";
        self.server = "";
        self.user = "";
        self.password = "";
        self.database = "";
        self.extra = &.{};
    }
};

/// 解析连接串（键名忽略大小写，值保留原样）。
///
/// 认得的键：`Provider` / `Data Source`（别名 `DataSource`/`Filename`）/
/// `Migration` / `ShowSql` / `Readonly` / `Pooling`；其余键进 `extra`。
pub fn parseConnectionString(gpa: std.mem.Allocator, conn_str: []const u8) !ConnectionOptions {
    var opts = ConnectionOptions{};
    errdefer if (opts.data_source.len > 0) gpa.free(opts.data_source);
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
            opts.server = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Port")) {
            opts.port = std.fmt.parseInt(u16, value, 10) catch 3306;
        } else if (std.ascii.eqlIgnoreCase(key, "Uid") or std.ascii.eqlIgnoreCase(key, "User") or
            std.ascii.eqlIgnoreCase(key, "User Id") or std.ascii.eqlIgnoreCase(key, "UserId") or
            std.ascii.eqlIgnoreCase(key, "UserID") or std.ascii.eqlIgnoreCase(key, "Username"))
        {
            opts.user = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Pwd") or std.ascii.eqlIgnoreCase(key, "Password")) {
            opts.password = try gpa.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "Migration")) {
            opts.migration = Migration.parse(value);
        } else if (std.ascii.eqlIgnoreCase(key, "ShowSql")) {
            opts.show_sql = parseBool(value);
        } else if (std.ascii.eqlIgnoreCase(key, "Readonly") or std.ascii.eqlIgnoreCase(key, "ReadOnly")) {
            opts.read_only = parseBool(value);
        } else if (std.ascii.eqlIgnoreCase(key, "Pooling")) {
            opts.pooling = parseBool(value);
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
    /// 生成但未执行（`Migration=ReadOnly`）
    executed: bool = true,

    pub fn describeAlloc(self: SchemaReport, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            gpa,
            "结构同步：建表 {d} / 补列 {d} / 建索引 {d} / 删列 {d} / 删索引 {d} / 跳过 {d}{s}",
            .{
                self.tables_created,  self.columns_added,   self.indexes_created,
                self.columns_dropped, self.indexes_dropped, self.tables_skipped,
                if (self.executed) "" else "（只读：未执行）",
            },
        );
    }
};

pub const Dal = struct {
    gpa: std.mem.Allocator,
    model: EntityModel,
    opts: ConnectionOptions,
    /// SQLite 动态库句柄（`Provider=MySQL` 时为 null，MySQL 走纯协议不需外部库）
    lib: ?sqlite.Lib = null,
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
    /// 写入拦截器链（不拥有，由调用方创建与销毁）
    chain: ?*interceptor.Chain = null,

    /// 一条分表路由：表名 + 策略（表名/模板字符串由 Dal 持有）
    pub const ShardRoute = struct {
        table_name: []const u8,
        policy: shards.TimePolicy,
    };

    /// 缓存注册项：类型擦除的回调（表名 + 失效函数）
    pub const CacheHook = struct {
        table_name: []const u8,
        ctx: *anyopaque,
        invalidate: *const fn (ctx: *anyopaque) void,
    };

    /// 从 `Model.xml` 文件打开。
    pub fn open(gpa: std.mem.Allocator, conn_str: []const u8, model_path: []const u8) !Dal {
        var m = try EntityModel.load(gpa, model_path);
        errdefer m.deinit();
        return initWithModel(gpa, conn_str, m);
    }

    /// 用已解析的模型打开（模型所有权转移给 Dal）。
    pub fn initWithModel(gpa: std.mem.Allocator, conn_str: []const u8, m: EntityModel) !Dal {
        var opts_owned = try parseConnectionString(gpa, conn_str);
        errdefer freeOptions(gpa, &opts_owned);

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
            .mysql => {
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
        if (self.lib) |*lib| lib.deinit();
        self.opts.deinit(self.gpa);
        self.model.deinit();
    }

    /// 注册整表缓存（由 `cache.Cache(T).init` 调用）。
    pub fn registerCache(self: *Dal, hook: CacheHook) !void {
        try self.cache_hooks.append(self.gpa, hook);
    }

    /// 注销整表缓存（按 ctx 指针匹配）。
    pub fn unregisterCache(self: *Dal, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < self.cache_hooks.items.len) {
            if (self.cache_hooks.items[i].ctx == ctx) {
                _ = self.cache_hooks.swapRemove(i);
                return;
            }
            i += 1;
        }
    }

    /// 写后失效：只通知与该表匹配的缓存。
    pub fn invalidateCaches(self: *Dal, table_name: []const u8) void {
        for (self.cache_hooks.items) |hook| {
            if (std.ascii.eqlIgnoreCase(hook.table_name, table_name)) hook.invalidate(hook.ctx);
        }
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
        switch (opts.provider) {
            .sqlite => {
                const lib_ptr = if (self.lib) |*l| l else return error.Unsupported;
                const db = try sqlite.Db.open(lib_ptr, opts.data_source);
                var s = Session.init(self.gpa, .sqlite, db);
                s.read_only = opts.read_only;
                return s;
            },
            .mysql => {
                const conn = try mysql.Conn.open(self.gpa, .{
                    .host = opts.server,
                    .port = opts.port,
                    .user = opts.user,
                    .password = opts.password,
                    .database = opts.database,
                });
                var s = Session.initWithDriver(self.gpa, .mysql, .{ .mysql = conn });
                s.read_only = opts.read_only;
                return s;
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
            .mysql => true,
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
        for (self.shard_routes.items) |*route| {
            if (std.ascii.eqlIgnoreCase(route.table_name, table_name)) return &route.policy;
        }
        return null;
    }

    /// 按字段值定位分片表句柄。返回的 `ShardModel` 由调用方释放。
    ///
    /// 跨库分片（`ConnPolicy` 指向别的连接）需要额外挂载连接，本轮**显式不支持**：
    /// 返回 `error.Unsupported` 并打印实际期望的连接名，避免静默写到错误库。
    pub fn tableShard(self: *Dal, table_name: []const u8, value: @import("zzig").db.Value) !struct { table: TableRef, model: shards.ShardModel } {
        const policy = self.shardPolicyFor(table_name) orelse return error.NoShardPolicy;
        const shard_model = (try policy.shardOf(value)) orelse return error.NoShardPolicy;

        if (!std.ascii.eqlIgnoreCase(shard_model.conn_name, self.connName())) {
            std.debug.print(
                "[zcode] 分表：分片连接 {s} 与当前连接 {s} 不同，尚未支持跨库分片（表 {s}）\n",
                .{ shard_model.conn_name, self.connName(), shard_model.table_name },
            );
            shard_model.deinit(self.gpa);
            return error.Unsupported;
        }

        const t = self.model.table(table_name) orelse {
            shard_model.deinit(self.gpa);
            return error.TableNotFound;
        };
        var ref = TableRef.init(self.gpa, self.opts.provider, t);
        ref.table_name = shard_model.table_name;
        ref.setWriteNotifier(@ptrCast(self), onTableWrite);
        ref.setInterceptorChain(self.chain);
        return .{ .table = ref, .model = shard_model };
    }

    /// 当前连接名（模型 `<Option><ConnName>`，缺省空串）。
    pub fn connName(self: *const Dal) []const u8 {
        return self.model.options.connName() orelse "";
    }

    // ── 写入拦截器 ──────────────────────────────────────────────

    /// 挂上写入拦截器链（不接管所有权）。此后 `table()` 取到的表句柄都会应用它。
    pub fn setInterceptorChain(self: *Dal, chain: ?*interceptor.Chain) void {
        self.chain = chain;
    }

    fn freeOptions(gpa: std.mem.Allocator, opts: *ConnectionOptions) void {
        opts.deinit(gpa);
    }

    /// 打开一个写会话；`Readonly=true` 时打开只读会话（写入在调用点报错）。
    pub fn openSession(self: *Dal) !Session {
        switch (self.opts.provider) {
            .sqlite => {
                const lib_ptr = if (self.lib) |*l| l else return error.Unsupported;
                var db = try sqlite.Db.open(lib_ptr, self.opts.data_source);
                errdefer db.close();
                var s = Session.init(self.gpa, .sqlite, db);
                s.read_only = self.opts.read_only;
                return s;
            },
            .mysql => {
                const conn = try mysql.Conn.open(self.gpa, .{
                    .host = self.opts.server,
                    .port = self.opts.port,
                    .user = self.opts.user,
                    .password = self.opts.password,
                    .database = self.opts.database,
                });
                var s = Session.initWithDriver(self.gpa, .mysql, .{ .mysql = conn });
                s.read_only = self.opts.read_only;
                return s;
            },
            else => return error.Unsupported,
        }
    }

    /// 取表句柄（按实体名或物理表名）。
    pub fn table(self: *Dal, name: []const u8) !TableRef {
        const t = self.model.table(name) orelse return error.TableNotFound;
        var ref = TableRef.init(self.gpa, self.opts.provider, t);
        ref.setWriteNotifier(@ptrCast(self), onTableWrite);
        ref.setInterceptorChain(self.chain);
        return ref;
    }

    fn onTableWrite(ctx: *anyopaque, table_name: []const u8) void {
        const self: *Dal = @ptrCast(@alignCast(ctx));
        self.invalidateCaches(table_name);
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
    pub fn syncSchema(self: *Dal, s: *Session) !SchemaReport {
        var report = SchemaReport{};

        const global = self.effectiveMigration();
        if (global == .off) {
            report.tables_skipped = self.model.tables.len;
            report.executed = false;
            return report;
        }
        report.executed = global.canExecute();

        for (self.model.tables) |*t| {
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

test "连接串解析" {
    const a = std.testing.allocator;
    var opts = try parseConnectionString(a, "Data Source=..\\Data\\DG.db;Provider=SQLite;ShowSql=true;Migration=On;Pooling=false;Foo=Bar");
    defer opts.deinit(a);

    try std.testing.expectEqual(DatabaseKind.sqlite, opts.provider);
    try std.testing.expectEqualStrings("..\\Data\\DG.db", opts.data_source);
    try std.testing.expect(opts.show_sql);
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
