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
