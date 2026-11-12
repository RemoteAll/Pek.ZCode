//! 代码生成：`Model.xml` → Zig 实体（对应 DH.NCode `XCodeTool` / Rust `Pek.RCode/src/codegen.rs`）。
//!
//! 生成的结构体满足 `entity.zig` 的「实体契约」：`meta` / `dirty` / `columnValue` / `setColumnValue`
//!  + 每列的 `getXxx` / `setXxx`（setter 自动置脏）。
//!
//! 与 Rust 版一致：实体必须**生成**而不能手写——手写实体没有脏位图，`update` 会写全部非主键列。
//!
//! 用法：
//! ```powershell
//! zig build codegen -- --model Entity\Model.xml --out src\entities
//! ```

const std = @import("std");
const zzig = @import("zzig");
const model = @import("model.zig");
const EntityModel = model.EntityModel;
const TableMeta = model.TableMeta;
const ColumnMeta = model.ColumnMeta;
const DataType = model.DataType;

pub const Options = struct {
    out_dir: []const u8,
    /// 只生成指定表（实体名或物理表名，忽略大小写）
    table: ?[]const u8 = null,
    /// 只打印不落盘
    dry_run: bool = false,
    /// 生成代码里的 `zcode` 导入路径。
    ///
    /// 默认 `zcode`（包外消费方）；**库内自用**（如 `src/membership/entities/`）要传相对路径，
    /// 否则 `@import("zcode")` 在自身包里会变成循环依赖。
    import: []const u8 = "zcode",
};

pub const Report = struct {
    tables: usize = 0,
    files: usize = 0,
};

/// 生成全部表的实体文件（外加 `mod.zig` 索引）。
pub fn generateAll(gpa: std.mem.Allocator, m: *const EntityModel, opts: Options) !Report {
    if (!opts.dry_run) try zzig.compat.fs.cwd().makePath(opts.out_dir);

    var report = Report{};
    var modules: std.ArrayList([]const u8) = .empty;
    defer {
        for (modules.items) |s| gpa.free(s);
        modules.deinit(gpa);
    }

    for (m.tables) |*t| {
        if (opts.table) |want| {
            if (!std.ascii.eqlIgnoreCase(t.name, want) and
                !std.ascii.eqlIgnoreCase(t.effectiveTableName(), want)) continue;
        }
        const src = try generateTableAllocOpt(gpa, t, .{ .out_dir = opts.out_dir, .import = opts.import });
        defer gpa.free(src);

        if (opts.dry_run) {
            std.debug.print("===== {s}.zig =====\n{s}\n", .{ t.name, src });
        } else {
            const safe = try fileSafeName(gpa, t.name);
            defer gpa.free(safe);
            const file_name = try std.fmt.allocPrint(gpa, "{s}.zig", .{safe});
            defer gpa.free(file_name);
            const path = try std.fs.path.join(gpa, &.{ opts.out_dir, file_name });
            defer gpa.free(path);
            try zzig.File.WriteAll(path, src);
            report.files += 1;
        }
        try modules.append(gpa, try gpa.dupe(u8, t.name));
        report.tables += 1;
    }

    if (!opts.dry_run) {
        const index = try moduleIndexAlloc(gpa, modules.items);
        defer gpa.free(index);
        const path = try std.fs.path.join(gpa, &.{ opts.out_dir, "mod.zig" });
        defer gpa.free(path);
        try zzig.File.WriteAll(path, index);
        report.files += 1;
    }
    return report;
}

/// 单表源码。
pub fn generateTableAlloc(gpa: std.mem.Allocator, t: *const TableMeta) ![]u8 {
    return generateTableAllocOpt(gpa, t, .{ .out_dir = "" });
}

