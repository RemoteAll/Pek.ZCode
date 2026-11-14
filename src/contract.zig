//! 契约清单生成（对应 C# `Code/InterfaceBuilder.BuildInterfaces`）。
//!
//! ## 它产出什么
//!
//! 把模型里每张表导成**对外契约**，两种形态：
//! - `csharpAlloc`：**C# 接口**文本（`public partial interface I{Name} { Int32 Id { get; set; } … }`）
//!   —— 与 C# 侧 `InterfaceBuilder` 同形，本仓与 C# 系统共用同一个 `Model.xml` 时可直接给对方编译；
//! - `jsonAlloc`：**机器可读契约**（表/列/类型/长度/精度/可空/主键/唯一/映射），供前端、其它语言、
//!   自动化对拍使用；字段顺序固定，便于 diff。
//!
//! ## 性能口径（这个库要撑上亿设备，生成器也不能乱分配）
//!
//! 生成是**一次性**动作（构建期/发版前），但实现仍按热路径的标准写：
//! - 单趟遍历，输出全部追加到**一个** `ArrayList`，进函数前按「表数 × (每表头 + 列数 × 每列估算)」
//!   `ensureTotalCapacity` 预留，避免逐字段增长重分配；
//! - 类型名/长度/精度用**栈上 bufPrint**，不产生临时堆分配；
//! - 字符串转义逐个字符 append，不先拼中间串。
//!
//! 用例里用**计数分配器**守住这一点：200 张表 × 20 列的模型，堆分配次数不得超过 8 次
//! （输出缓冲 1 次 + 极少数增长；一旦有人改成"每列 allocPrint" 就会红）。
//!
//! ## 与 C# 的差异
//! - C# 每张表**一个文件**（`Save`），这里返回一段文本，路径/编码由调用方决定；
//! - C# 的类名可被模型属性 `ModelInterface` 模板覆盖（`{name}` 占位）；这里用 `Options.prefix` +
//!   `class_name` 回调式覆盖（`nameTemplateAlloc`），不读模型私有属性；
//! - C# 的 `Option.Nullable` 只影响 `String`；这里同口径（`nullable_string`），其它类型不加 `?`。

const std = @import("std");
const model = @import("model.zig");

pub const Options = struct {
    /// 接口名前缀（C# 是 `"I" + Table.Name`）
    prefix: []const u8 = "I",
    /// 命名空间（空 = 不写 `namespace`）
    namespace: []const u8 = "",
    /// 可空字符串是否输出 `String?`（C# `BuilderOption.Nullable`）
    nullable_string: bool = true,
    /// 按 `Table@Name` 或 `Table@TableName` 排除整张表
    excludes: []const []const u8 = &.{},
    /// 按列名排除字段（所有表适用）
    exclude_columns: []const []const u8 = &.{},
};

/// 每表固定开销（`public partial interface Xxx\n{\n}\n`）估算，用于一次性预留输出缓冲。
const per_table_overhead: usize = 96;
/// 每列渲染开销估算（缩进 + 类型 + 名字 + `{ get; set; }` + 换行）。
const per_column_overhead: usize = 64;

/// 契约类名：`prefix ++ Table@Name`（对应 C# `ClassName = "I" + Table.Name`）。
pub fn classNameAlloc(a: std.mem.Allocator, table_name: []const u8, prefix: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, table_name });
}

/// 生成 C# 接口文本（所有表拼在一段里；调用方按表拆分也容易——每段以 `public partial interface` 开头）。
pub fn csharpAlloc(a: std.mem.Allocator, m: *const model.EntityModel, opts: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, estimateSize(m, opts));

    if (opts.namespace.len > 0) {
        try out.appendSlice(a, "namespace ");
        try out.appendSlice(a, opts.namespace);
        try out.appendSlice(a, "\n{\n");
    }

    for (m.tables) |*t| {
        if (isExcluded(t, opts)) continue;

        try out.appendSlice(a, "public partial interface ");
        try out.appendSlice(a, opts.prefix);
        try out.appendSlice(a, t.name);
        try out.appendSlice(a, "\n{\n");

        for (t.columns) |*col| {
            const fname = col.column_name orelse col.name;
            if (isColumnExcluded(col.name, opts) or isColumnExcluded(fname, opts)) continue;
            if (isModelFalse(col)) continue;

            // 注释：描述整体放进 <summary>（多行用空格压平，避免生成非法 XML 注释）
            if (col.description.len > 0) {
                try out.appendSlice(a, "    /// <summary>");
                try appendFlattened(a, &out, col.description);
                try out.appendSlice(a, "</summary>\n");
            }

            try out.appendSlice(a, "    ");
            try appendCsharpType(a, &out, col, opts);
            try out.append(a, ' ');
            try out.appendSlice(a, col.name);
            try out.appendSlice(a, " { get; set; }\n");
        }

        try out.appendSlice(a, "}\n");
        if (opts.namespace.len == 0) try out.append(a, '\n');
    }

    if (opts.namespace.len > 0) try out.appendSlice(a, "}\n");
    return out.toOwnedSlice(a);
}

