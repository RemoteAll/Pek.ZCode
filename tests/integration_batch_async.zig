//! 集成测试（第三批）：批量写模式（SaveModes）/ 延迟队列后台凑批 / 异步保存。
//!
//! 全部用**真 SQLite**（临时库文件），验证「SQL 真的执行、数据真的落库」。

const std = @import("std");
const zcode = @import("zcode");
const zzig = @import("zzig");

const Field = zcode.sqlbuild.Field;

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
    \\  <Option><Namespace>Test.Batch</Namespace><ConnName>DH</ConnName></Option>
    \\  <Tables>
    \\    <Table Name="Item" TableName="BH_Item">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Code" DataType="String" Length="50" />
    \\        <Column Name="Name" DataType="String" Length="50" />
    \\      </Columns>
    \\      <Indexes><Index Unique="True" Columns="Code" /></Indexes>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

const Item = struct {
    dirty: zcode.entity.DirtyBits = 0,
    Id: i32 = 0,
    Code: []const u8 = "",
    Name: []const u8 = "",

    pub const meta = zcode.entity.EntityMeta{
        .name = "Item",
        .table_name = "BH_Item",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "Code", .data_type = .string },
            .{ .name = "Name", .data_type = .string },
        },
    };

    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = self.Id },
            1 => .{ .text = self.Code },
            2 => .{ .text = self.Name },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => self.Id = @intCast(v.asI64() orelse 0),
            1 => self.Code = if (v == .text) v.text else "",
            2 => self.Name = if (v == .text) v.text else "",
            else => {},
        }
    }
};

fn tempDbPath(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    return zcode.File.UniqueTempName(a, tag, ".db");
}

fn openDal(a: std.mem.Allocator, db_path: []const u8) !zcode.Dal {
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);
    return zcode.Dal.initWithModel(a, conn, m);
}

/// 填一行（物理列名，`upsertBatch` 的口径）
fn mk(out: *[2]Field, code: []const u8, name: []const u8) []const Field {
    out[0] = .{ .name = "Code", .value = .{ .text = code } };
    out[1] = .{ .name = "Name", .value = .{ .text = name } };
    return out;
}

/// 按 Code 查 Name（找不到返回 null）
fn nameOf(a: std.mem.Allocator, t: *const zcode.dbtable.TableRef, s: *zcode.Session, code: []const u8) !?[]const u8 {
    var w = zcode.Where.init(a);
    defer w.deinit();
    _ = try w.eq("Code", .{ .text = code });

    var q = zcode.Query.init(a);
    defer q.deinit();
    _ = q.filterWhere(&w);

    const rows = try t.queryRows(s, &q);
    if (rows.len == 0) return null;
    const v = rows[0].get("Name") orelse return null;
    return if (v == .text) v.text else null;
}

fn sleepMs(ms: u64) void {
    zzig.compat.sleep(ms * std.time.ns_per_ms);
}

// ───────────────────────── SaveModes 批量写 ─────────────────────────

test "批量写：insert / upsert / insert_ignore / replace 四种模式真的落库" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "batchmode");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const t = try dal.table("Item");

    // 1) 首次插入两行
    var r1: [2]Field = undefined;
    var r2: [2]Field = undefined;
    const first = [_][]const Field{ mk(&r1, "A", "甲"), mk(&r2, "B", "乙") };
    try std.testing.expectEqual(@as(usize, 2), try t.insertBatch(&s, &first));
    try std.testing.expectEqual(@as(i64, 2), try t.count(&s, null));

    // 2) upsert：唯一索引冲突时更新 Name
    var r3: [2]Field = undefined;
    var r4: [2]Field = undefined;
    const upd = [_][]const Field{ mk(&r3, "A", "甲改"), mk(&r4, "C", "丙") };
    _ = try t.upsertBatch(&s, &upd, .upsert);
    try std.testing.expectEqual(@as(i64, 3), try t.count(&s, null));
    try std.testing.expectEqualStrings("甲改", (try nameOf(a, &t, &s, "A")).?);

    // 3) insert_ignore：同 Code 不覆盖、新 Code 插入
    var r5: [2]Field = undefined;
    var r6: [2]Field = undefined;
    const ign = [_][]const Field{ mk(&r5, "A", "不该生效"), mk(&r6, "D", "丁") };
    _ = try t.upsertBatch(&s, &ign, .insert_ignore);
    try std.testing.expectEqual(@as(i64, 4), try t.count(&s, null));
    try std.testing.expectEqualStrings("甲改", (try nameOf(a, &t, &s, "A")).?);

    // 4) replace：整行替换（SQLite `INSERT OR REPLACE`）
    var r7: [2]Field = undefined;
    const rep = [_][]const Field{mk(&r7, "A", "甲再改")};
    _ = try t.upsertBatch(&s, &rep, .replace);
    try std.testing.expectEqualStrings("甲再改", (try nameOf(a, &t, &s, "A")).?);
}