/// 单表源码（可指定导入路径）。
pub fn generateTableAllocOpt(gpa: std.mem.Allocator, t: *const TableMeta, opts: Options) ![]u8 {
    var b = zzig.Buf.init(gpa);
    defer b.deinit();

    try b.add("//! 由 zcodegen 生成，请勿手改。\n");
    try b.add("//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>\n");
    if (t.description.len > 0) {
        try b.add("//! ");
        try addOneLine(&b, t.description);
        try b.add("\n");
    }
    try b.fmt("const zcode = @import(\"{s}\");\n\n", .{opts.import});

    try b.fmt("pub const {s} = struct {{\n", .{t.name});
    try b.add("    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）\n");
    try b.add("    dirty: zcode.entity.DirtyBits = 0,\n\n");

    for (t.columns) |*c| {
        if (c.description.len > 0) {
            try b.add("    /// ");
            try addOneLine(&b, c.description);
            try b.add("\n");
        }
        try b.fmt("    @\"{s}\": {s}{s},\n", .{
            c.name,
            zigType(c.data_type),
            defaultInit(c.data_type),
        });
    }
    try b.add("\n");

    // meta
    try b.add("    pub const meta = zcode.entity.EntityMeta{\n");
    try b.fmt("        .name = \"{s}\",\n", .{t.name});
    try b.fmt("        .table_name = \"{s}\",\n", .{t.effectiveTableName()});
    try b.add("        .fields = &.{\n");
    for (t.columns) |*c| {
        try b.fmt("            .{{ .name = \"{s}\", .data_type = .{s}", .{ c.name, @tagName(c.data_type) });
        if (c.primary_key) try b.add(", .primary_key = true");
        if (c.identity) try b.add(", .identity = true");
        if (c.nullable) try b.add(", .nullable = true");
        if (c.additional) try b.add(", .additional = true");
        if (c.length > 0) try b.fmt(", .length = {d}", .{c.length});
        if (c.precision > 0) try b.fmt(", .precision = {d}", .{c.precision});
        if (c.scale > 0) try b.fmt(", .scale = {d}", .{c.scale});
        if (!std.mem.eql(u8, c.name, t.effectiveColumnName(c))) {
            try b.fmt(", .column_name = \"{s}\"", .{t.effectiveColumnName(c)});
        }
        if (c.description.len > 0) {
            try b.add(", .description = \"");
            try addOneLine(&b, c.description);
            try b.add("\"");
        }
        try b.add(" },\n");
    }
    try b.add("        },\n    };\n\n");

    // 主键 / 自增 / 累加字段的列下标（避免业务代码自己数下标）
    try b.add("    /// 主键列下标（按模型声明顺序）\n");
    try b.add("    pub const main_keys: []const usize = &.{");
    {
        var first = true;
        for (t.columns, 0..) |*c, i| {
            if (!c.primary_key) continue;
            if (!first) try b.add(", ");
            first = false;
            try b.fmt("{d}", .{i});
        }
    }
    try b.add("};\n");

    if (t.identity() != null) {
        for (t.columns, 0..) |*c, i| {
            if (!c.identity) continue;
            try b.fmt("    /// 自增列下标（{s}）\n", .{c.name});
            try b.fmt("    pub const identity_index: usize = {d};\n", .{i});
            break;
        }
    }
    {
        const adds = try t.additionalFields(gpa);
        defer if (adds.len > 0) gpa.free(adds);
        if (adds.len > 0) {
            try b.add("    /// 累加字段列下标（更新时按 `col + 值`）\n");
            try b.add("    pub const additional_indexes: []const usize = &.{");
            var first = true;
            for (adds) |a| {
                for (t.columns, 0..) |*c, i| {
                    if (!std.mem.eql(u8, c.name, a.name)) continue;
                    if (!first) try b.add(", ");
                    first = false;
                    try b.fmt("{d}", .{i});
                    break;
                }
            }
            try b.add("};\n");
        }
    }
    try b.add("\n");

    // 索引元数据（与 Model.xml 同源，建表/对账都靠它）
    if (t.indexes.len > 0) {
        try b.add("    /// 索引（对应 `Model.xml` 的 `Index`）\n");
        try b.add("    pub const indexes = [_]zcode.codegen.IndexInfo{\n");
        for (t.indexes) |idx| {
            try b.add("        .{ ");
            if (idx.name) |n| try b.fmt(".name = \"{s}\", ", .{n});
            try b.add(".columns = &.{");
            for (idx.columns, 0..) |col, i| {
                if (i > 0) try b.add(", ");
                try b.fmt("\"{s}\"", .{col});
            }
            try b.fmt("}}, .unique = {s}", .{if (idx.unique) "true" else "false"});
            if (idx.expression) |e| try b.fmt(", .expression = \"{s}\"", .{e});
            try b.add(" },\n");
        }
        try b.add("    };\n\n");
    }

    // 表句柄（业务代码拿它做表级操作，不需要自己拼表名）
    try b.add("    /// 取表句柄（表级 CRUD / 分片路由都用它）。\n");
    try b.add("    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {\n");
    try b.fmt("        return dal.table(\"{s}\");\n", .{t.effectiveTableName()});
    try b.add("    }\n");

    // 访问器
    for (t.columns, 0..) |*c, i| {
        const suffix = try accessorName(gpa, c.name);
        defer gpa.free(suffix);
        try b.fmt("    pub fn get{s}(self: @This()) {s} {{ return self.@\"{s}\"; }}\n", .{ suffix, zigType(c.data_type), c.name });
        try b.fmt("    pub fn set{s}(self: *@This(), v: {s}) void {{\n", .{ suffix, zigType(c.data_type) });
        try b.fmt("        self.@\"{s}\" = v;\n", .{c.name});
        try b.fmt("        zcode.entity.markDirty(&self.dirty, {d});\n    }}\n", .{i});
    }
    try b.add("\n");

    // columnValue
    try b.add("    /// 读取第 i 列（与 meta.fields 同序）。\n");
    try b.add("    pub fn columnValue(self: @This(), i: usize) zcode.Value {\n");
    try b.add("        return switch (i) {\n");
    for (t.columns, 0..) |*c, i| {
        try b.fmt("            {d} => ", .{i});
        try addValueExpr(&b, c.data_type, c.name);
        try b.add(",\n");
    }
    try b.add("            else => .{ .null = {} },\n        };\n    }\n\n");

    // setColumnValue
    try b.add("    /// 装载第 i 列（不置脏）。\n");
    try b.add("    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {\n");
    try b.add("        switch (i) {\n");
    for (t.columns, 0..) |*c, i| {
        try b.fmt("            {d} => {{ ", .{i});
        try addAssignStmt(&b, c.data_type, c.name);
        try b.add(" },\n");
    }
    try b.add("            else => {},\n        }\n    }\n");
    try b.add("};\n");

    return b.toOwnedSlice();
}

