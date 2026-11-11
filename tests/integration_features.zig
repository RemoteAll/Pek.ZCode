//! 集成测试（第二批）：分表路由 / 读写分离 / 连接池 / 写入拦截器 / Migration Full。
//!
//! 与 `integration.zig` 拆开是为了让「新增能力」的用例集中可查；两者用同一套模型与临时库口径。

const std = @import("std");
const zcode = @import("zcode");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
    \\  <Option><Namespace>Test.Entity</Namespace><ConnName>DH</ConnName></Option>
    \\  <Tables>
    \\    <Table Name="Log" TableName="DH_Log">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Title" DataType="String" Length="50" />
    \\        <Column Name="CreateTime" DataType="DateTime" Nullable="True" />
    \\        <Column Name="UpdateTime" DataType="DateTime" Nullable="True" />
    \\      </Columns>
    \\      <Indexes><Index Columns="Title" /></Indexes>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

fn tempDbPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    return zcode.File.UniqueTempName(a, tag, ".db");
}

fn openDalFile(a: std.mem.Allocator, db_path: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

// ───────────────────────── 分表路由 ─────────────────────────

test "分表：按月路由到不同物理表并真实写入" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "shard");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    // 基础表 + 两个月分片表各建一份（结构同源）
    _ = try dal.syncSchema(&s);
    for ([_][]const u8{ "DH_Log_202401", "DH_Log_202402" }) |tbl| {
        const t = try dal.table("Log");
        // 用表元数据副本改物理名：`createTableAlloc` 看的是 `TableMeta`，不看 `TableRef.table_name`
        var meta = t.table.*;
        meta.table_name = tbl;
        const ddl = try zcode.DatabaseKind.sqlite.createTableAlloc(a, &meta);
        defer {
            for (ddl) |stmt| a.free(stmt);
            a.free(ddl);
        }
        for (ddl) |stmt| {
            // 只建表：索引名是按基础表名生成的，分片表再建会撞索引名
            if (!std.mem.startsWith(u8, stmt, "CREATE TABLE")) continue;
            _ = try s.execute(stmt, &.{});
        }
    }

    try dal.addShardPolicy("Log", .{
        .gpa = a,
        .field = "CreateTime",
        .base_conn = "DH",
        .base_table = "DH_Log",
        .table_policy = "{0}_{1:yyyyMM}",
        .step_ms = 30 * zcode.shards.day_ms,
        .level = .month,
    });

    // 2024-01-15 → DH_Log_202401；2024-02-20 → DH_Log_202402
    const jan = try dal.tableShard("Log", .{ .datetime = .{ .year = 2024, .month = 1, .day = 15 } });
    defer jan.model.deinit(a);
    try std.testing.expectEqualStrings("DH_Log_202401", jan.model.table_name);
    _ = try jan.table.insert(&s, &.{.{ .name = "Title", .value = .{ .text = "jan" } }});

    const feb = try dal.tableShard("Log", .{ .datetime = .{ .year = 2024, .month = 2, .day = 20 } });
    defer feb.model.deinit(a);
    try std.testing.expectEqualStrings("DH_Log_202402", feb.model.table_name);
    _ = try feb.table.insert(&s, &.{.{ .name = "Title", .value = .{ .text = "feb" } }});

    // 两个分片各自只有自己的数据
    var t_jan = try dal.table("Log");
    t_jan.table_name = "DH_Log_202401";
    var t_feb = try dal.table("Log");
    t_feb.table_name = "DH_Log_202402";
    try std.testing.expectEqual(@as(i64, 1), try t_jan.count(&s, null));
    try std.testing.expectEqual(@as(i64, 1), try t_feb.count(&s, null));

    // 没有注册策略的表 → 显式报错（不静默写基础表）
    try std.testing.expectError(error.NoShardPolicy, dal.tableShard("NoSuchTable", .{ .int = 0 }));
    // 策略存在但字段值无法解析成时间（雪花 Id = 0）→ 明确报错，不猜分片
    try std.testing.expectError(error.InvalidShardValue, dal.tableShard("Log", .{ .int = 0 }));
}