test "批量写：upsert 在无主键表上明确报错，不静默降级" {
    const a = std.testing.allocator;
    const no_pk_xml =
        \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
        \\  <Option><ConnName>DH</ConnName></Option>
        \\  <Tables><Table Name="Npk" TableName="BH_Npk"><Columns>
        \\    <Column Name="Code" DataType="String" Length="20" />
        \\  </Columns></Table></Tables>
        \\</EntityModel>
    ;
    const path = try tempDbPath(a, "nopk");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    const m = try zcode.EntityModel.parse(a, no_pk_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{path});
    defer a.free(conn);
    var dal = try zcode.Dal.initWithModel(a, conn, m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    const t = try dal.table("Npk");
    const one = [_]Field{.{ .name = "Code", .value = .{ .text = "x" } }};
    const rows = [_][]const Field{&one};
    try std.testing.expectError(error.NoPrimaryKey, t.upsertBatch(&s, &rows, .upsert));
}

// ───────────────────────── 延迟队列：后台自动凑批 ─────────────────────────

test "延迟队列：后台线程自动凑批写库（start/stop）" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "queuebg");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var q = zcode.entity_queue.Queue(Item).init(a, &dal, .{
        .max_count = 0,
        .max_latency_ms = 0,
        .period_ms = 30,
    });
    defer q.deinit();

    var item1 = Item{ .Code = "Q1", .Name = "一" };
    var item2 = Item{ .Code = "Q2", .Name = "二" };
    try q.addDelayed(&item1, 0);
    try q.addDelayed(&item2, 0);
    try std.testing.expectEqual(@as(usize, 2), q.pending());

    try q.start();

    const t = try dal.table("Item");
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        if (try t.count(&s, null) == 2) break;
        sleepMs(10);
    }
    q.stop();

    try std.testing.expectEqual(@as(i64, 2), try t.count(&s, null));
    try std.testing.expectEqual(@as(usize, 0), q.pending());
    try std.testing.expect(q.flush_count >= 1);
    try std.testing.expectEqual(@as(usize, 2), q.total_flushed);
}

test "延迟队列：未到期不写，到期才写" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "queuedelay");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    var q = zcode.entity_queue.Queue(Item).init(a, &dal, .{ .max_count = 0, .max_latency_ms = 0, .period_ms = 20 });
    defer q.deinit();

    var it = Item{ .Code = "L1", .Name = "晚" };
    try q.addDelayed(&it, 150);
    try q.start();

    const t = try dal.table("Item");
    sleepMs(50);
    try std.testing.expectEqual(@as(i64, 0), try t.count(&s, null));
    try std.testing.expectEqual(@as(usize, 1), q.pending());

    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        if (try t.count(&s, null) == 1) break;
        sleepMs(10);
    }
    q.stop();
    try std.testing.expectEqual(@as(i64, 1), try t.count(&s, null));
}

// ───────────────────────── 异步保存 ─────────────────────────

test "异步保存（凑批）：saveAsync 入队，后台按表合并成多行 INSERT" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "asyncsave");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);
    defer zcode.entity_queue.stopGlobal();

    // 三条一起入队：应合并成一条多行 INSERT（不是三次往返）
    var it1 = Item{ .Code = "AS1", .Name = "一" };
    var it2 = Item{ .Code = "AS2", .Name = "二" };
    var it3 = Item{ .Code = "AS3", .Name = "三" };
    try zcode.entity.saveAsync(std.heap.page_allocator, &dal, &it1, 0);
    try zcode.entity.saveAsync(std.heap.page_allocator, &dal, &it2, 0);
    try zcode.entity.saveAsync(std.heap.page_allocator, &dal, &it3, 0);

    // 手动触发一次 flush（等价于定时器 tick），验「一次凑批写三条」
    try zcode.entity_queue.flushGlobal();

    const t = try dal.table("Item");
    try std.testing.expectEqual(@as(i64, 3), try t.count(&s, null));
}

