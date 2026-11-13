//! 集成测试：真实 SQLite（动态加载 DLL）上的端到端链路。
//!
//! 覆盖：`Model.xml` 解析 → 增量建表 → 插入/按主键取/更新/分页查询/计数/删除，
//! 以及时间（XCode 7 位小数秒）与十进制（尾随零）在库里的往返。

const std = @import("std");
const zcode = @import("zcode");
const build_options = @import("build_options");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
    \\  <Option><Namespace>Test.Entity</Namespace><ConnName>DH</ConnName></Option>
    \\  <Tables>
    \\    <Table Name="JiLiYu" TableName="DH_JiLiYu" Description="激励语">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Code" DataType="String" Length="50" Master="True" Description="编码" />
    \\        <Column Name="Title" DataType="String" Description="标题" />
    \\        <Column Name="Amount" DataType="Decimal" Precision="18" Scale="4" />
    \\        <Column Name="Ok" DataType="Boolean" />
    \\        <Column Name="CreateTime" DataType="DateTime" />
    \\      </Columns>
    \\      <Indexes>
    \\        <Index Columns="Code" Unique="True" />
    \\        <Index Columns="CreateTime" />
    \\      </Indexes>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

fn openDal(a: std.mem.Allocator, db_path: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

/// 在临时目录下生成唯一库文件路径（调用方负责 free + 删文件）。
fn tempDbPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    return zcode.File.UniqueTempName(a, tag, ".db");
}

test "端到端：建表 → CRUD → 分页 → 聚合" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "crud");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = openDal(a, db_path) catch |e| {
        std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    const report = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 1), report.tables_created);
    try std.testing.expectEqual(@as(usize, 2), report.indexes_created);

    const table = try dal.table("JiLiYu");

    // 插入两行
    const now = zcode.DateTime.nowLocal();
    const id1 = try table.insert(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Code", .value = .{ .text = "k1" } },
        .{ .name = "Title", .value = .{ .text = "第一条" } },
        .{ .name = "Amount", .value = .{ .decimal = try zcode.Decimal.parse("12.3400") } },
        .{ .name = "Ok", .value = .{ .boolean = true } },
        .{ .name = "CreateTime", .value = .{ .datetime = now } },
    });
    try std.testing.expectEqual(@as(i64, 1), id1);

    _ = try table.insert(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Code", .value = .{ .text = "k2" } },
        .{ .name = "Title", .value = .{ .text = "第二条" } },
        .{ .name = "Amount", .value = .{ .decimal = try zcode.Decimal.parse("0") } },
        .{ .name = "Ok", .value = .{ .boolean = false } },
        .{ .name = "CreateTime", .value = .{ .datetime = now } },
    });

    // 计数
    try std.testing.expectEqual(@as(i64, 2), try table.count(&s, null));

    // 按主键取
    const row = (try table.findByPk(&s, &.{.{ .int = id1 }})).?;
    try std.testing.expectEqualStrings("k1", row.get("Code").?.text);
    try std.testing.expect(row.get("Ok").?.boolean);
    // 十进制：SQLite 的 `decimal` 列是 NUMERIC 亲和度，尾随零在存储层就丢了（C# 同样如此），
    // 这里断言的是**数值相等**，不是文本逐字相等。
    const amount = row.get("Amount").?.asDecimal().?;
    try std.testing.expect(amount.eql(try zcode.Decimal.parse("12.34")));
    // 时间按 7 位小数秒往返
    const dt = row.get("CreateTime").?.datetime;
    try std.testing.expectEqual(now.year, dt.year);
    try std.testing.expectEqual(now.month, dt.month);
    try std.testing.expectEqual((now.nanos / 100) * 100, (dt.nanos / 100) * 100);

    // 条件查询 + 分页（按 Status 不存在，用 Ok 条件）
    var w = zcode.Where.init(a);
    defer w.deinit();
    _ = try w.eq("Ok", .{ .boolean = true });

    var q = zcode.Query.init(a);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = try q.orderBy("Id", false);
    _ = q.page(1, 10);

    const rows = try table.queryRows(&s, &q);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("k1", rows[0].get("Code").?.text);

    // 更新
    var uw = zcode.Where.init(a);
    defer uw.deinit();
    _ = try uw.eq("Id", .{ .int = id1 });
    const affected = try table.update(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Title", .value = .{ .text = "改过" } },
    }, &uw);
    try std.testing.expectEqual(@as(usize, 1), affected);

    const row2 = (try table.findByPk(&s, &.{.{ .int = id1 }})).?;
    try std.testing.expectEqualStrings("改过", row2.get("Title").?.text);

    // 删除
    const deleted = try table.delete(&s, &uw);
    try std.testing.expectEqual(@as(usize, 1), deleted);
    try std.testing.expectEqual(@as(i64, 1), try table.count(&s, null));
}