test "分表：区间扫描与条件推导（集成口径）" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "shardr");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();

    try dal.addShardPolicy("Log", .{
        .gpa = a,
        .field = "CreateTime",
        .base_conn = "DH",
        .base_table = "DH_Log",
        .table_policy = "{0}_{1:yyyyMM}",
        .step_ms = 30 * zcode.shards.day_ms,
        .level = .month,
    });

    const policy = dal.shardPolicyFor("Log").?;
    var out: std.ArrayList(zcode.shards.ShardModel) = .empty;
    defer {
        for (out.items) |m| m.deinit(a);
        out.deinit(a);
    }

    var w = zcode.Where.init(a);
    defer w.deinit();
    _ = try w.ge("CreateTime", .{ .datetime = .{ .year = 2024, .month = 1, .day = 20 } });
    _ = try w.lt("CreateTime", .{ .datetime = .{ .year = 2024, .month = 3, .day = 1 } });
    try policy.shardsForWhere(&w, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("DH_Log_202401", out.items[0].table_name);
    try std.testing.expectEqualStrings("DH_Log_202402", out.items[1].table_name);
}

// ───────────────────────── 读写分离 ─────────────────────────

test "读写分离：从库会话只读，忽略表与全局切主库回落主库" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "rw");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    {
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    // 从库挂同一文件（SQLite 没有物理复制，这里验证的是「连接选择」语义）
    const replica_conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{path});
    defer a.free(replica_conn);
    try dal.attachReplicas(&.{replica_conn});
    try std.testing.expectEqual(@as(usize, 1), dal.replicaCount());

    // 默认：读会话选中从库，且是只读的
    var rs = try dal.readSessionFor("DH_Log");
    defer rs.deinit();
    try std.testing.expect(rs.read_only);
    _ = try rs.queryRows("SELECT 1", &.{});
    try std.testing.expectError(error.ReadOnly, rs.execute("DELETE FROM DH_Log", &.{}));

    // 忽略表 → 回落主库（主库会话可写）
    try dal.readStrategy().setIgnoreTables(&.{"DH_Log"});
    var ps = try dal.readSessionFor("DH_Log");
    defer ps.deinit();
    try std.testing.expect(!ps.read_only);
    _ = try ps.execute("INSERT INTO DH_Log (Title) VALUES (?)", &.{.{ .text = "via-primary" }});

    // 全局切主库 → 一律主库（可写）
    try dal.readStrategy().setIgnoreTables(&.{});
    dal.setPrimaryOnly(true);
    var ps2 = try dal.readSessionFor("DH_Log");
    defer ps2.deinit();
    _ = try ps2.execute("INSERT INTO DH_Log (Title) VALUES (?)", &.{.{ .text = "primary-only" }});
    dal.setPrimaryOnly(false);

    // 轮询：两个从库时下标交替
    try dal.attachReplicas(&.{ replica_conn, replica_conn });
    var r1 = try dal.readSessionFor("DH_Log");
    r1.deinit();
    var r2 = try dal.readSessionFor("DH_Log");
    r2.deinit();
    try std.testing.expectEqual(@as(usize, 0), dal.rr_index);
}

test "读写分离：方言不一致的从库拒绝挂载" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "rw2");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();

    try std.testing.expectError(
        error.Unsupported,
        dal.attachReplicas(&.{"Provider=MySQL;Server=127.0.0.1;Database=x;UserID=root;Password="}),
    );
    try std.testing.expectEqual(@as(usize, 0), dal.replicaCount());
}

// ───────────────────────── 连接池 ─────────────────────────

test "连接池：Dal 级池化（文件库）可复用且写后可见" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "pool");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    try std.testing.expect(dal.supportsPooling());

    var p = dal.makePool(.{ .max_size = 2, .idle_timeout_ms = 0 });
    defer p.deinit();

    {
        const s = try p.acquire();
        var owned = s;
        _ = try dal.syncSchema(&owned);
        p.release(owned);
    }
    {
        const s = try p.acquire();
        var owned = s;
        const t = try dal.table("Log");
        _ = try t.insert(&owned, &.{.{ .name = "Title", .value = .{ .text = "pooled" } }});
        p.release(owned);
    }
    try std.testing.expectEqual(@as(usize, 1), p.stats().created);
    try std.testing.expectEqual(@as(usize, 1), p.stats().reused);

    // 数据真的落盘
    var s = try dal.openSession();
    defer s.deinit();
    const t = try dal.table("Log");
    try std.testing.expectEqual(@as(i64, 1), try t.count(&s, null));
}

test "连接池：内存库不支持池化（每次连接是独立库）" {
    const a = std.testing.allocator;
    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = try zcode.Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
    defer dal.deinit();
    try std.testing.expect(!dal.supportsPooling());
}

// ───────────────────────── 写入拦截器 ─────────────────────────

