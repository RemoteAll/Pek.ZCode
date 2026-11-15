//! 搜索条件推导（对应 C# `Code/SearchBuilder.cs`）。
//!
//! ## 用途
//!
//! 后台列表页 / 开放接口的「高级查询」参数不该手写维护——它完全由模型推导：
//! **索引列 + 枚举/映射的整数列 + 布尔开关 + 时间字段**就是可搜项，外加固定得 `key` / `page`
//! 与时间区间 `start` / `end`。C# 用这套规则生成查询页面代码，这里则直接产出**参数计划**，
//! 供 Zig 侧拼 `query.Where` 或生成前端表单。
//!
//! ## 规则（逐条对齐 `SearchBuilder.GetColumns()`）
//!
//! 1. **索引列优先**：凡出现在任一索引里的列（按**表字段顺序**），且不是主键/自增/主字段、
//!    `ShowIn.Search` 没显式 `Hide` → 入选；
//! 2. **显式 Show**：`ShowIn.Search = Show` → 直接入选；`Hide` → 直接排除；
//! 3. **时间分片列**（`DataScale` 非空）→ 入选；
//! 4. **整数列**：是枚举（`EnumType`）/ 有 `Map` / 有 `Type` 属性 → 入选；
//! 5. **布尔列**：除 `enable` / `isDeleted` 外 → 入选；这两个**排在最后**入选（它们是常见开关）；
//! 6. 收尾：挑出**数据时间列**（`DataScale` 以 `time` 开头 → 否则第一个 `DateTime` → 否则 `UpdateTime`/`CreateTime`）
//!    与**雪花键**（`Int64` 主键且非自增），把它们移出可搜列，并移除 `key`/`page`，
//!    有数据时间列或雪花键时再移除 `start`/`end`（避免与区间参数重名）。
//!
//! ## 与 C# 的差异
//! - C# 生成的是 C# 方法参数（`ParameterModel`）；Zig 产出的是 `Param`（名字 + 语义 `Kind`）；
//! - 保留字处理（C# 给参数名加 `@`）不适用：调用方拼 SQL 时统一走 `dialect` 的引用规则。

const std = @import("std");
const model = @import("model.zig");
const tmpl = @import("sqltemplate.zig");
const query_mod = @import("query.zig");
const Where = query_mod.Where;
const OrderBy = query_mod.OrderBy;
const Query = query_mod.Query;
const expression = @import("expression.zig");
const Value = @import("zzig").db.Value;
const Dal = @import("dal.zig").Dal;
const Session = @import("session.zig").Session;
const entity = @import("entity.zig");

/// 参数语义
pub const Kind = enum {
    /// 等值过滤（`col = @p`）
    equal,
    /// 时间区间（`start` / `end` 一对）
    time_range,
    /// 关键字（C# 里是模糊搜索的 `key`）
    key,
    /// 分页参数（`page`）
    page,
};

pub const Param = struct {
    name: []const u8,
    kind: Kind,
    /// `equal` 时对应的列；`time_range`/`key`/`page` 为 null
    column: ?*const model.ColumnMeta = null,
};

pub const Plan = struct {
    /// 可搜索列（已剔除数据时间列与 `key`/`page`/`start`/`end`）
    columns: []const *const model.ColumnMeta,
    /// 数据时间列：`DataScale` 以 `time` 开头的列 → 第一个 `DateTime` → `UpdateTime`/`CreateTime`
    data_time: ?*const model.ColumnMeta,
    /// 雪花键（`Int64` 主键且非自增）：有它时用 `Id` 做游标分页
    snow_key: ?*const model.ColumnMeta,
};

pub const Options = struct {
    /// 是否追加 `start` / `end` / `key` / `page` 四个固定参数（C# `GetParameters(columns, extend)`）
    extend: bool = true,
};