test "二次 sync_schema 幂等，且新增列自动补齐" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "evolve");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    {
        var dal = try openDal(a, db_path);
        defer dal.deinit();
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    // 模型新增一列 → 再次同步应补列（不重建表、不动历史数据）
    const evolved_xml =
        \\<EntityModel><Tables><Table Name="JiLiYu" TableName="DH_JiLiYu">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Code" DataType="String" Length="50" Master="True" />
        \\    <Column Name="Extra" DataType="String" Length="20" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    const m2 = try zcode.EntityModel.parse(a, evolved_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);
    var dal2 = try zcode.Dal.initWithModel(a, conn, m2);
    defer dal2.deinit();

    var s2 = try dal2.openSession();
    defer s2.deinit();
    const r2 = try dal2.syncSchema(&s2);
    try std.testing.expectEqual(@as(usize, 0), r2.tables_created);
    try std.testing.expectEqual(@as(usize, 1), r2.columns_added);
}

/// 与 `zcodegen` 生成结构同构的实体（集成测试专用）。
const JiLiYu = struct {
    dirty: zcode.entity.DirtyBits = 0,
    Id: i32 = 0,
    Code: []const u8 = "",
    Title: []const u8 = "",
    Amount: zcode.Decimal = .{ .mantissa = 0, .scale = 0 },
    Ok: bool = false,
    CreateTime: zcode.DateTime = .{},

    pub const meta = zcode.entity.EntityMeta{
        .name = "JiLiYu",
        .table_name = "DH_JiLiYu",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "Code", .data_type = .string },
            .{ .name = "Title", .data_type = .string },
            .{ .name = "Amount", .data_type = .decimal },
            .{ .name = "Ok", .data_type = .boolean },
            .{ .name = "CreateTime", .data_type = .datetime },
        },
    };

    pub fn getTitle(self: @This()) []const u8 {
        return self.Title;
    }

    pub fn setTitle(self: *@This(), v: []const u8) void {
        self.Title = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }

    pub fn getAmount(self: @This()) zcode.Decimal {
        return self.Amount;
    }

    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = self.Id },
            1 => .{ .text = self.Code },
            2 => .{ .text = self.Title },
            3 => .{ .decimal = self.Amount },
            4 => .{ .boolean = self.Ok },
            5 => .{ .datetime = self.CreateTime },
            else => .{ .null = {} },
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => {
                self.Id = v.asI32() orelse 0;
            },
            1 => {
                switch (v) {
                    .text => |t| self.Code = t,
                    .null => self.Code = "",
                    else => {},
                }
            },
            2 => {
                switch (v) {
                    .text => |t| self.Title = t,
                    .null => self.Title = "",
                    else => {},
                }
            },
            3 => {
                self.Amount = v.asDecimal() orelse .{ .mantissa = 0, .scale = 0 };
            },
            4 => {
                self.Ok = v.asBool() orelse false;
            },
            5 => {
                self.CreateTime = v.asDatetime() orelse .{};
            },
            else => {},
        }
    }
};

