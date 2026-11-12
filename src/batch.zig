//! 批量查找器与批操作选项（对应 DH.NCode `Model/BatchFinder.cs` + `Model/BatchOption.cs`）。
//!
//! ## `BatchFinder`
//! 场景：拿到一批主键（如「用户 Id 列表」），随后逐个使用；如果每个都单独 `findByPk`，
//! 就是 N 次往返（N+1 问题）。`BatchFinder` 先登记全部主键，第一次未命中时按 `batch_size`
//! 分批 `WHERE 主键 IN (...)` 预取——**只往后扫、不回头**，与 C# 完全同口径：
//!
//! - `add` 会**跳过** `0` / 空串（C# 里 `Int32 0`、`Int64 0`、空字符串都丢），并按键去重；
//! - `find` 先查本地缓存；键不在登记集合里报 `error.NotInKeys`（C# 抛 `ArgumentOutOfRangeException`）；
//! - 扫描游标 `index` 只在「本批没找到」时前进，找到即返回，后续同批命中走缓存；
//! - `loader` 可替换批次加载逻辑（C# 的 `Callback`）。
//!
//! 行数据深拷贝进自己的 arena（会话结果集随时 `resetResults`），所以 `find` 返回的 `Row`
//! 在 `deinit` 之前一直有效。
//!
//! ## `BatchOption`
//! 批操作（Insert / Update / Upsert）的可选参数：列集合、要更新的列、要累加的列、是否全字段插入、批大小。
//! Zig 侧目前只作为**参数载体**（`insertBatch` / `saveBatch` 由调用方按需读取），
//! 与 C# 一致使用**属性名**而非列名。

const std = @import("std");
const Value = @import("zzig").db.Value;
const Row = @import("session.zig").Row;
const Session = @import("session.zig").Session;
const dbtable = @import("dbtable.zig");
const TableRef = dbtable.TableRef;
const Query = @import("query.zig").Query;
const Where = @import("query.zig").Where;

/// 批操作选项（对应 C# `Model/BatchOption.cs`）。
pub const BatchOption = struct {
    /// 列集合（属性名）；空 = 使用全部列
    columns: []const []const u8 = &.{},
    /// 要更新的列（Update / Upsert 用）；空 = 脏数据
    update_columns: []const []const u8 = &.{},
    /// 要累加更新的列（Update / Upsert 用）
    add_columns: []const []const u8 = &.{},
    /// 是否插入全部字段（Insert / Upsert）；false = 只插有脏数据的字段
    full_insert: bool = false,
    /// 分批大小；0 = 用连接设置或全局 `Setting.batch_size`
    batch_size: usize = 0,

    pub const empty: BatchOption = .{};
};

/// 自定义批量加载回调（C# `BatchFinder.Callback`）。
pub const BatchLoader = *const fn (
    ctx: *anyopaque,
    s: *Session,
    keys: []const Value,
) anyerror![]Row;