/// 完整计划：可搜列 + 数据时间列 + （可选）固定参数。
pub fn planAlloc(a: std.mem.Allocator, table: *const model.TableMeta, opts: Options) !struct { plan: Plan, params: []Param } {
    const plan = Plan{
        .columns = try searchColumnsAlloc(a, table),
        .data_time = dataTimeColumn(table),
        .snow_key = snowKeyColumn(table),
    };

    var params: std.ArrayList(Param) = .empty;
    for (plan.columns) |col| {
        try params.append(a, .{ .name = col.name, .kind = .equal, .column = col });
    }
    if (opts.extend) {
        if (plan.data_time != null or plan.snow_key != null) {
            try params.append(a, .{ .name = "start", .kind = .time_range });
            try params.append(a, .{ .name = "end", .kind = .time_range });
        }
        try params.append(a, .{ .name = "key", .kind = .key });
        try params.append(a, .{ .name = "page", .kind = .page });
    }
    return .{ .plan = plan, .params = try params.toOwnedSlice(a) };
}

/// 可搜索列（`Plan.columns` 的实现，单独暴露便于测试/复用）。
pub fn searchColumnsAlloc(a: std.mem.Allocator, table: *const model.TableMeta) ![]const *const model.ColumnMeta {
    var out: std.ArrayList(*const model.ColumnMeta) = .empty;
    errdefer out.deinit(a);

    // 1) 索引列优先（按表字段顺序）
    if (table.indexes.len > 0) {
        for (table.columns) |*col| {
            if (col.primary_key or col.identity or col.master) continue;
            if (showInSearch(col) == .hide) continue;
            if (inAnyIndex(table, col)) try addUnique(a, &out, col);
        }
    }

    // 2) 特殊字段
    for (table.columns) |*col| {
        if (containsPtr(out.items, col)) continue;

        switch (showInSearch(col)) {
            .show => {
                try addUnique(a, &out, col);
                continue;
            },
            .hide => continue,
            .auto => {},
        }

        if (col.data_scale != null and col.data_scale.?.len > 0) {
            try addUnique(a, &out, col);
        } else if (isInt(col.data_type)) {
            // 整型：枚举 / 有映射 / 有 Type 属性 才值得作为搜索项
            if (hasNonEmpty(col.enum_type) or hasNonEmpty(col.map) or hasExtraKey(col, "Type")) {
                try addUnique(a, &out, col);
            }
        } else if (col.data_type == .boolean and !isSwitchName(col.name)) {
            try addUnique(a, &out, col);
        }
    }

    // 3) enable / isDeleted 这类布尔开关排在最后
    for (table.columns) |*col| {
        if (containsPtr(out.items, col)) continue;
        if (col.data_type == .boolean and isSwitchName(col.name)) try addUnique(a, &out, col);
    }

    // 4) 收尾：剔除数据时间列与保留参数名
    const data_time = dataTimeColumn(table);
    const snow = snowKeyColumn(table);
    var kept: std.ArrayList(*const model.ColumnMeta) = .empty;
    errdefer kept.deinit(a);
    for (out.items) |col| {
        if (data_time) |dt| {
            if (col == dt) continue;
        }
        if (snow) |sk| {
            if (col == sk) continue;
        }
        if (isReservedName(col.name, data_time != null or snow != null)) continue;
        try kept.append(a, col);
    }
    out.deinit(a);
    return kept.toOwnedSlice(a);
}

/// 数据时间列：`DataScale` 以 `time` 开头 → 第一个 `DateTime` → `UpdateTime` / `CreateTime`。
pub fn dataTimeColumn(table: *const model.TableMeta) ?*const model.ColumnMeta {
    for (table.columns) |*col| {
        if (col.data_scale) |ds| {
            if (ds.len >= 4 and std.ascii.eqlIgnoreCase(ds[0..4], "time")) return col;
        }
    }
    for (table.columns) |*col| {
        if (col.data_type == .datetime) return col;
    }
    for (table.columns) |*col| {
        if (std.ascii.eqlIgnoreCase(col.name, "UpdateTime") or std.ascii.eqlIgnoreCase(col.name, "CreateTime")) return col;
    }
    return null;
}