test "对象实体：脏字段更新只写变化列，无变化不发 SQL" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "entity");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = try openDal(a, db_path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    // 插入（自增回写）
    var e = JiLiYu{};
    e.Code = "e-1";
    e.Title = "原始标题";
    e.Amount = try zcode.Decimal.parse("1.5");
    e.Ok = true;
    e.CreateTime = zcode.DateTime.nowLocal();
    const id = try zcode.entity.insert(&dal, &e, &s);
    try std.testing.expect(id > 0);
    try std.testing.expectEqual(@as(i32, @intCast(id)), e.Id);

    // 按主键取
    var loaded = (try zcode.entity.findByPk(&dal, JiLiYu, &s, &.{.{ .int = id }})).?;
    try std.testing.expectEqualStrings("原始标题", loaded.getTitle());

    // 绕过实体改 Amount，实体只脏 Title → 落库不得覆盖 Amount
    var w = zcode.Where.init(a);
    defer w.deinit();
    _ = try w.eq("Id", .{ .int = id });
    const table = try dal.table("JiLiYu");
    _ = try table.update(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Amount", .value = .{ .decimal = try zcode.Decimal.parse("9") } },
    }, &w);

    loaded.setTitle("只改标题");
    try std.testing.expectEqual(@as(usize, 1), try zcode.entity.update(&dal, &loaded, &s));
    // 无脏列 → 返回 0（不发 SQL）
    try std.testing.expectEqual(@as(usize, 0), try zcode.entity.update(&dal, &loaded, &s));

    const again = (try zcode.entity.findByPk(&dal, JiLiYu, &s, &.{.{ .int = id }})).?;
    try std.testing.expectEqualStrings("只改标题", again.getTitle());
    try std.testing.expect(again.getAmount().eql(try zcode.Decimal.parse("9")));

    // 查询与删除
    if (try zcode.entity.count(&dal, JiLiYu, &s, null) != 1) return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), try zcode.entity.delete(&dal, &again, &s));
    try std.testing.expectEqual(@as(i64, 0), try zcode.entity.count(&dal, JiLiYu, &s, null));
}

test "批量写：多行插入 / 主键批量删除 / 实体批量保存" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "batch");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = try openDal(a, db_path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const table = try dal.table("JiLiYu");

    // 1) 多行 INSERT：3 行一次写入
    var rows: std.ArrayList([]const zcode.sqlbuild.Field) = .empty;
    defer rows.deinit(a);
    for (0..3) |k| {
        const f = try ar.alloc(zcode.sqlbuild.Field, 5);
        f[0] = .{ .name = "Code", .value = .{ .text = try std.fmt.allocPrint(ar, "b-{d}", .{k}) } };
        f[1] = .{ .name = "Title", .value = .{ .text = "批量" } };
        f[2] = .{ .name = "Amount", .value = .{ .decimal = try zcode.Decimal.parse("1") } };
        f[3] = .{ .name = "Ok", .value = .{ .boolean = true } };
        f[4] = .{ .name = "CreateTime", .value = .{ .datetime = zcode.DateTime.nowLocal() } };
        try rows.append(a, f);
    }
    try std.testing.expectEqual(@as(usize, 3), try table.insertBatch(&s, rows.items));
    try std.testing.expectEqual(@as(i64, 3), try table.count(&s, null));

    // 2) 主键批量删除：先查出三个 ID
    var q = zcode.Query.init(a);
    defer q.deinit();
    const all = try table.queryRows(&s, &q);
    const ids = try ar.alloc(zcode.Value, all.len);
    for (all, 0..) |row, i| ids[i] = .{ .int = row.get("Id").?.asI64().? };
    try std.testing.expectEqual(all.len, try table.deleteByPkBatch(&s, ids));
    try std.testing.expectEqual(@as(i64, 0), try table.count(&s, null));

    // 3) 实体批量保存：2 个新增合并插入 + 1 个已有按脏列更新
    var existing = JiLiYu{};
    existing.Code = "e-existing";
    existing.Title = "旧";
    existing.Amount = try zcode.Decimal.parse("0");
    const existing_id = try zcode.entity.insert(&dal, &existing, &s);

    var e1 = JiLiYu{};
    e1.Code = "n-1";
    e1.Title = "新1";
    e1.Amount = try zcode.Decimal.parse("0");

    var e2 = JiLiYu{};
    e2.Code = "n-2";
    e2.Title = "新2";
    e2.Amount = try zcode.Decimal.parse("0");

    var e3 = (try zcode.entity.findByPk(&dal, JiLiYu, &s, &.{.{ .int = existing_id }})).?;
    e3.setTitle("改过");

    const report = try zcode.entity.saveBatch(&dal, JiLiYu, &[_]*JiLiYu{ &e1, &e2, &e3 }, &s);
    try std.testing.expectEqual(@as(usize, 2), report.inserted);
    try std.testing.expectEqual(@as(usize, 1), report.updated);
    try std.testing.expectEqual(@as(i64, 3), try table.count(&s, null));

    // 脏列已清：再保存一次只有「无变化」
    const report2 = try zcode.entity.saveBatch(&dal, JiLiYu, &[_]*JiLiYu{&e3}, &s);
    try std.testing.expectEqual(@as(usize, 1), report2.unchanged);
    try std.testing.expectEqual(@as(usize, 0), report2.updated);
}

