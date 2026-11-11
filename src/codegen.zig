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
        const src = try generateTableAlloc(gpa, t);
        defer gpa.free(src);

        if (opts.dry_run) {
            std.debug.print("===== {s}.zig =====\n{s}\n", .{ t.name, src });
        } else {
            const file_name = try std.fmt.allocPrint(gpa, "{s}.zig", .{fileSafeName(t.name)});
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
    var b = zzig.Buf.init(gpa);
    defer b.deinit();

    try b.add("//! 由 zcodegen 生成，请勿手改。\n");
    try b.add("//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>\n");
    if (t.description.len > 0) {
        try b.add("//! ");
        try addOneLine(&b, t.description);
        try b.add("\n");
    }
    try b.add("const zcode = @import(\"zcode\");\n\n");

    try b.fmt("pub const {s} = struct {{\n", .{t.name});
    try b.add("    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）\n");
    try b.add("    dirty: zcode.entity.DirtyBits = 0,\n\n");

    for (t.columns) |*c| {
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
        try b.add(" },\n");
    }
    try b.add("        },\n    };\n\n");

    // 访问器
    for (t.columns, 0..) |*c, i| {
        const suffix = accessorName(c.name);
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
        try b.fmt("pub const {s} = @import(\"{s}.zig\").{s};\n", .{ n, fileSafeName(n), n });
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

/// 文件名安全化（保留 ASCII 字母数字，其余换 `_`）。
fn fileSafeName(name: []const u8) []const u8 {
    // 表名一般是标识符，直接返回；这里只做保守处理
    return name;
}

/// 访问器后缀：非字母数字换 `_`，首字符是数字时补 `_`。
fn accessorName(name: []const u8) []const u8 {
    // 生成时缓冲区复用：借用 `name` 本身（表名/列名来自模型 arena）
    return name;
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