/// 雪花键：`Int64` 主键且非自增（C# `dcSnow`）。
pub fn snowKeyColumn(table: *const model.TableMeta) ?*const model.ColumnMeta {
    for (table.columns) |*col| {
        if (col.primary_key and !col.identity and col.data_type == .int64) return col;
    }
    return null;
}

// ── 内部工具 ────────────────────────────────────────────────────────────────

const Tri = tmpl.TriState;

fn showInSearch(col: *const model.ColumnMeta) Tri {
    const raw = col.show_in orelse return .auto;
    if (raw.len == 0) return .auto;
    return tmpl.ShowInOption.parse(raw).search;
}

fn inAnyIndex(table: *const model.TableMeta, col: *const model.ColumnMeta) bool {
    for (table.indexes) |idx| {
        for (idx.columns) |name| {
            if (std.ascii.eqlIgnoreCase(name, col.name)) return true;
            if (col.column_name) |cn| {
                if (std.ascii.eqlIgnoreCase(name, cn)) return true;
            }
        }
    }
    return false;
}

fn isInt(t: @import("types.zig").DataType) bool {
    return switch (t) {
        .byte, .int16, .int32, .int64 => true,
        else => false,
    };
}

fn isSwitchName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "enable") or std.ascii.eqlIgnoreCase(name, "isDeleted");
}

fn hasNonEmpty(v: ?[]const u8) bool {
    return if (v) |s| s.len > 0 else false;
}

fn hasExtraKey(col: *const model.ColumnMeta, key: []const u8) bool {
    for (col.extra) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.key, key)) return kv.value.len > 0;
    }
    return false;
}

fn isReservedName(name: []const u8, has_time: bool) bool {
    if (std.ascii.eqlIgnoreCase(name, "key") or std.ascii.eqlIgnoreCase(name, "page")) return true;
    if (has_time and (std.ascii.eqlIgnoreCase(name, "start") or std.ascii.eqlIgnoreCase(name, "end"))) return true;
    return false;
}

fn containsPtr(items: []const *const model.ColumnMeta, col: *const model.ColumnMeta) bool {
    for (items) |it| {
        if (it == col) return true;
    }
    return false;
}

fn addUnique(a: std.mem.Allocator, out: *std.ArrayList(*const model.ColumnMeta), col: *const model.ColumnMeta) !void {
    if (containsPtr(out.items, col)) return;
    try out.append(a, col);
}

// ── 用例 ────────────────────────────────────────────────────────────────────

fn testModel(a: std.mem.Allocator) !model.EntityModel {
    const xml =
        \\<EntityModel><Tables><Table Name="Order" TableName="Shop_Order">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int64" PrimaryKey="True" Identity="True" />
        \\    <Column Name="OrderNo" DataType="String" Length="32" />
        \\    <Column Name="Status" DataType="Int32" EnumType="OrderStatus" />
        \\    <Column Name="ShopId" DataType="Int32" />
        \\    <Column Name="Remark" DataType="String" Length="200" />
        \\    <Column Name="CreateTime" DataType="DateTime" DataScale="time" />
        \\    <Column Name="UpdateTime" DataType="DateTime" />
        \\    <Column Name="Enable" DataType="Boolean" />
        \\    <Column Name="IsDeleted" DataType="Boolean" />
        \\  </Columns>
        \\  <Indexes>
        \\    <Index Columns="OrderNo" Unique="True" />
        \\    <Index Columns="ShopId,Status" />
        \\  </Indexes>
        \\</Table></Tables></EntityModel>
    ;
    return model.EntityModel.parse(a, xml);
}