/// 实体索引文件。
pub fn moduleIndexAlloc(gpa: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var b = zzig.Buf.init(gpa);
    defer b.deinit();
    try b.add("//! 由 zcodegen 生成：实体索引，请勿手改。\n\n");
    for (names) |n| {
        const safe = try fileSafeName(gpa, n);
        defer gpa.free(safe);
        try b.fmt("pub const {s} = @import(\"{s}.zig\").{s};\n", .{ n, safe, n });
    }
    if (names.len > 0) {
        try b.add("\n/// 全部实体（用 `inline for (all) |T|` 编译期逐个处理）\n");
        try b.add("pub const all = .{");
        for (names, 0..) |n, i| {
            if (i > 0) try b.add(", ");
            try b.add(n);
        }
        try b.add("};\n");
    }
    return b.toOwnedSlice();
}

fn zigType(dt: DataType) []const u8 {
    return switch (dt) {
        .boolean => "bool",
        .byte => "u8",
        .int16 => "i16",
        .int32 => "i32",
        .int64 => "i64",
        .single => "f32",
        .double => "f64",
        .decimal => "zcode.Decimal",
        .string, .json => "[]const u8",
        .datetime => "zcode.DateTime",
        .binary => "[]const u8",
    };
}

fn defaultInit(dt: DataType) []const u8 {
    return switch (dt) {
        .boolean => " = false",
        .byte, .int16, .int32, .int64 => " = 0",
        .single, .double => " = 0",
        .decimal => " = .{ .mantissa = 0, .scale = 0 }",
        .string, .json, .binary => " = \"\"",
        .datetime => " = .{}",
    };
}