test "整表缓存：命中 / 写后自动失效 / TTL 过期重载" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "cache");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = try openDal(a, db_path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("JiLiYu");
    _ = try table.delete(&s, null);

    // 2 行（走实体：内部经 Dal.table，同样会触发写后失效）
    var ids: [2]i32 = undefined;
    for (0..2) |k| {
        var e = JiLiYu{};
        e.Code = try std.fmt.allocPrint(s.resultAllocator(), "c-{d}", .{k});
        e.Title = "缓存";
        e.Amount = try zcode.Decimal.parse("0");
        e.Ok = true;
        e.CreateTime = zcode.DateTime.nowLocal();
        ids[k] = @intCast(try zcode.entity.insert(&dal, &e, &s));
    }

    var c = zcode.cache.Cache(JiLiYu).init(&dal, 60);
    defer c.deinit();

    // 首次访问整表装载；按主键命中
    try std.testing.expectEqual(@as(usize, 2), try c.count(&s));
    const hit = (try c.get(&s, ids[1])).?;
    try std.testing.expectEqualStrings("c-1", hit.Code);

    // 绕过 TableRef 直接写库 → 缓存立即可见？不，仍是旧快照（Blocking 语义靠写后失效，这里没有通知）
    _ = try s.execute("INSERT INTO \"DH_JiLiYu\" (\"Code\", \"Title\", \"Amount\", \"Ok\", \"CreateTime\") VALUES (?, ?, ?, ?, ?)", &.{
        .{ .text = "raw" },
        .{ .text = "raw" },
        .{ .decimal = try zcode.Decimal.parse("0") },
        .{ .boolean = true },
        .{ .datetime = zcode.DateTime.nowLocal() },
    });
    try std.testing.expectEqual(@as(usize, 2), try c.count(&s));

    // TTL 过期 → 同步重载，看到第 3 行
    c.loaded_at -= 100;
    try std.testing.expectEqual(@as(usize, 3), try c.count(&s));

    // 通过 TableRef 写入 → 自动失效 → 下次访问就是新快照
    _ = try table.insert(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Code", .value = .{ .text = "via-ref" } },
        .{ .name = "Title", .value = .{ .text = "写后失效" } },
        .{ .name = "Amount", .value = .{ .decimal = try zcode.Decimal.parse("0") } },
        .{ .name = "Ok", .value = .{ .boolean = true } },
        .{ .name = "CreateTime", .value = .{ .datetime = zcode.DateTime.nowLocal() } },
    });
    try std.testing.expectEqual(@as(usize, 4), try c.count(&s));

    // 手动失效
    c.invalidate();
    try std.testing.expectEqual(@as(usize, 4), try c.count(&s));
}

test "单对象缓存：命中 / TTL 过期回库 / 写后自动失效" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "singlecache");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = try openDal(a, db_path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("JiLiYu");
    _ = try table.delete(&s, null);

    var id: i32 = 0;
    {
        var e = JiLiYu{};
        e.Code = "sc-1";
        e.Title = "原始";
        e.Amount = try zcode.Decimal.parse("0");
        e.Ok = true;
        e.CreateTime = zcode.DateTime.nowLocal();
        id = @intCast(try zcode.entity.insert(&dal, &e, &s));
    }

    var c = zcode.cache.SingleCache(JiLiYu).init(&dal, 60);
    defer c.deinit();

    const v1 = (try c.get(&s, id)).?;
    try std.testing.expectEqualStrings("原始", v1.Title);
    try std.testing.expectEqual(@as(usize, 1), c.cachedCount());

    // 绕过 TableRef 直接改库：缓存仍返回旧值（说明没有每次回库）
    _ = try s.execute("UPDATE \"DH_JiLiYu\" SET \"Title\" = ? WHERE \"Id\" = ?", &.{
        .{ .text = "直改" },
        .{ .int = id },
    });
    const v2 = (try c.get(&s, id)).?;
    try std.testing.expectEqualStrings("原始", v2.Title);

    // TTL 过期 → 回库拿到新值
    c.entries.getPtr(id).?.loaded_at -= 100;
    const v3 = (try c.get(&s, id)).?;
    try std.testing.expectEqualStrings("直改", v3.Title);

    // 通过 TableRef 写入 → 自动失效（条目被清空）
    var w = zcode.Where.init(a);
    defer w.deinit();
    _ = try w.eq("Id", .{ .int = id });
    _ = try table.update(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Title", .value = .{ .text = "写后失效" } },
    }, &w);
    try std.testing.expectEqual(@as(usize, 0), c.cachedCount());

    const v4 = (try c.get(&s, id)).?;
    try std.testing.expectEqualStrings("写后失效", v4.Title);
}