// ───────────────────────── 累加字段（Additional） ─────────────────────────

test "累加字段：实体保存走 col = col + ?，两次累加得到 3" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "accum");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    const accum_model =
        \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
        \\  <Option><ConnName>DH</ConnName></Option>
        \\  <Tables><Table Name="Cnt" TableName="BH_Cnt"><Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Code" DataType="String" Length="20" />
        \\    <Column Name="Hits" DataType="Int32" Additional="True" />
        \\  </Columns></Table></Tables>
        \\</EntityModel>
    ;

    const Cnt = struct {
        dirty: zcode.entity.DirtyBits = 0,
        Id: i32 = 0,
        Code: []const u8 = "",
        Hits: i32 = 0,

        pub const meta = zcode.entity.EntityMeta{
            .name = "Cnt",
            .table_name = "BH_Cnt",
            .fields = &.{
                .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
                .{ .name = "Code", .data_type = .string },
                .{ .name = "Hits", .data_type = .int32, .additional = true },
            },
        };

        pub fn columnValue(self: @This(), i: usize) zcode.Value {
            return switch (i) {
                0 => .{ .int = self.Id },
                1 => .{ .text = self.Code },
                2 => .{ .int = self.Hits },
                else => .null,
            };
        }

        pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
            switch (i) {
                0 => self.Id = @intCast(v.asI64() orelse 0),
                1 => self.Code = if (v == .text) v.text else "",
                2 => self.Hits = @intCast(v.asI64() orelse 0),
                else => {},
            }
        }
    };

    const m = try zcode.EntityModel.parse(a, accum_model);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{path});
    defer a.free(conn);
    var dal = try zcode.Dal.initWithModel(a, conn, m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    // 先插入一行 Hits=1
    var row1 = Cnt{ .Code = "k", .Hits = 1 };
    _ = try zcode.entity.insert(&dal, &row1, &s);

    // 累加 2：应变成 3（不是被覆盖成 2）
    var upd = Cnt{ .Id = row1.Id, .Hits = 2 };
    zcode.entity.markDirty(&upd.dirty, 2);
    _ = try zcode.entity.update(&dal, &upd, &s);

    const got = (try zcode.entity.findByPk(&dal, Cnt, &s, &.{.{ .int = row1.Id }})).?;
    try std.testing.expectEqual(@as(i32, 3), got.Hits);
}

// ───────────────────────── 直执行 SQL（方言占位符） ─────────────────────────

test "Dal 直执行 SQL：`?` 占位符自动适配方言，参数走绑定" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "rawsql");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    var dal = try openDal(a, path);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    _ = try dal.syncSchema(&s);

    // 直插一行
    _ = try dal.exec("Insert Into BH_Item (Code, Name) Values (?, ?)", &.{
        .{ .text = "R1" },
        .{ .text = "直写" },
    });

    // 直查（返回深拷贝：行结构 + 列名 + 文本字节都要按 `freeRows` 释放）
    const rows = try dal.queryAlloc(a, "Select Name From BH_Item Where Code = ?", &.{.{ .text = "R1" }});
    defer zcode.session.freeRows(a, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("直写", rows[0].at(0).?.text);

    // 按表归属的连接执行（这里与主连接一致）
    const n = try dal.execOnTable("Item", "Update BH_Item Set Name = ? Where Code = ?", &.{
        .{ .text = "改过" },
        .{ .text = "R1" },
    });
    try std.testing.expectEqual(@as(usize, 1), n);
}

// ───────────────────────── 多表事务 / 跨库事务守卫 ─────────────────────────