test "搜索推导 - 索引列 / 枚举整数 / 时间列 / 布尔开关的顺序与剔除" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try testModel(a);
    const table = &m.tables[0];
    const cols = try searchColumnsAlloc(a, table);

    var names: std.ArrayList([]const u8) = .empty;
    for (cols) |c| try names.append(a, c.name);
    // 期望：索引列 OrderNo/ShopId/Status（按字段顺序，Status 虽是索引列但也是枚举整数，只出现一次）
    // + 布尔开关 Enable/IsDeleted 排最后；Remark 无索引无映射 → 不入选；
    // CreateTime（time 分片）被识别成数据时间列 → 从可搜列剔除
    try std.testing.expectEqualStrings("OrderNo,Status,ShopId,Enable,IsDeleted", try std.mem.join(a, ",", names.items));

    const dt = dataTimeColumn(table).?;
    try std.testing.expectEqualStrings("CreateTime", dt.name);
}

test "搜索推导 - 数据时间列的三级回退" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 没有 DataScale：退到第一个 DateTime
    var m1 = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="A" TableName="A">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" PrimaryKey="True" Identity="True" />
        \\    <Column Name="ModifyOn" DataType="DateTime" />
        \\    <Column Name="CreateTime" DataType="DateTime" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    );
    try std.testing.expectEqualStrings("ModifyOn", dataTimeColumn(&m1.tables[0]).?.name);

    // 没有 DateTime：退到 UpdateTime / CreateTime
    var m2 = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="B" TableName="B">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" PrimaryKey="True" Identity="True" />
        \\    <Column Name="CreateTime" DataType="String" Length="20" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    );
    try std.testing.expectEqualStrings("CreateTime", dataTimeColumn(&m2.tables[0]).?.name);

    // 都没有 → null
    var m3 = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="C" TableName="C">
        \\  <Columns><Column Name="Id" DataType="Int32" PrimaryKey="True" Identity="True" /></Columns>
        \\</Table></Tables></EntityModel>
    );
    try std.testing.expect(dataTimeColumn(&m3.tables[0]) == null);
}

test "搜索推导 - 参数计划：等值 + start/end + key + page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try testModel(a);
    const r = try planAlloc(a, &m.tables[0], .{ .extend = true });

    var names: std.ArrayList([]const u8) = .empty;
    for (r.params) |p| try names.append(a, p.name);
    try std.testing.expectEqualStrings("OrderNo,Status,ShopId,Enable,IsDeleted,start,end,key,page", try std.mem.join(a, ",", names.items));
    try std.testing.expectEqual(Kind.time_range, r.params[5].kind);
    try std.testing.expectEqual(Kind.page, r.params[8].kind);

    // 不扩展时只有可搜列
    const r2 = try planAlloc(a, &m.tables[0], .{ .extend = false });
    try std.testing.expectEqual(@as(usize, 5), r2.params.len);
}

test "搜索推导 - ShowIn 显式 Show/Hide 覆盖推导结果" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="D" TableName="D">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" PrimaryKey="True" Identity="True" />
        \\    <Column Name="Remark" DataType="String" Length="100" ShowIn="Search" />
        \\    <Column Name="Memo" DataType="String" Length="100" ShowIn="A|A|A|A|N" />
        \\  </Columns>
        \\  <Indexes><Index Columns="Memo" /></Indexes>
        \\</Table></Tables></EntityModel>
    );
    const cols = try searchColumnsAlloc(a, &m.tables[0]);
    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqualStrings("Remark", cols[0].name);
}

// ══════════════════ 执行侧（≂ C# `Entity.Search` 系列） ══════════════════
//
// 上面那半是「模型 → 参数计划」（C# `SearchBuilder` 的产出）；
// 下面这半是「用户输入 → 条件 → 分页查询」，也就是 C# 页面代码里手写的那段。
//
// 三条必须照抄 C# 的规则：
// 1. **按空白拆词，词之间 AND**（`SearchWhereByKeys`：`keys.Split(' ')` 后 `exp &= ...`）；
// 2. **每个词对所有字符串列 OR LIKE**（`SearchWhereByKey`：`fields` 为空取 `Meta.Fields`，
//    再 `item.Type != typeof(String) continue`）；
// 3. **通配符转义**（C# `Contains` → `FormatLike`：`%`→`\%`、`_`→`\_`、`'`→`''`）。
//    不转义时用户搜 `50%` 会变成「50 开头的任意串」，是静默错。