// 生产模型回归：固件来自 C# 仓库 `DH.NCode/DH.NCode/Model.xml`（9 张表、200 列、7 种数据类型）。// 只做「解析 + 方言 DDL 生成 + 往返」——**不连库**，所以任何机器都能跑。
test "生产模型回归：DH.NCode 内置 Model.xml 可解析并生成 SQLite 建表 SQL" {
    const a = std.testing.allocator;

    var m = try zcode.EntityModel.load(a, "tests/fixtures/dh-ncode-model.xml");
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 9), m.tables.len);
    try std.testing.expect(m.options.connName() != null);

    var total_columns: usize = 0;
    var index_statements: usize = 0;

    for (m.tables) |*t| {
        try std.testing.expect(t.columns.len > 0);
        total_columns += t.columns.len;

        // XCode 模型约定：每张表至少一个主键
        const pks = try t.primaryKeys(a);
        defer a.free(pks);
        try std.testing.expect(pks.len > 0);

        const stmts = try zcode.dialect.DatabaseKind.sqlite.createTableAlloc(a, t);
        defer {
            for (stmts) |stmt| a.free(stmt);
            a.free(stmts);
        }
        try std.testing.expect(stmts.len >= 1);
        try std.testing.expect(std.mem.startsWith(u8, stmts[0], "CREATE TABLE "));
        // 非自增主键应生成表级 PRIMARY KEY
        if (t.identity() == null) {
            try std.testing.expect(std.mem.indexOf(u8, stmts[0], "PRIMARY KEY (") != null);
        }
        for (stmts) |stmt| {
            if (std.mem.startsWith(u8, stmt, "CREATE INDEX ") or std.mem.startsWith(u8, stmt, "CREATE UNIQUE INDEX ")) {
                index_statements += 1;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 200), total_columns);
    try std.testing.expect(index_statements > 0);

    // 解析 → 写出 → 再解析：表/列/索引数量一致（未识别属性不丢）
    const xml = try m.toXmlAlloc(a);
    defer a.free(xml);
    var m2 = try zcode.EntityModel.parse(a, xml);
    defer m2.deinit();

    try std.testing.expectEqual(m.tables.len, m2.tables.len);
    for (m.tables, 0..) |t, i| {
        const t2 = &m2.tables[i];
        try std.testing.expectEqualStrings(t.name, t2.name);
        try std.testing.expectEqualStrings(t.effectiveTableName(), t2.effectiveTableName());
        try std.testing.expectEqual(t.columns.len, t2.columns.len);
        try std.testing.expectEqual(t.indexes.len, t2.indexes.len);
    }
}

// ── MySQL ───────────────────────────────────────────────────────────────────

test "MySQL 连接串解析：Server/Port/Database/Uid/Pwd（不连库）" {
    const a = std.testing.allocator;
    var o = try zcode.parseConnectionString(a, "Provider=MySQL;Server=127.0.0.1;Port=3307;Database=zcode;Uid=root;Pwd=secret;Migration=On");
    defer o.deinit(a);

    try std.testing.expectEqual(zcode.DatabaseKind.mysql, o.provider);
    try std.testing.expectEqualStrings("127.0.0.1", o.server);
    try std.testing.expectEqual(@as(u16, 3307), o.port);
    try std.testing.expectEqualStrings("zcode", o.database);
    try std.testing.expectEqualStrings("root", o.user);
    try std.testing.expectEqualStrings("secret", o.password);
    try std.testing.expectEqual(zcode.Migration.on, o.migration.?);

    // 别名键（Host/User/Password）也要认
    var o2 = try zcode.parseConnectionString(a, "Provider=MySQL;Host=db.local;User=u;Password=p;DataBase=mes");
    defer o2.deinit(a);
    try std.testing.expectEqualStrings("db.local", o2.server);
    try std.testing.expectEqualStrings("u", o2.user);
    try std.testing.expectEqualStrings("p", o2.password);
    try std.testing.expectEqualStrings("mes", o2.database);
    try std.testing.expectEqual(@as(u16, 3306), o2.port); // 未给 Port 用默认
}