/// 实体对象批量查找器。
pub const BatchFinder = struct {
    gpa: std.mem.Allocator,
    table: TableRef,
    /// 唯一键列（物理列名）
    key_column: []const u8,
    /// 批大小，默认 500（与 C# 一致）
    batch_size: usize = 500,

    /// 登记的主键（去重后，保持登记顺序）
    keys: std.ArrayListUnmanaged(Value) = .empty,
    /// 已扫描到的位置（只前进）
    index: usize = 0,

    arena: std.heap.ArenaAllocator,
    /// `seen` 的键文本（独立 arena：`resetCache` 不能把它们回收掉）
    key_arena: std.heap.ArenaAllocator,
    /// 键文本 → 行
    cache: std.StringHashMapUnmanaged(Row) = .empty,
    /// 已加载的键（去重，避免重复登记）
    seen: std.StringHashMapUnmanaged(void) = .empty,

    /// 自定义批次加载（`null` = 内置 `IN` 查询）
    loader: ?BatchLoader = null,
    loader_ctx: ?*anyopaque = null,

    pub fn init(gpa: std.mem.Allocator, table: TableRef, key_column: []const u8) BatchFinder {
        return .{
            .gpa = gpa,
            .table = table,
            .key_column = key_column,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .key_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *BatchFinder) void {
        self.keys.deinit(self.gpa);
        self.cache.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        self.arena.deinit();
        self.key_arena.deinit();
    }

    /// 登记一批主键：跳过 `0` / 空串，按键去重（C# `Add` 同口径）。
    pub fn add(self: *BatchFinder, values: []const Value) !void {
        for (values) |v| {
            if (isSkipped(v)) continue;

            const text = try self.keyTextIn(self.key_arena.allocator(), v);
            if (self.seen.contains(text)) continue;
            try self.seen.put(self.gpa, text, {});
            try self.keys.append(self.gpa, v);
        }
    }

    /// 登记的主键个数。
    pub fn keyCount(self: *const BatchFinder) usize {
        return self.keys.items.len;
    }

    /// 已缓存的行数。
    pub fn cacheCount(self: *const BatchFinder) usize {
        return self.cache.count();
    }

    /// 按主键查找。未命中且后面还有未扫描的键时，分批预取后再判断。
    ///
    /// - 键为 `0` / 空串 → `null`（不报错，与 C# 一致）；
    /// - 键未登记 → `error.NotInKeys`；
    /// - 全部扫完仍没有 → `null`。
    pub fn find(self: *BatchFinder, s: *Session, key: Value) !?Row {
        if (isSkipped(key)) return null;

        const key_text = try self.keyTextAlloc(key);
        defer self.gpa.free(key_text);

        if (self.cache.get(key_text)) |row| return row;

        if (!self.seen.contains(key_text)) return error.NotInKeys;

        var batch: std.ArrayListUnmanaged(Value) = .empty;
        defer batch.deinit(self.gpa);

        while (self.index < self.keys.items.len) {
            batch.clearRetainingCapacity();
            const end = @min(self.index + self.batch_size, self.keys.items.len);
            try batch.appendSlice(self.gpa, self.keys.items[self.index..end]);
            if (batch.items.len == 0) break;

            const rows = try self.load(s, batch.items);
            for (rows) |row| {
                const row_key = row.get(self.key_column) orelse continue;
                try self.store(row_key, row);
            }

            if (self.cache.get(key_text)) |row| return row;

            self.index = end;
        }
        return null;
    }

    /// 清空缓存与扫描游标（键登记保留）：数据被外部改动后可重扫。
    pub fn resetCache(self: *BatchFinder) void {
        self.cache.clearRetainingCapacity();
        self.index = 0;
        _ = self.arena.reset(.retain_capacity);
        // arena 重置后缓存里的 Row 已失效，必须同时清空（上面已 clear）
    }

    fn load(self: *BatchFinder, s: *Session, keys: []const Value) ![]Row {
        if (self.loader) |loader| return loader(self.loader_ctx.?, s, keys);

        var w = Where.init(self.gpa);
        defer w.deinit();
        _ = try w.in(self.key_column, keys);

        var q = Query.init(self.gpa);
        defer q.deinit();
        _ = q.filterWhere(&w);
        return self.table.queryRows(s, &q);
    }

    /// 深拷贝一行进缓存（键与行都进 row arena，`resetCache` 时一起回收）。
    fn store(self: *BatchFinder, key: Value, row: Row) !void {
        const a = self.arena.allocator();
        const key_text = try self.keyTextIn(a, key);

        if (self.cache.contains(key_text)) return;

        const names = try a.alloc([]const u8, row.names.len);
        for (row.names, 0..) |name, i| names[i] = try a.dupe(u8, name);
        const values = try a.alloc(Value, row.values.len);
        for (row.values, 0..) |v, i| values[i] = try deepCopyValue(a, v);

        try self.cache.put(self.gpa, key_text, .{ .names = names, .values = values });
    }

    fn keyTextAlloc(self: *BatchFinder, key: Value) ![]u8 {
        return self.keyTextIn(self.gpa, key);
    }

    fn keyTextIn(self: *BatchFinder, a: std.mem.Allocator, key: Value) ![]u8 {
        _ = self;
        return key.toTextAlloc(a);
    }
};

/// C# 里 `0` / 空串视为「无效主键」，直接跳过。
pub fn isSkipped(v: Value) bool {
    return switch (v) {
        .null => true,
        .int => |n| n == 0,
        .text => |t| t.len == 0,
        else => false,
    };
}

fn deepCopyValue(a: std.mem.Allocator, v: Value) !Value {
    return switch (v) {
        .text => |t| Value{ .text = try a.dupe(u8, t) },
        .blob => |b| Value{ .blob = try a.dupe(u8, b) },
        else => v,
    };
}

// ============================ 测试 ============================

const testing = std.testing;
const model = @import("model.zig");
const sqlbuild = @import("sqlbuild.zig");
const Dal = @import("dal.zig").Dal;

const test_model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel>
    \\  <Tables>
    \\    <Table Name="User" TableName="User">
    \\      <Columns>
    \\        <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\        <Column Name="Name" DataType="String" Length="50" Nullable="True" />
    \\      </Columns>
    \\    </Table>
    \\  </Tables>
    \\</EntityModel>
;

fn memDal(a: std.mem.Allocator) !Dal {
    const m = try model.EntityModel.parse(a, test_model_xml);
    return Dal.initWithModel(a, "Data Source=:memory:;Provider=SQLite", m);
}

fn seed(s: *Session, table: TableRef, names: []const []const u8) !void {
    for (names) |name| {
        const fields = [_]sqlbuild.Field{
            .{ .name = "Name", .value = .{ .text = name } },
        };
        _ = try table.insert(s, &fields);
    }
}

test "isSkipped：0 与空串" {
    try testing.expect(isSkipped(.null));
    try testing.expect(isSkipped(.{ .int = 0 }));
    try testing.expect(isSkipped(.{ .text = "" }));
    try testing.expect(!isSkipped(.{ .int = 1 }));
    try testing.expect(!isSkipped(.{ .text = "a" }));
    try testing.expect(!isSkipped(.{ .float = 0 }));
}

test "BatchOption 默认值" {
    const o = BatchOption.empty;
    try testing.expectEqual(@as(usize, 0), o.columns.len);
    try testing.expect(!o.full_insert);
    try testing.expectEqual(@as(usize, 0), o.batch_size);
}

test "BatchFinder：去重 / 跳过 0 / 按批预取 / 未登记者报错" {
    const a = testing.allocator;
    var dal = try memDal(a);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    _ = try dal.syncSchema(&s);
    const table = try dal.table("User");
    try seed(&s, table, &.{ "a", "b", "c", "d", "e" });

    var finder = BatchFinder.init(a, table, "Id");
    defer finder.deinit();

    // 重复登记只留一份；0 被跳过
    try finder.add(&.{ .{ .int = 3 }, .{ .int = 3 }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 5 } });
    try testing.expectEqual(@as(usize, 3), finder.keyCount());

    // 批大小 2：找 5 需要跨两批（第一批 [3,1]，第二批 [5]）
    finder.batch_size = 2;

    const row5 = (try finder.find(&s, .{ .int = 5 })).?;
    try testing.expectEqualStrings("e", row5.get("Name").?.text);
    // 第一批已缓存 3 和 1，第二次命中不再查库
    const cached_before = finder.cacheCount();
    const row3 = (try finder.find(&s, .{ .int = 3 })).?;
    try testing.expectEqualStrings("c", row3.get("Name").?.text);
    try testing.expectEqual(cached_before, finder.cacheCount());

    // 0 与空串直接 null，不报错
    try testing.expect(try finder.find(&s, .{ .int = 0 }) == null);
    try testing.expect(try finder.find(&s, .{ .text = "" }) == null);

    // 未登记 → NotInKeys
    try testing.expectError(error.NotInKeys, finder.find(&s, .{ .int = 2 }));

    // 登记了但库里没有 → null
    try finder.add(&.{.{ .int = 999 }});
    try testing.expect(try finder.find(&s, .{ .int = 999 }) == null);
}

test "BatchFinder：自定义 loader 生效" {
    const a = testing.allocator;
    var dal = try memDal(a);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();

    _ = try dal.syncSchema(&s);
    const table = try dal.table("User");
    try seed(&s, table, &.{ "x", "y" });

    var calls: usize = 0;

    const Ctx = struct {
        calls: *usize,
        table: TableRef,
        fn load(ctx: *anyopaque, sess: *Session, keys: []const Value) anyerror![]Row {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls.* += 1;
            var w = Where.init(sess.gpa);
            defer w.deinit();
            _ = try w.in("Id", keys);
            var q = Query.init(sess.gpa);
            defer q.deinit();
            _ = q.filterWhere(&w);
            return self.table.queryRows(sess, &q);
        }
    };
    var ctx = Ctx{ .calls = &calls, .table = table };

    var finder = BatchFinder.init(a, table, "Id");
    defer finder.deinit();
    finder.loader = Ctx.load;
    finder.loader_ctx = &ctx;

    try finder.add(&.{.{ .int = 1 }});
    _ = try finder.find(&s, .{ .int = 1 });
    try testing.expectEqual(@as(usize, 1), calls);
}