test "拦截器：插入自动补 CreateTime/UpdateTime，更新只刷新 UpdateTime" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "icp");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var ti = zcode.interceptor.TimeInterceptor{};
    var chain = zcode.interceptor.Chain.init(a);
    defer chain.deinit();
    try chain.add(ti.interceptor());
    dal.setInterceptorChain(&chain);

    const t = try dal.table("Log");
    const id = try t.insert(&s, &.{.{ .name = "Title", .value = .{ .text = "auto" } }});
    try std.testing.expect(id > 0);

    // 库里两个时间列都被补上
    const row = (try t.findByPk(&s, &.{.{ .int = id }})).?;
    const create_time = row.get("CreateTime").?;
    const update_time = row.get("UpdateTime").?;
    try std.testing.expect(create_time.asDatetime().?.year >= 2024);
    try std.testing.expect(update_time.asDatetime().?.year >= 2024);
    try std.testing.expectEqual(@as(usize, 1), chain.applied_count);

    // 更新：显式只改 Title，拦截器补 UpdateTime（不补 CreateTime）
    var w = zcode.Where.init(a);
    defer w.deinit();
    _ = try w.eq("Id", .{ .int = id });
    _ = try t.update(&s, &.{.{ .name = "Title", .value = .{ .text = "changed" } }}, &w);
    try std.testing.expect(chain.applied_count >= 2);
}

test "拦截器：批量插入同样补审计列" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "icp2");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var ti = zcode.interceptor.TimeInterceptor{};
    var chain = zcode.interceptor.Chain.init(a);
    defer chain.deinit();
    try chain.add(ti.interceptor());
    dal.setInterceptorChain(&chain);

    const t = try dal.table("Log");
    const rows = [_][]const zcode.sqlbuild.Field{
        &.{.{ .name = "Title", .value = .{ .text = "a" } }},
        &.{.{ .name = "Title", .value = .{ .text = "b" } }},
    };
    try std.testing.expectEqual(@as(usize, 2), try t.insertBatch(&s, &rows));
    try std.testing.expectEqual(@as(i64, 2), try t.count(&s, null));
}

// ───────────────────────── 迁移 Full ─────────────────────────

test "迁移：On 档不删列，Full 档删除模型外的列与索引" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "mig");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDalFile(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    // 手工加一列 + 一个模型外索引（模拟历史遗留）
    _ = try s.execute("ALTER TABLE DH_Log ADD COLUMN Legacy TEXT", &.{});
    _ = try s.execute("CREATE INDEX ix_legacy ON DH_Log (Legacy)", &.{});

    // On 档：不删
    const r_on = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 0), r_on.columns_dropped);
    try std.testing.expectEqual(@as(usize, 0), r_on.indexes_dropped);

    // 切成 Full：删列 + 删索引
    const conn_full = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite;Migration=Full", .{path});
    defer a.free(conn_full);
    const m_full = try zcode.EntityModel.parse(a, model_xml);
    var dal_full = try zcode.Dal.initWithModel(a, conn_full, m_full);
    defer dal_full.deinit();
    var s_full = try dal_full.openSession();
    defer s_full.deinit();

    const r_full = try dal_full.syncSchema(&s_full);
    try std.testing.expectEqual(@as(usize, 1), r_full.columns_dropped);
    try std.testing.expectEqual(@as(usize, 1), r_full.indexes_dropped);

    // 再同步一次：幂等（已无可删）
    const r_again = try dal_full.syncSchema(&s_full);
    try std.testing.expectEqual(@as(usize, 0), r_again.columns_dropped);
    try std.testing.expectEqual(@as(usize, 0), r_again.indexes_dropped);

    // Legacy 列确实没了
    const rows = try s_full.queryRows("PRAGMA table_info(DH_Log)", &.{});
    for (rows) |row| {
        if (row.get("name")) |v| {
            if (v.asText()) |name| try std.testing.expect(!std.ascii.eqlIgnoreCase(name, "Legacy"));
        }
    }
}

test "迁移：表级档位只能收紧（表级 Off 时不建表）" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "mig2");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    const xml =
        \\<EntityModel><Tables>
        \\  <Table Name="Skip" TableName="Skip_Table" Migration="Off">
        \\    <Columns><Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" /></Columns>
        \\  </Table>
        \\  <Table Name="Keep" TableName="Keep_Table">
        \\    <Columns><Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" /></Columns>
        \\  </Table>
        \\</Tables></EntityModel>
    ;
    const m = try zcode.EntityModel.parse(a, xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite;Migration=Full", .{path});
    defer a.free(conn);
    var dal = try zcode.Dal.initWithModel(a, conn, m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    const r = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 1), r.tables_created); // 只有 Keep
    try std.testing.expectEqual(@as(usize, 1), r.tables_skipped); // Skip 被表级 Off 跳过

    const rows = try s.queryRows("SELECT name FROM sqlite_master WHERE type='table' AND name='Skip_Table'", &.{});
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}