// MySQL 真库端到端：需 `zig build integration -Dmysql-conn="Server=...;Database=...;Uid=...;Pwd=..."`。
// 没给连接串时**显式 SKIP**（打印原因），绝不静默当成通过。
test "MySQL 真库：建表 → CRUD → 分页（需 -Dmysql-conn）" {
    const conn_str = build_options.mysql_conn;
    if (conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-conn，跳过 MySQL 真库集成测试\n", .{});
        return;
    }

    const a = std.testing.allocator;
    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = zcode.Dal.initWithModel(a, conn_str, m) catch |e| {
        std.debug.print("[FAIL] 连接 MySQL 失败：{s}\n", .{@errorName(e)});
        return e;
    };
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    // 幂等：先清掉旧表，保证从零建表也走一遍
    _ = s.execute("DROP TABLE IF EXISTS `DH_JiLiYu`", &.{}) catch |e| {
        std.debug.print("[FAIL] 清理旧表失败：{s}（{s}）\n", .{ @errorName(e), s.lastError() });
        return e;
    };

    const report = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 1), report.tables_created);
    try std.testing.expectEqual(@as(usize, 0), report.columns_added);

    const table = try dal.table("JiLiYu");

    var id: i32 = 0;
    {
        var e = JiLiYu{};
        e.Code = "my-1";
        e.Title = "MySQL 原始";
        e.Amount = try zcode.Decimal.parse("12.3400");
        e.Ok = true;
        e.CreateTime = zcode.DateTime.nowLocal();
        id = @intCast(try zcode.entity.insert(&dal, &e, &s));
        try std.testing.expect(id > 0);
    }

    const found = (try table.findByPk(&s, &.{.{ .int = id }})).?;
    try std.testing.expectEqualStrings("MySQL 原始", found.get("Title").?.text);

    var w = zcode.Where.init(a);
    defer w.deinit();
    _ = try w.eq("Id", .{ .int = id });
    const n = try table.update(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Title", .value = .{ .text = "MySQL 改过" } },
    }, &w);
    try std.testing.expectEqual(@as(usize, 1), n);

    const total = try table.count(&s, null);
    try std.testing.expect(total >= 1);

    try std.testing.expectEqual(@as(usize, 1), try table.delete(&s, &w));
    _ = s.execute("DROP TABLE IF EXISTS `DH_JiLiYu`", &.{}) catch {};
}

// ── 事务 ───────────────────────────────────────────────────────────────────
fn insertOne(dal: *zcode.Dal, s: *zcode.session.Session, code: []const u8) !i64 {
    var e = JiLiYu{};
    e.Code = code;
    e.Title = "tx";
    e.Amount = try zcode.Decimal.parse("1");
    e.Ok = true;
    e.CreateTime = zcode.DateTime.nowLocal();
    return try zcode.entity.insert(dal, &e, s);
}

test "事务：提交 / 回滚 / 嵌套计数（对齐 C# Transaction 语义）" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "tx");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = openDal(a, db_path) catch |e| {
        std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("JiLiYu");
    _ = try table.delete(&s, null);

    // 1) 回滚：插入不落库
    try std.testing.expectEqual(@as(u32, 1), try s.beginTransaction(.default));
    _ = try insertOne(&dal, &s, "tx-rb");
    try std.testing.expectEqual(@as(u32, 0), try s.rollback(false));
    try std.testing.expect(!s.inTransaction());
    try std.testing.expectEqual(@as(i64, 0), try table.count(&s, null));

    // 2) 提交：落库
    try std.testing.expectEqual(@as(u32, 1), try s.beginTransaction(.default));
    _ = try insertOne(&dal, &s, "tx-ok");
    try std.testing.expectEqual(@as(u32, 0), try s.commit());
    try std.testing.expectEqual(@as(i64, 1), try table.count(&s, null));

    // 3) 嵌套计数：内层 rollback 只减计数（不回滚），外层 commit 才真正提交
    //    —— 与 C# `Transaction.Rollback()` 的计数语义一致
    try std.testing.expectEqual(@as(u32, 1), try s.beginTransaction(.default));
    try std.testing.expectEqual(@as(u32, 2), try s.beginTransaction(.default));
    _ = try insertOne(&dal, &s, "tx-nested");
    try std.testing.expectEqual(@as(u32, 1), try s.rollback(false));
    try std.testing.expectEqual(@as(u32, 0), try s.commit());
    try std.testing.expectEqual(@as(i64, 2), try table.count(&s, null));

    // 4) 不在事务里提交 → 明确报错（不静默成功）
    try std.testing.expectError(error.NoTransaction, s.commit());
    try std.testing.expectError(error.NoTransaction, s.rollback(false));
}