fn addValueExpr(b: *zzig.Buf, dt: DataType, name: []const u8) !void {
    switch (dt) {
        .boolean => try b.fmt(".{{ .boolean = self.@\"{s}\" }}", .{name}),
        .byte, .int16, .int32, .int64 => try b.fmt(".{{ .int = @intCast(self.@\"{s}\") }}", .{name}),
        .single => try b.fmt(".{{ .float = @floatCast(self.@\"{s}\") }}", .{name}),
        .double => try b.fmt(".{{ .float = self.@\"{s}\" }}", .{name}),
        .decimal => try b.fmt(".{{ .decimal = self.@\"{s}\" }}", .{name}),
        .datetime => try b.fmt(".{{ .datetime = self.@\"{s}\" }}", .{name}),
        .string, .json => try b.fmt(".{{ .text = self.@\"{s}\" }}", .{name}),
        .binary => try b.fmt(".{{ .blob = self.@\"{s}\" }}", .{name}),
    }
}

fn addAssignStmt(b: *zzig.Buf, dt: DataType, name: []const u8) !void {
    switch (dt) {
        .boolean => try b.fmt("self.@\"{s}\" = v.asBool() orelse false;", .{name}),
        .byte => try b.fmt("self.@\"{s}\" = v.asU8() orelse 0;", .{name}),
        .int16 => try b.fmt("self.@\"{s}\" = v.asI16() orelse 0;", .{name}),
        .int32 => try b.fmt("self.@\"{s}\" = v.asI32() orelse 0;", .{name}),
        .int64 => try b.fmt("self.@\"{s}\" = v.asI64() orelse 0;", .{name}),
        .single => try b.fmt("self.@\"{s}\" = v.asF32() orelse 0;", .{name}),
        .double => try b.fmt("self.@\"{s}\" = v.asF64() orelse 0;", .{name}),
        .decimal => try b.fmt("self.@\"{s}\" = v.asDecimal() orelse .{{ .mantissa = 0, .scale = 0 }};", .{name}),
        .datetime => try b.fmt("self.@\"{s}\" = v.asDatetime() orelse .{{}};", .{name}),
        .string, .json => try b.fmt("switch (v) {{ .text => |t| self.@\"{s}\" = t, .null => self.@\"{s}\" = \"\", else => {{}} }}", .{ name, name }),
        .binary => try b.fmt("switch (v) {{ .blob => |b| self.@\"{s}\" = b, .null => self.@\"{s}\" = \"\", else => {{}} }}", .{ name, name }),
    }
}

/// 索引元数据（生成代码里以 `indexes` 常量形式出现）。
pub const IndexInfo = struct {
    name: []const u8 = "",
    columns: []const []const u8 = &.{},
    unique: bool = false,
    expression: ?[]const u8 = null,
};

/// 文件名安全化（保留 ASCII 字母数字与 `_`，其余换 `_`）。
fn fileSafeName(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
    }
    if (out.len == 0) {
        gpa.free(out);
        return gpa.dupe(u8, "Entity");
    }
    return out;
}

/// 访问器后缀：非字母数字换 `_`，首字符是数字时补 `_`。
fn accessorName(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, name.len + 1);
    var n: usize = 0;
    if (name.len > 0 and std.ascii.isDigit(name[0])) {
        out[0] = '_';
        n = 1;
    }
    for (name) |c| {
        out[n] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
        n += 1;
    }
    return gpa.realloc(out, n);
}

fn addOneLine(b: *zzig.Buf, text: []const u8) !void {
    for (text) |c| {
        try b.addByte(if (c == '\n' or c == '\r' or c == '\t') ' ' else c);
    }
}

test "生成实体：meta/脏位/取值与装载" {
    const xml =
        \\<EntityModel><Tables><Table Name="Article" TableName="ZCode_Article">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Title" DataType="String" Length="100" />
        \\    <Column Name="Score" DataType="Int64" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();

    const src = try generateTableAlloc(std.testing.allocator, &m.tables[0]);
    defer std.testing.allocator.free(src);

    try std.testing.expect(std.mem.indexOf(u8, src, "pub const Article = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".table_name = \"ZCode_Article\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".{ .name = \"Id\", .data_type = .int32, .primary_key = true, .identity = true }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "zcode.entity.markDirty(&self.dirty, 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".{ .int = @intCast(self.@\"Score\") }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "self.@\"Score\" = v.asI64() orelse 0;") != null);
}