test "多表事务：同库两张表在同一事务内提交与回滚" {
    const a = std.testing.allocator;
    const path = try tempDbPath(a, "tx");
    defer a.free(path);
    defer zcode.File.DeleteQuiet(path);

    const tx_model =
        \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
        \\  <Option><ConnName>DH</ConnName></Option>
        \\  <Tables>
        \\    <Table Name="A" TableName="BH_A"><Columns>
        \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\      <Column Name="Name" DataType="String" Length="20" />
        \\    </Columns></Table>
        \\    <Table Name="B" TableName="BH_B"><Columns>
        \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\      <Column Name="Name" DataType="String" Length="20" />
        \\    </Columns></Table>
        \\  </Tables>
        \\</EntityModel>
    ;

    const m = try zcode.EntityModel.parse(a, tx_model);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{path});
    defer a.free(conn);
    var dal = try zcode.Dal.initWithModel(a, conn, m);
    defer dal.deinit();
    {
        var s0 = try dal.openSession();
        defer s0.deinit();
        _ = try dal.syncSchema(&s0);
    }

    // 同库两表 → 允许；一次提交都生效
    {
        var s = try dal.openSession();
        defer s.deinit();
        try dal.beginTransactionForTables(&s, &.{ "A", "B" });
        _ = try dal.execIn(&s, "Insert Into BH_A (Name) Values (?)", &.{.{ .text = "a1" }});
        _ = try dal.execIn(&s, "Insert Into BH_B (Name) Values (?)", &.{.{ .text = "b1" }});
        _ = try s.commit();
    }
    {
        var s = try dal.openSession();
        defer s.deinit();
        try std.testing.expectEqual(@as(i64, 1), try (try dal.table("A")).count(&s, null));
        try std.testing.expectEqual(@as(i64, 1), try (try dal.table("B")).count(&s, null));
    }

    // 回滚：两张表都不应留下数据
    {
        var s = try dal.openSession();
        defer s.deinit();
        try dal.beginTransactionForTables(&s, &.{ "A", "B" });
        _ = try dal.execIn(&s, "Insert Into BH_A (Name) Values (?)", &.{.{ .text = "a2" }});
        _ = try dal.execIn(&s, "Insert Into BH_B (Name) Values (?)", &.{.{ .text = "b2" }});
        _ = try s.rollback(false);
    }
    {
        var s = try dal.openSession();
        defer s.deinit();
        try std.testing.expectEqual(@as(i64, 1), try (try dal.table("A")).count(&s, null));
        try std.testing.expectEqual(@as(i64, 1), try (try dal.table("B")).count(&s, null));
    }
}

test "跨库多表事务：明确报错（不静默拆成两个事务，也不假装自动分库）" {
    const a = std.testing.allocator;
    const p1 = try tempDbPath(a, "txc1");
    defer a.free(p1);
    defer zcode.File.DeleteQuiet(p1);
    const p2 = try tempDbPath(a, "txc2");
    defer a.free(p2);
    defer zcode.File.DeleteQuiet(p2);

    const cross_model =
        \\<EntityModel xmlns="https://newlifex.com/Model202509.xsd">
        \\  <Option><ConnName>DH</ConnName></Option>
        \\  <Tables>
        \\    <Table Name="A" TableName="BH_A"><Columns>
        \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    </Columns></Table>
        \\    <Table Name="L" TableName="BH_L" ConnName="Log"><Columns>
        \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    </Columns></Table>
        \\  </Tables>
        \\</EntityModel>
    ;

    const m = try zcode.EntityModel.parse(a, cross_model);
    const conn1 = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{p1});
    defer a.free(conn1);
    const conn2 = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{p2});
    defer a.free(conn2);
    var dal = try zcode.Dal.initWithModel(a, conn1, m);
    defer dal.deinit();
    try dal.attachConnection("Log", conn2);

    // 同一连接 → 通过
    const same = try dal.connectionOfTables(&.{"A"});
    try std.testing.expectEqualStrings("DH", same);

    // 跨连接 → CrossDatabaseTransaction
    try std.testing.expectError(error.CrossDatabaseTransaction, dal.connectionOfTables(&.{ "A", "L" }));
    var s2 = try dal.openSession();
    defer s2.deinit();
    try std.testing.expectError(error.CrossDatabaseTransaction, dal.beginTransactionForTables(&s2, &.{ "A", "L" }));
}