test "事务：Scoped 未提交自动回滚（对应 EntityTransaction 的 Dispose 语义）" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "tx-scope");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = openDal(a, db_path) catch |e| {
        std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const table = try dal.table("JiLiYu");
    _ = try table.delete(&s, null);

    {
        var tx = try zcode.ScopedTransaction.begin(&s);
        defer tx.deinit();
        _ = try insertOne(&dal, &s, "scope-rb");
        // 故意不 commit
    }
    try std.testing.expectEqual(@as(i64, 0), try table.count(&s, null));

    {
        var tx = try zcode.ScopedTransaction.begin(&s);
        defer tx.deinit();
        _ = try insertOne(&dal, &s, "scope-ok");
        try tx.commit();
    }
    try std.testing.expectEqual(@as(i64, 1), try table.count(&s, null));
}

// MySQL 真库：BIT 列在文本协议下的字节序。
// 口径分歧：C# 绿色版 `DH.MySql` 按小端还原，Rust `Pek.RCode` 按大端；
// 这里用真实服务器一次定死（b16 存 0x0102：大端读到 258，小端读到 513）。
test "MySQL 真库：BIT 列字节序（需 -Dmysql-conn）" {
    const conn_str = build_options.mysql_conn;
    if (conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-conn，跳过 BIT 字节序用例\n", .{});
        return;
    }

    const a = std.testing.allocator;
    var dal = try zcode.Dal.initWithModel(a, conn_str, try zcode.EntityModel.parse(a, model_xml));
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    _ = try s.execute("DROP TABLE IF EXISTS bit_probe", &.{});
    _ = try s.execute("CREATE TABLE bit_probe (id INT PRIMARY KEY, b8 BIT(8), b16 BIT(16)) ENGINE=InnoDB", &.{});
    _ = try s.execute("INSERT INTO bit_probe VALUES (1, b'10000001', b'0000000100000010')", &.{});

    const rows = try s.queryRows("SELECT b8, b16 FROM bit_probe WHERE id = 1", &.{});
    defer _ = s.execute("DROP TABLE IF EXISTS bit_probe", &.{}) catch {};

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    const b8 = rows[0].get("b8").?.asI64().?;
    const b16 = rows[0].get("b16").?.asI64().?;
    std.debug.print("[BIT] 真库读回：b8={d}（期望 129） b16={d}（期望 258）\n", .{ b8, b16 });
    try std.testing.expectEqual(@as(i64, 129), b8);
    // 实测结论：MySQL 线上为大端（存 0x0102 → 字节 [0x01,0x02] → 258）
    try std.testing.expectEqual(@as(i64, 258), b16);
}

// ── 反向工程（DB → Model.xml）──────────────────────────────────────────────