pub const ApplyError = error{
    /// `fields` / `time_column` / 排序里给了模型没有的列
    NoField,
} || std.mem.Allocator.Error;

/// 搜索选项（≂ C# `Search(key, PageParameter)` 的参数集合）。
pub const QueryOptions = struct {
    /// 参与 LIKE 的列（按名，忽略大小写）；**null 或空 = 模型里所有字符串列**。
    /// 给了非字符串列 → 跳过（照 C# `Contains` 只支持 String）。
    fields: ?[]const []const u8 = null,
    /// 时间列（null = 模型里 `Master="True"` 的列；找不到就不加时间条件）
    time_column: ?[]const u8 = null,
    /// 时间窗起点（null = 不限）
    time_start: ?Value = null,
    /// 时间窗终点（null = 不限）
    time_end: ?Value = null,
    /// 右端是否闭区间。缺省 **false = 左闭右开**（对齐 C# DateTime 的 `Between`）；
    /// 整数日期（`20250101` 这种）需要两端闭合时显式传 true。
    time_end_inclusive: bool = false,
    /// 排序（复用 `Query.OrderBy`，列名按模型校验）
    orders: []const OrderBy = &.{},
    /// 页码（从 1 开始）
    page_index: usize = 1,
    /// 每页行数（0 = 不分页；大表请配合 `Setting.max_query_rows`）
    page_size: usize = 20,
};

/// 搜索结果（≂ C# `PageParameter` 回填的 `TotalCount`）。
pub fn Page(comptime T: type) type {
    return struct {
        rows: []T,
        /// 满足条件的**总行数**（不受分页影响）
        total: i64,
        page_index: usize,
        page_size: usize,

        /// 总页数（`page_size = 0` 表示不分页 → 1 页）。
        pub fn totalPages(self: @This()) usize {
            if (self.page_size == 0) return 1;
            const t: usize = if (self.total <= 0) 0 else @intCast(self.total);
            return (t + self.page_size - 1) / self.page_size;
        }
    };
}

/// 收集参与搜索的列（返回**物理**列名，可直接进 SQL）。`fields` 为空 → 所有字符串列。
fn collectSearchColumns(
    gpa: std.mem.Allocator,
    table: *const model.TableMeta,
    fields: ?[]const []const u8,
) ApplyError![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);

    if (fields) |names| {
        if (names.len > 0) {
            for (names) |n| {
                const col = table.column(n) orelse return ApplyError.NoField;
                if (col.data_type != .string) continue;
                try out.append(gpa, table.effectiveColumnName(col));
            }
            return out.toOwnedSlice(gpa);
        }
    }

    for (table.columns) |*col| {
        if (col.data_type != .string) continue;
        try out.append(gpa, table.effectiveColumnName(col));
    }
    return out.toOwnedSlice(gpa);
}

/// 「空格分隔的关键字」→ 条件：每个词一次「多列 OR LIKE」，**词之间 AND**。
///
/// ≂ C# `SearchWhereByKeys`：空串不加条件；按空白拆（去空项）、逐项 `Trim` 后再判空。
/// **返回实际追加的条件条数**（0 = 没搜索，等于全量）。
///
/// 通配符按 C# `FormatLike` 转义后再包 `%...%`：搜 `50%` 是「含 50% 这个串」。
pub fn applyKeys(
    w: *Where,
    gpa: std.mem.Allocator,
    table: *const model.TableMeta,
    keys: []const u8,
    fields: ?[]const []const u8,
) ApplyError!usize {
    if (keys.len == 0) return 0;

    const cols = try collectSearchColumns(gpa, table, fields);
    defer gpa.free(cols);
    if (cols.len == 0) return 0; // 没有字符串列 → 搜不出东西，也不该加条件

    var added: usize = 0;
    var it = std.mem.tokenizeAny(u8, keys, " \t\r\n");
    while (it.next()) |raw| {
        const word = std.mem.trim(u8, raw, " \t\r\n");
        if (word.len == 0) continue;

        // 转义与 `%...%` 包装由 `anyLikeEscaped` 负责（含 `ESCAPE '!'` 子句）
        _ = try w.anyLikeEscaped(cols, word);
        added += 1;
    }
    return added;
}