/// 生成契约 JSON（结构固定：`{ "tables": [ { name, table_name, description, fields: [...], indexes: [...] } ] }`）。
pub fn jsonAlloc(a: std.mem.Allocator, m: *const model.EntityModel, opts: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    // JSON 里每列多几个键（类型/长度/精度/可空/主键/唯一/映射），估算值放大一些
    try out.ensureTotalCapacity(a, estimateSize(m, opts) * 2);

    try out.appendSlice(a, "{\"tables\":[");
    var first_table = true;
    for (m.tables) |*t| {
        if (isExcluded(t, opts)) continue;
        if (!first_table) try out.append(a, ',');
        first_table = false;

        try out.appendSlice(a, "{\"name\":");
        try appendJsonString(a, &out, t.name);
        try out.appendSlice(a, ",\"table_name\":");
        try appendJsonString(a, &out, t.effectiveTableName());
        try out.appendSlice(a, ",\"description\":");
        try appendJsonString(a, &out, t.description);
        try out.appendSlice(a, ",\"fields\":[");

        var first_field = true;
        for (t.columns) |*col| {
            const fname = col.column_name orelse col.name;
            if (isColumnExcluded(col.name, opts) or isColumnExcluded(fname, opts)) continue;
            if (isModelFalse(col)) continue;
            if (!first_field) try out.append(a, ',');
            first_field = false;

            try out.appendSlice(a, "{\"name\":");
            try appendJsonString(a, &out, col.name);
            try out.appendSlice(a, ",\"column_name\":");
            try appendJsonString(a, &out, fname);
            try out.appendSlice(a, ",\"type\":");
            try appendJsonString(a, &out, col.data_type.name());
            if (col.length > 0) {
                try out.appendSlice(a, ",\"length\":");
                try appendInt(a, &out, col.length);
            }
            if (col.precision > 0) {
                try out.appendSlice(a, ",\"precision\":");
                try appendInt(a, &out, col.precision);
                try out.appendSlice(a, ",\"scale\":");
                try appendInt(a, &out, col.scale);
            }
            try out.appendSlice(a, ",\"nullable\":");
            try out.appendSlice(a, if (col.nullable) "true" else "false");
            if (col.primary_key) try out.appendSlice(a, ",\"primary_key\":true");
            if (col.identity) try out.appendSlice(a, ",\"identity\":true");
            if (isSingleUnique(t, col)) try out.appendSlice(a, ",\"unique\":true");
            if (col.map) |mp| {
                if (mp.len > 0) {
                    try out.appendSlice(a, ",\"map\":");
                    try appendJsonString(a, &out, mp);
                }
            }
            if (col.enum_type) |et| {
                if (et.len > 0) {
                    try out.appendSlice(a, ",\"enum\":");
                    try appendJsonString(a, &out, et);
                }
            }
            try out.append(a, '}');
        }
        try out.appendSlice(a, "],\"indexes\":[");
        for (t.indexes, 0..) |idx, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, "{\"columns\":[");
            for (idx.columns, 0..) |c, ci| {
                if (ci > 0) try out.append(a, ',');
                try appendJsonString(a, &out, c);
            }
            try out.appendSlice(a, "],\"unique\":");
            try out.appendSlice(a, if (idx.unique) "true" else "false");
            try out.append(a, '}');
        }
        try out.appendSlice(a, "]}");
    }
    try out.appendSlice(a, "]}\n");
    return out.toOwnedSlice(a);
}

// ── 内部实现 ────────────────────────────────────────────────────────────────

fn estimateSize(m: *const model.EntityModel, opts: Options) usize {
    var n: usize = 64;
    for (m.tables) |*t| {
        if (isExcluded(t, opts)) continue;
        n += per_table_overhead;
        n += t.columns.len * per_column_overhead;
        n += t.indexes.len * 32;
    }
    return n;
}