test "反向工程：SQLite 建表 → 反查 → Model.xml 可再解析" {
    const a = std.testing.allocator;

    const db_path = try tempDbPath(a, "reverse");
    defer a.free(db_path);
    defer zcode.File.DeleteQuiet(db_path);

    var dal = openDal(a, db_path) catch |e| {
        std.debug.print("[SKIP] SQLite 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const xml = try zcode.reverse.modelXmlAlloc(a, &s, .{ .namespace = "Test.Entity", .conn_name = "DH" });
    defer a.free(xml);

    var m2 = try zcode.EntityModel.parse(a, xml);
    defer m2.deinit();

    try std.testing.expectEqual(@as(usize, 1), m2.tables.len);
    const t = &m2.tables[0];
    try std.testing.expectEqualStrings("DH_JiLiYu", t.effectiveTableName());
    try std.testing.expectEqual(@as(usize, 6), t.columns.len);

    const id = t.column("Id").?;
    try std.testing.expect(id.primary_key);
    try std.testing.expect(id.identity); // INTEGER PRIMARY KEY 视为自增
    try std.testing.expectEqual(zcode.DataType.int32, id.data_type);

    try std.testing.expectEqual(zcode.DataType.string, t.column("Title").?.data_type);
    try std.testing.expectEqual(zcode.DataType.decimal, t.column("Amount").?.data_type);
    try std.testing.expectEqual(zcode.DataType.datetime, t.column("CreateTime").?.data_type);

    // 模型里声明了 2 个索引（Code 唯一 + CreateTime）
    try std.testing.expectEqual(@as(usize, 2), t.indexes.len);
    var unique_count: usize = 0;
    for (t.indexes) |idx| {
        if (idx.unique) unique_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), unique_count);
}

test "MySQL 真库：反向工程 → Model.xml（需 -Dmysql-conn）" {
    const conn_str = build_options.mysql_conn;
    if (conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-conn，跳过反向工程用例\n", .{});
        return;
    }

    const a = std.testing.allocator;
    var dal = try zcode.Dal.initWithModel(a, conn_str, try zcode.EntityModel.parse(a, model_xml));
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    _ = try s.execute("DROP TABLE IF EXISTS `DH_JiLiYu`", &.{});
    _ = try dal.syncSchema(&s);
    defer _ = s.execute("DROP TABLE IF EXISTS `DH_JiLiYu`", &.{}) catch {};

    const xml = try zcode.reverse.modelXmlAlloc(a, &s, .{ .namespace = "Test.Entity" });
    defer a.free(xml);

    var m2 = try zcode.EntityModel.parse(a, xml);
    defer m2.deinit();

    const t = m2.table("DH_JiLiYu") orelse {
        std.debug.print("[FAIL] 反查结果里没有 DH_JiLiYu；生成内容：\n{s}\n", .{xml});
        return error.TableNotFound;
    };
    try std.testing.expectEqual(@as(usize, 6), t.columns.len);
    const id = t.column("Id").?;
    try std.testing.expect(id.primary_key);
    try std.testing.expect(id.identity);
    try std.testing.expectEqual(zcode.DataType.string, t.column("Title").?.data_type);
    try std.testing.expectEqual(zcode.DataType.decimal, t.column("Amount").?.data_type);
    // MySQL 的 PRIMARY 索引不应作为普通索引重复输出
    for (t.indexes) |idx| {
        if (idx.name) |n| try std.testing.expect(!std.ascii.eqlIgnoreCase(n, "PRIMARY"));
        if (idx.columns.len == 1) try std.testing.expect(!std.mem.eql(u8, idx.columns[0], "Id"));
    }
}

// 新增能力的集成用例（分表 / 读写分离 / 连接池 / 拦截器 / Migration Full）
test {
    _ = @import("integration_features.zig");
}

// PostgreSQL 接线用例（协议层由 zzig 回环假服务端覆盖）
test {
    _ = @import("integration_pg.zig");
}

// PostgreSQL **真库**用例（需 -Dpg-conn；覆盖建表/CRUD/批量插/反向工程/scram）
test {
    _ = @import("integration_pg_real.zig");
}

// 跨库分片 + 分片表自动建表
test {
    _ = @import("integration_shard.zig");
}

// MySQL LOAD DATA LOCAL INFILE 批量装载（需 -Dmysql-conn）
test {
    _ = @import("integration_mysql_bulk.zig");
}

// MySQL TLS（SslMode=Required/None/VerifyCA/VerifyFull，需 -Dmysql-conn，可选 -Dmysql-ca）
test {
    _ = @import("integration_mysql_tls.zig");
}

// MySQL 压缩协议（Compression=True，需 -Dmysql-conn）
test {
    _ = @import("integration_mysql_compress.zig");
}

// 数据库远程服务（真 socket + 真 SQLite，无需外部实例）
test {
    _ = @import("integration_dbservice.zig");
}

// SQL Server 接线（连接串 + 假 TDS 服务端上的建表链路；协议层见 zzig 回环用例）
test {
    _ = @import("integration_tsql.zig");
}

// 统计累加 + 数据抽取器（真 SQLite）
test {
    _ = @import("integration_stat_extract.zig");
    _ = @import("integration_batch_async.zig");
    _ = @import("integration_shard_batch.zig");
    _ = @import("integration_sql_log.zig");
    _ = @import("integration_membership_orm.zig");
    _ = @import("integration_area.zig");
    _ = @import("integration_dirty_batch.zig");
    _ = @import("integration_cache_limit.zig");
}