/// 值比较（只用于判断时间窗 `start` 与 `end` 的先后；判不了就返回 null = 不做判定）。
fn valueOrder(x: Value, y: Value) ?std.math.Order {
    if (x.asI64()) |xi| {
        if (y.asI64()) |yi| {
            if (xi < yi) return .lt;
            if (xi > yi) return .gt;
            return .eq;
        }
    }
    if (x.asText()) |xs| {
        if (y.asText()) |ys| return std.mem.order(u8, xs, ys);
    }
    return null;
}

/// 追加时间窗条件（≂ C# `FieldExtension.Between` 的 DateTime / Int64 两个重载）。
///
/// - 缺省**左闭右开**（DateTime 口径）：`>= start` / `< end`；
/// - `end_inclusive = true` 时**两端闭合**（Int64 口径）：`>= start` / `<= end`，
///   且 `start == end` 退化成 `=`；
/// - `start > end` → **不加条件**（C# 返回空表达式；宁可搜出全部也不生成恒假条件）。
///
/// 返回 false 表示「没加任何条件」（两端都没给 / 模型没有时间列 / start > end）。
pub fn applyTimeRange(
    w: *Where,
    table: *const model.TableMeta,
    time_column: ?[]const u8,
    start: ?Value,
    end: ?Value,
    end_inclusive: bool,
) ApplyError!bool {
    if (start == null and end == null) return false;

    const col = blk: {
        if (time_column) |name| break :blk table.column(name) orelse return ApplyError.NoField;
        for (table.columns) |*c| {
            if (c.master) break :blk c;
        }
        break :blk null;
    };
    if (col == null) return false;
    const name = table.effectiveColumnName(col.?);

    if (start != null and end != null) {
        if (valueOrder(start.?, end.?) == .gt) return false;
    }

    if (start) |s| {
        if (end != null and end_inclusive and valueOrder(s, end.?) == .eq) {
            _ = try w.eq(name, s);
            return true;
        }
        _ = try w.ge(name, s);
    }
    if (end) |e| {
        if (end_inclusive) {
            _ = try w.le(name, e);
        } else {
            _ = try w.lt(name, e);
        }
    }
    return true;
}

/// 按参数计划把**等值过滤**写进条件（`plan.params` 里 `kind == .equal` 的那些）。
///
/// `input` 是「参数名 → 值」的映射（通常来自 HTTP 查询串）。缺失的参数跳过、
/// **值为 null/空串的也跳过**（列表页没填的筛选项等于不筛）。
pub fn applyEquals(
    w: *Where,
    table: *const model.TableMeta,
    params: []const Param,
    input: *const std.StringHashMapUnmanaged(Value),
) ApplyError!usize {
    var added: usize = 0;
    for (params) |p| {
        if (p.kind != .equal) continue;
        const v = input.get(p.name) orelse continue;
        if (v.isNull()) continue;
        if (v.asText()) |t| {
            if (t.len == 0) continue;
        }
        const col = p.column orelse (table.column(p.name) orelse return ApplyError.NoField);
        _ = try w.eq(table.effectiveColumnName(col), v);
        added += 1;
    }
    return added;
}

/// 「搜索框」一站式入口：关键字 + 时间窗 + 排序 + 分页，一次返回**行 + 总数**。
///
/// ≂ C# `Search(String key, PageParameter page)` —— C# 的 `PageParameter` 会被回填总行数，
/// 这里直接放进返回值，调用方不必再发一次 `COUNT`。
///
/// 返回的实体字符串**借用会话结果 arena**（与 `entity.queryRows` 同口径），
/// 下次查询或 `Session.resetResults` 后失效；要长留请自己深拷贝。
pub fn search(
    dal: *Dal,
    comptime T: type,
    s: *Session,
    keys: []const u8,
    opt: QueryOptions,
) !Page(T) {
    const ref = try dal.table(T.meta.table_name);
    const gpa = dal.gpa;

    var w = Where.init(gpa);
    defer w.deinit();

    _ = try applyKeys(&w, gpa, ref.table, keys, opt.fields);
    _ = try applyTimeRange(&w, ref.table, opt.time_column, opt.time_start, opt.time_end, opt.time_end_inclusive);

    return searchWhere(dal, T, s, &w, opt.orders, opt.page_index, opt.page_size);
}