/// C# 类型：优先模型里显式写的 `Type` 属性（C# `Properties["Type"]`），否则按标准类型名映射。
fn appendCsharpType(a: std.mem.Allocator, out: *std.ArrayList(u8), col: *const model.ColumnMeta, opts: Options) !void {
    if (extraValue(col, "Type")) |t| {
        if (t.len > 0) return out.appendSlice(a, t);
    }
    switch (col.data_type) {
        .boolean => try out.appendSlice(a, "Boolean"),
        .byte => try out.appendSlice(a, "Byte"),
        .int16 => try out.appendSlice(a, "Int16"),
        .int32 => try out.appendSlice(a, "Int32"),
        .int64 => try out.appendSlice(a, "Int64"),
        .single => try out.appendSlice(a, "Single"),
        .double => try out.appendSlice(a, "Double"),
        .decimal => try out.appendSlice(a, "Decimal"),
        .datetime => try out.appendSlice(a, "DateTime"),
        .binary => try out.appendSlice(a, "Byte[]"),
        .json => try out.appendSlice(a, "String"),
        .string => {
            // C# 口径：只有 String 在 Nullable 开关打开且列可空时才加 `?`
            if (opts.nullable_string and col.nullable) {
                try out.appendSlice(a, "String?");
            } else {
                try out.appendSlice(a, "String");
            }
        },
    }
}

/// 追加「压平换行」的文本（XML 注释里不能带裸换行）。
fn appendFlattened(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var last_space = false;
    for (text) |c| {
        const ch = switch (c) {
            '\r', '\n', '\t' => ' ',
            // XML 注释里 `--` 与 `<` 会破坏结构，换成安全字符
            '<' => '(',
            '>' => ')',
            else => c,
        };
        if (ch == ' ') {
            if (last_space) continue;
            last_space = true;
        } else {
            last_space = false;
        }
        try out.append(a, ch);
    }
}

/// JSON 字符串（只转必需字符；逐个 append，不拼中间串）。
fn appendJsonString(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(a, '"');
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                    try out.appendSlice(a, esc);
                } else {
                    try out.append(a, c);
                }
            },
        }
    }
    try out.append(a, '"');
}

fn appendInt(a: std.mem.Allocator, out: *std.ArrayList(u8), v: anytype) !void {
    var buf: [24]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try out.appendSlice(a, text);
}

fn extraValue(col: *const model.ColumnMeta, key: []const u8) ?[]const u8 {
    for (col.extra) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.key, key)) return kv.value;
    }
    return null;
}

/// C# `ValidColumn`：`Properties["Model"] == "False"` 的列不生成。
/// 本仓模型把 `Model` 解析进了 `ColumnMeta.model`（不是留在 `extra` 里）。
fn isModelFalse(col: *const model.ColumnMeta) bool {
    if (col.model) |v| {
        if (v.len > 0) return std.ascii.eqlIgnoreCase(v, "False");
    }
    const v = extraValue(col, "Model") orelse return false;
    return std.ascii.eqlIgnoreCase(v, "False");
}

fn isExcluded(t: *const model.TableMeta, opts: Options) bool {
    for (opts.excludes) |x| {
        if (std.ascii.eqlIgnoreCase(x, t.name)) return true;
        if (std.ascii.eqlIgnoreCase(x, t.effectiveTableName())) return true;
    }
    return false;
}

fn isColumnExcluded(name: []const u8, opts: Options) bool {
    for (opts.exclude_columns) |x| {
        if (std.ascii.eqlIgnoreCase(x, name)) return true;
    }
    return false;
}

fn isSingleUnique(t: *const model.TableMeta, col: *const model.ColumnMeta) bool {
    for (t.indexes) |idx| {
        if (!idx.unique or idx.columns.len != 1) continue;
        const c = idx.columns[0];
        if (std.ascii.eqlIgnoreCase(c, col.name)) return true;
        if (col.column_name) |cn| {
            if (std.ascii.eqlIgnoreCase(c, cn)) return true;
        }
    }
    return false;
}

// ── 用例 ────────────────────────────────────────────────────────────────────

/// 计数分配器：统计**分配次数**（不是字节数），用于守住「不要每字段 allocPrint」。
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawRemap(buf, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ret_addr);
    }

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

fn contractModel(a: std.mem.Allocator) !model.EntityModel {
    const xml =
        \\<EntityModel><Tables>
        \\  <Table Name="User" TableName="Sys_User" Description="用户表">
        \\    <Columns>
        \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" Description="主键" />
        \\      <Column Name="Name" DataType="String" Length="50" Nullable="True" Description="姓名" />
        \\      <Column Name="Inner" DataType="String" Length="10" Model="False" />
        \\    </Columns>
        \\    <Indexes><Index Columns="Name" Unique="True" /></Indexes>
        \\  </Table>
        \\  <Table Name="Temp" TableName="Sys_Temp">
        \\    <Columns><Column Name="Id" DataType="Int64" PrimaryKey="True" /></Columns>
        \\  </Table>
        \\</Tables></EntityModel>
    ;
    return model.EntityModel.parse(a, xml);
}