/// 已有条件（`Where`）时的一站式入口：条件 + 排序 + 分页 + 总数。
pub fn searchWhere(
    dal: *Dal,
    comptime T: type,
    s: *Session,
    w: *const Where,
    orders: []const OrderBy,
    page_index: usize,
    page_size: usize,
) !Page(T) {
    const ref = try dal.table(T.meta.table_name);
    const gpa = dal.gpa;

    var q = Query.init(gpa);
    defer q.deinit();

    if (!w.isEmpty()) _ = q.filterWhere(w);
    for (orders) |o| {
        // 列名按模型校验：外部传入的排序串就是注入面
        const col = ref.table.column(o.column) orelse return ApplyError.NoField;
        _ = try q.orderBy(ref.table.effectiveColumnName(col), o.desc);
    }
    if (page_size > 0) _ = q.page(if (page_index == 0) 1 else page_index, page_size);

    const rows = try entity.queryRows(dal, T, s, &q);
    const total = try ref.count(s, w);

    return .{
        .rows = rows,
        .total = total,
        .page_index = if (page_index == 0) 1 else page_index,
        .page_size = page_size,
    };
}

test "搜索执行 - 空格拆词、词间 AND、每词多列 OR LIKE、通配符已转义" {
    const a = std.testing.allocator;
    const t = model.TableMeta{
        .name = "Demo",
        .table_name = "DH_Demo",
        .columns = &.{
            .{ .name = "Name", .data_type = .string },
            .{ .name = "Code", .data_type = .string, .column_name = "F_Code" },
            .{ .name = "Age", .data_type = .int32 },
        },
    };

    var w = Where.init(a);
    defer w.deinit();

    const n = try applyKeys(&w, a, &t, "  ab   50%  ", null);
    try std.testing.expectEqual(@as(usize, 2), n);

    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);
    const sql = try w.renderAlloc(a, .sqlite, &params);
    defer a.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, " AND ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "Age") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ESCAPE '!'") != null);
    try std.testing.expectEqual(@as(usize, 4), params.items.len);
    try std.testing.expectEqualStrings("%ab%", params.items[0].text);
    try std.testing.expectEqualStrings("%50!%%", params.items[2].text);
}

test "搜索执行 - 空关键字/纯空白不加条件；未知列报 NoField；非字符串列跳过" {
    const a = std.testing.allocator;
    const t = model.TableMeta{
        .name = "Demo",
        .table_name = "DH_Demo",
        .columns = &.{
            .{ .name = "Name", .data_type = .string },
            .{ .name = "Age", .data_type = .int32 },
        },
    };

    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expectEqual(@as(usize, 0), try applyKeys(&w, a, &t, "", null));
        try std.testing.expectEqual(@as(usize, 0), try applyKeys(&w, a, &t, "   \t ", null));
        try std.testing.expect(w.isEmpty());
    }
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expectEqual(@as(usize, 1), try applyKeys(&w, a, &t, "x", &.{ "Name", "Age" }));
    }
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expectError(ApplyError.NoField, applyKeys(&w, a, &t, "x", &.{"Nope"}));
    }
}