test "契约 - C# 接口：类型/可空 String/注释/排除 Model=False 列" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try contractModel(a);
    const text = try csharpAlloc(a, &m, .{});

    try std.testing.expect(std.mem.indexOf(u8, text, "public partial interface IUser\n{") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    Int32 Id { get; set; }") != null);
    // 可空 String → String?（C# BuilderOption.Nullable 口径）
    try std.testing.expect(std.mem.indexOf(u8, text, "    String? Name { get; set; }") != null);
    // 描述进 <summary>
    try std.testing.expect(std.mem.indexOf(u8, text, "/// <summary>姓名</summary>") != null);
    // Model=False 的列不生成
    try std.testing.expect(std.mem.indexOf(u8, text, "Inner") == null);
    // 第二张表
    try std.testing.expect(std.mem.indexOf(u8, text, "public partial interface ITemp") != null);
}

test "契约 - C# 接口：prefix / namespace / excludes 生效" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try contractModel(a);
    const text = try csharpAlloc(a, &m, .{
        .prefix = "I",
        .namespace = "My.Models",
        .excludes = &.{"Sys_Temp"},
        .nullable_string = false,
    });
    try std.testing.expect(std.mem.startsWith(u8, text, "namespace My.Models\n{\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "ITemp") == null);
    // 关掉 nullable_string 后不再有 String?
    try std.testing.expect(std.mem.indexOf(u8, text, "String?") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    String Name { get; set; }") != null);
}

test "契约 - JSON：可被解析回来，字段/类型/标记都对" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try contractModel(a);
    const text = try jsonAlloc(a, &m, .{});

    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    const tables = parsed.value.object.get("tables").?.array;
    try std.testing.expectEqual(@as(usize, 2), tables.items.len);

    const user = tables.items[0].object;
    try std.testing.expectEqualStrings("User", user.get("name").?.string);
    try std.testing.expectEqualStrings("Sys_User", user.get("table_name").?.string);

    const fields = user.get("fields").?.array;
    try std.testing.expectEqual(@as(usize, 2), fields.items.len); // Model=False 的列不进契约
    const id = fields.items[0].object;
    try std.testing.expectEqualStrings("Id", id.get("name").?.string);
    try std.testing.expectEqualStrings("Int32", id.get("type").?.string);
    try std.testing.expect(id.get("identity").?.bool);
    try std.testing.expect(id.get("primary_key").?.bool);

    const name = fields.items[1].object;
    try std.testing.expectEqualStrings("String", name.get("type").?.string);
    try std.testing.expect(name.get("nullable").?.bool);
    try std.testing.expect(name.get("unique").?.bool); // 单列唯一索引
    try std.testing.expectEqual(@as(i64, 50), name.get("length").?.integer);

    // 索引段
    const indexes = user.get("indexes").?.array;
    try std.testing.expectEqual(@as(usize, 1), indexes.items.len);
    try std.testing.expect(indexes.items[0].object.get("unique").?.bool);
}

test "契约 - 生成过程不发生逐字段堆分配（200 表 × 20 列，分配次数 ≤ 8）" {
    const a = std.testing.allocator;

    // 构造 200 张表 × 20 列的模型（每列都带描述，逼出最坏情况）
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(a);
    try xml.appendSlice(a, "<EntityModel><Tables>");
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try xml.appendSlice(a, try std.fmt.bufPrint(&buf, "<Table Name=\"T{d}\" TableName=\"Db_T{d}\">", .{ i, i }));
        try xml.appendSlice(a, "<Columns>");
        var j: usize = 0;
        while (j < 20) : (j += 1) {
            try xml.appendSlice(a, try std.fmt.bufPrint(
                &buf,
                "<Column Name=\"C{d}\" DataType=\"String\" Length=\"32\" Description=\"列 {d} 的说明\"/>",
                .{ j, j },
            ));
        }
        try xml.appendSlice(a, "</Columns></Table>");
    }
    try xml.appendSlice(a, "</Tables></EntityModel>");

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var m = try model.EntityModel.parse(arena.allocator(), xml.items);

    var ctx = CountingAllocator.init(a);
    const ca = ctx.allocator();

    {
        const out = try csharpAlloc(ca, &m, .{});
        a.free(out);
    }
    {
        const out = try jsonAlloc(ca, &m, .{});
        a.free(out);
    }

    // 预留了容量 → 输出缓冲基本只分配一次；一旦有人改成"每列 allocPrint"，这里会飙到几千
    try std.testing.expect(ctx.allocs <= 8);
}