test "搜索执行 - 时间窗：左闭右开 / 两端闭合 / start==end 退化 / start>end 不加" {
    const a = std.testing.allocator;
    const t = model.TableMeta{
        .name = "Demo",
        .table_name = "DH_Demo",
        .columns = &.{
            .{ .name = "CreateTime", .data_type = .int64, .master = true },
            .{ .name = "Name", .data_type = .string },
        },
    };
    const no_time = model.TableMeta{
        .name = "Demo2",
        .table_name = "DH_Demo2",
        .columns = &.{.{ .name = "Name", .data_type = .string }},
    };

    var params: std.ArrayList(Value) = .empty;
    defer params.deinit(a);

    // 左闭右开（C# DateTime 口径）
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expect(try applyTimeRange(&w, &t, null, .{ .int = 100 }, .{ .int = 200 }, false));
        params.clearRetainingCapacity();
        const sql = try w.renderAlloc(a, .sqlite, &params);
        defer a.free(sql);
        try std.testing.expect(std.mem.indexOf(u8, sql, ">=") != null);
        try std.testing.expect(std.mem.indexOf(u8, sql, "< ?") != null);
        try std.testing.expect(std.mem.indexOf(u8, sql, "<=") == null);
    }

    // 两端闭合（C# Int64 口径）
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expect(try applyTimeRange(&w, &t, null, .{ .int = 100 }, .{ .int = 200 }, true));
        params.clearRetainingCapacity();
        const sql = try w.renderAlloc(a, .sqlite, &params);
        defer a.free(sql);
        try std.testing.expect(std.mem.indexOf(u8, sql, "<=") != null);
    }

    // start == end 且闭合 → 退化成 `=`
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expect(try applyTimeRange(&w, &t, null, .{ .int = 100 }, .{ .int = 100 }, true));
        params.clearRetainingCapacity();
        const sql = try w.renderAlloc(a, .sqlite, &params);
        defer a.free(sql);
        try std.testing.expect(std.mem.indexOf(u8, sql, ">=") == null);
        try std.testing.expect(std.mem.indexOf(u8, sql, "=") != null);
    }

    // start > end → 不加条件
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expect(!try applyTimeRange(&w, &t, null, .{ .int = 200 }, .{ .int = 100 }, true));
        try std.testing.expect(w.isEmpty());
    }

    // 两端都没给 / 模型没有 Master 列 → 不加（不报错）
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expect(!try applyTimeRange(&w, &t, null, null, null, false));
        try std.testing.expect(!try applyTimeRange(&w, &no_time, null, .{ .int = 1 }, null, false));
        try std.testing.expect(w.isEmpty());
    }

    // 显式指定不存在的列 → NoField
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expectError(ApplyError.NoField, applyTimeRange(&w, &t, "Nope", .{ .int = 1 }, null, false));
    }
}

test "搜索执行 - 等值过滤：只取 .equal 参数，空值跳过，缺失跳过" {
    const a = std.testing.allocator;
    const t = model.TableMeta{
        .name = "Demo",
        .table_name = "DH_Demo",
        .columns = &.{
            .{ .name = "Status", .data_type = .int32 },
            .{ .name = "ShopId", .data_type = .int32 },
        },
    };
    const status: model.ColumnMeta = .{ .name = "Status", .data_type = .int32 };
    const shop: model.ColumnMeta = .{ .name = "ShopId", .data_type = .int32 };
    const params = [_]Param{
        .{ .name = "Status", .kind = .equal, .column = &status },
        .{ .name = "ShopId", .kind = .equal, .column = &shop },
        .{ .name = "key", .kind = .key },
        .{ .name = "page", .kind = .page },
    };

    var input: std.StringHashMapUnmanaged(Value) = .empty;
    defer input.deinit(a);
    try input.put(a, "Status", .{ .int = 1 });
    try input.put(a, "key", .{ .text = "abc" }); // kind 不是 .equal → 不参与

    var w = Where.init(a);
    defer w.deinit();

    const n = try applyEquals(&w, &t, &params, &input);
    try std.testing.expectEqual(@as(usize, 1), n);

    var out: std.ArrayList(Value) = .empty;
    defer out.deinit(a);
    const sql = try w.renderAlloc(a, .sqlite, &out);
    defer a.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "Status") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ShopId") == null);
}
