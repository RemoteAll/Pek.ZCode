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
    /// 是否同时产出业务扩展文件（`{Name}.biz.zig`）。
    ///
    /// 对应 C# 的 `Xxx.cs`（生成）+ `Xxx.Biz.cs`（手写）两分：
    /// - 基础文件每次生成都**覆盖**（数据契约：字段/meta/CRUD/缓存/校验）；
    /// - 业务文件**只在不存在时创建**，已有内容永不覆盖（派生属性、领域方法写到那里）。
    biz: bool = true,
    /// 强制重写业务文件（会丢掉手写内容，仅用于确认要重建模板时）
    force_biz: bool = false,
};

pub const Report = struct {
    tables: usize = 0,
    files: usize = 0,
    /// 本次写入的业务扩展文件数
    biz_written: usize = 0,
    /// 已存在而保留的业务扩展文件数
    biz_kept: usize = 0,
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

            // 业务扩展文件：只在不存在时创建（对齐 C# 的 `Xxx.Biz.cs` 不被覆盖）
            if (opts.biz) {
                const biz_name = try std.fmt.allocPrint(gpa, "{s}.biz.zig", .{safe});
                defer gpa.free(biz_name);
                const biz_path = try std.fs.path.join(gpa, &.{ opts.out_dir, biz_name });
                defer gpa.free(biz_path);
                if (opts.force_biz or !fileExists(biz_path)) {
                    const biz_src = try bizTemplateAlloc(gpa, t, opts);
                    defer gpa.free(biz_src);
                    try zzig.File.WriteAll(biz_path, biz_src);
                    report.files += 1;
                    report.biz_written += 1;
                } else {
                    report.biz_kept += 1;
                }
            }
        }
        try modules.append(gpa, try gpa.dupe(u8, t.name));
        report.tables += 1;
    }

    if (!opts.dry_run) {
        const index = try moduleIndexAllocOpt(gpa, modules.items, opts.biz);
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
    // 用 `checkMeta(...)` 包起来：列数超过脏位图宽度（256）时在**编译期**报错，
    // 不要拖到运行期由 `markDirty` 的位移溢出暴露（ReleaseFast 下是 UB）。
    try b.add("    pub const meta = zcode.entity.checkMeta(zcode.entity.EntityMeta{\n");
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
    try b.add("        },\n    });\n\n");

    // 列名常量（对应 C# 生成物里的 `__` 内部类）：业务代码不要再手写列名字符串。
    // 用 `@"..."` 形式，列名是关键字或含空格也能用。
    try b.add("    /// 列名常量（写 SQL / `Where` / `Field` 时引用这里）\n");
    try b.add("    pub const Field = struct {\n");
    for (t.columns) |*c| {
        try b.fmt("        pub const @\"{s}\" = \"{s}\";\n", .{ c.name, c.name });
    }
    try b.add("    };\n\n");

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
    try b.add("    }\n\n");

    // 缓存能力声明（对齐 C# 的 `MaxCacheCount`）：0 = 不参与整表缓存
    try b.fmt("    /// 模型 `MaxCacheCount`（0 = 不参与整表缓存）\n    pub const max_cache_count: i32 = {d};\n\n", .{t.max_cache_count});

    // 实例 CRUD（对齐 C# 实体上的 `Insert/Update/Delete/Save`）
    try b.add("    /// 插入一行（自增 ID 回写到自身）。\n");
    try b.add("    pub fn insert(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !i64 {\n        return zcode.entity.insert(dal, self, s);\n    }\n\n");
    try b.add("    /// 只更新脏列（无脏列不发 SQL）。\n");
    try b.add("    pub fn update(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !usize {\n        return zcode.entity.update(dal, self, s);\n    }\n\n");
    try b.add("    /// 按主键删除。\n");
    try b.add("    pub fn delete(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !usize {\n        return zcode.entity.delete(dal, self, s);\n    }\n\n");
    try b.add("    /// 保存：主键空则插入，否则更新（对齐 XCode `Save`）。\n");
    try b.add("    pub fn save(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !i64 {\n        return zcode.entity.save(dal, self, s);\n    }\n\n");

    // 静态查询（对齐 C# 生成的 `Find/FindAll/FindByKey/FindByName`）
    try b.add("    /// 按主键值取一行（支持复合主键：按 `meta.fields` 中主键顺序传值）。\n");
    try b.add("    pub fn findByKey(dal: *zcode.Dal, s: *zcode.Session, pk_values: []const zcode.Value) !?@This() {\n        return zcode.entity.findByPk(dal, @This(), s, pk_values);\n    }\n\n");
    {
        // 单一整型主键时多给一个强类型便利方法（业务代码最常用）
        var pk_count: usize = 0;
        var pk_is_int = false;
        for (t.columns) |*c| {
            if (!c.primary_key) continue;
            pk_count += 1;
            pk_is_int = switch (c.data_type) {
                .byte, .int16, .int32, .int64 => true,
                else => false,
            };
        }
        if (pk_count == 1 and pk_is_int) {
            try b.add("    /// 按主键取一行（单主键便利版）。\n");
            try b.add("    pub fn findByPk(dal: *zcode.Dal, s: *zcode.Session, pk: i64) !?@This() {\n        return zcode.entity.findByPk(dal, @This(), s, &.{.{ .int = pk }});\n    }\n\n");
        }
    }
    try b.add("    /// 条件查询（分页/排序/列选择同 `Query`）。\n");
    try b.add("    pub fn query(dal: *zcode.Dal, s: *zcode.Session, q: *const zcode.Query) ![]@This() {\n        return zcode.entity.queryRows(dal, @This(), s, q);\n    }\n\n");
    try b.add("    /// 计数。\n");
    try b.add("    pub fn count(dal: *zcode.Dal, s: *zcode.Session, filter: ?*const zcode.Where) !i64 {\n        return zcode.entity.count(dal, @This(), s, filter);\n    }\n\n");

    // 两级缓存的入口（TTL 缺省跟着全局 `Setting`）
    try b.add("    /// 整表缓存：小表常驻，配词查询不再打库；行数超过 `max_cache_count` 时自动退回查库。\n");
    try b.add("    pub fn cache(dal: *zcode.Dal) zcode.cache.Cache(@This()) {\n        return zcode.cache.Cache(@This()).init(dal, zcode.setting.current().entity_cache_expire);\n    }\n\n");
    try b.add("    /// 单对象缓存：大表按主键取，只缓存访问过的行。\n");
    try b.add("    pub fn singleCache(dal: *zcode.Dal) zcode.cache.SingleCache(@This()) {\n        return zcode.cache.SingleCache(@This()).init(dal, zcode.setting.current().single_cache_expire);\n    }\n\n");

    // 必填校验（对应 C# 生成的 `Valid`）
    try b.add("    /// 必填校验：返回第一个为空的非空字符列名，全通过返回 null。\n");
    try b.add("    pub fn valid(self: *const @This()) ?[]const u8 {\n        return zcode.entity_ext.checkRequired(self);\n    }\n\n");

    // 访问器
    for (t.columns, 0..) |*c, i| {
        const suffix = try accessorName(gpa, c.name);
        defer gpa.free(suffix);
        try b.fmt("    pub fn get{s}(self: @This()) {s} {{ return self.@\"{s}\"; }}\n", .{ suffix, zigType(c.data_type), c.name });
        try b.fmt("    pub fn set{s}(self: *@This(), v: {s}) void {{\n", .{ suffix, zigType(c.data_type) });
        // 「未改不置脏」：值相同时直接返回。这是 `update` 只写脏列的前提，
        // 也让批量写不会把「赋了相同值」的列带进 SQL（对齐 Rust Pek.RCode 的 dirty 口径）。
        try b.fmt("        if (zcode.entity.valueEql(self.@\"{s}\", v)) return;\n", .{c.name});
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
    return moduleIndexAllocOpt(gpa, names, false);
}

/// 实体索引文件（可附带业务扩展模块的导出）。
pub fn moduleIndexAllocOpt(gpa: std.mem.Allocator, names: []const []const u8, with_biz: bool) ![]u8 {
    var b = zzig.Buf.init(gpa);
    defer b.deinit();
    try b.add("//! 由 zcodegen 生成：实体索引，请勿手改。\n//!\n");
    try b.add("//! 约定：`{Name}.zig` 是生成的数据契约（会覆盖）；`{Name}.biz.zig` 是业务扩展（不覆盖）。\n\n");
    for (names) |n| {
        const safe = try fileSafeName(gpa, n);
        defer gpa.free(safe);
        try b.fmt("pub const {s} = @import(\"{s}.zig\").{s};\n", .{ n, safe, n });
    }
    if (with_biz and names.len > 0) {
        try b.add("\n/// 业务扩展模块（`{Name}.biz.zig`，手写代码放这里）\n");
        for (names) |n| {
            const safe = try fileSafeName(gpa, n);
            defer gpa.free(safe);
            try b.fmt("pub const {s}Biz = @import(\"{s}.biz.zig\");\n", .{ n, safe });
        }
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

/// 业务扩展文件模板（对应 C# 的 `Xxx.Biz.cs`）：生成器只在文件不存在时写一次。
///
/// 单向依赖：本文件 import 基础文件，基础文件**不** import 本文件，所以不会循环导入。
pub fn bizTemplateAlloc(gpa: std.mem.Allocator, t: *const TableMeta, opts: Options) ![]u8 {
    var b = zzig.Buf.init(gpa);
    defer b.deinit();

    try b.fmt("//! {s} 的业务扩展（**手写文件，重新生成实体时不会被覆盖**）。\n", .{t.name});
    try b.add("//!\n");
    try b.add("//! 分工：\n");
    try b.fmt("//! - `{s}.zig`：生成器产出并覆盖（字段 / meta / CRUD / 缓存 / 必填校验）；\n", .{t.name});
    try b.fmt("//! - `{s}.biz.zig`（本文件）：派生属性、领域方法、跨表联动、业务校验。\n", .{t.name});
    try b.add("//!\n");
    try b.add("//! 依赖方向只有一条：本文件 import 基础文件，基础文件不 import 本文件（不会循环导入）。\n\n");
    try b.fmt("const zcode = @import(\"{s}\");\n", .{opts.import});
    try b.fmt("const {s} = @import(\"{s}.zig\").{s};\n\n", .{ t.name, t.name, t.name });

    // 一个必定能编译的示例：转发生成侧必填校验（业务层只 import 一个文件就够）
    try b.add("/// 必填校验（转发到生成侧；返回第一个为空的列名，`null` = 通过）。\n");
    try b.fmt("pub fn valid(e: *const {s}) ?[]const u8 {{\n", .{t.name});
    try b.add("    return e.valid();\n}\n\n");

    try b.add("// ── 下面按需展开（示例，取消注释后按业务改）──────────────────────\n");
    try b.add("//\n");
    try b.add("// /// 派生属性：不落库，仅展示/导出用。\n");
    try b.fmt("// pub fn display(e: *const {s}) []const u8 {{\n", .{t.name});
    try b.add("//     return e.Name; // 换成实际列\n");
    try b.add("// }\n");
    try b.add("//\n");
    try b.add("// /// 保存前校验：配合 `try valid(e)` 在插入/更新前调用。\n");
    try b.fmt("// pub fn checkBeforeSave(e: *const {s}) !void {{\n", .{t.name});
    try b.add("//     if (e.valid()) |missing| return error.MissingField;\n");
    try b.add("// }\n");
    try b.add("//\n");
    try b.add("// /// 领域方法：例如把状态机迁移写在这里（需要 dal/session 就作为参数传进来）。\n");
    try b.fmt("// pub fn activate(e: *{s}, dal: *zcode.Dal, s: *zcode.Session) !void {{\n", .{t.name});
    try b.add("//     _ = try e.update(dal, s);\n");
    try b.add("// }\n");

    return b.toOwnedSlice();
}

/// 文件是否存在（`statFile` 抛错即视为不存在）。
fn fileExists(path: []const u8) bool {
    _ = zzig.compat.fs.cwd().statFile(path) catch return false;
    return true;
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
        // GUID 用 36 位字符表示（不引入单独的 Guid 类型）
        .guid => "[]const u8",
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
        .guid => " = \"\"",
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
        .guid => try b.fmt(".{{ .text = self.@\"{s}\" }}", .{name}),
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
        .guid => try b.fmt("switch (v) {{ .text => |t| self.@\"{s}\" = t, .null => self.@\"{s}\" = \"\", else => {{}} }}", .{ name, name }),
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

test "生成实体：Guid 列生成 []const u8 + .text 包装（不引入单独类型）" {
    const xml =
        \\<EntityModel><Tables><Table Name="Doc" TableName="ZCode_Doc">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Token" DataType="Guid" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();

    const src = try generateTableAlloc(std.testing.allocator, &m.tables[0]);
    defer std.testing.allocator.free(src);

    // 字段声明：字符串形态（有默认空串）
    try std.testing.expect(std.mem.indexOf(u8, src, "@\"Token\": []const u8 = \"\"") != null);
    // 元数据：类型是 guid
    try std.testing.expect(std.mem.indexOf(u8, src, ".{ .name = \"Token\", .data_type = .guid }") != null);
    // 写库取值：包成 .text
    try std.testing.expect(std.mem.indexOf(u8, src, ".{ .text = self.@\"Token\" }") != null);
    // 读库赋值：从 .text 取
    try std.testing.expect(std.mem.indexOf(u8, src, "switch (v) { .text => |t| self.@\"Token\" = t") != null);
}

test "生成实体：双文件契约（基础文件 + 业务扩展模板）" {
    const xml =
        \\<EntityModel><Tables><Table Name="Article" TableName="ZCode_Article" MaxCacheCount="500">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Name" DataType="String" Length="100" />
        \\    <Column Name="Score" DataType="Int64" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    ;
    var m = try EntityModel.parse(std.testing.allocator, xml);
    defer m.deinit();
    const t = &m.tables[0];

    // 基础文件：数据契约 + 便捷成员
    const base = try generateTableAllocOpt(std.testing.allocator, t, .{ .out_dir = "", .import = "zcode" });
    defer std.testing.allocator.free(base);
    try std.testing.expect(std.mem.indexOf(u8, base, "pub const Field = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "pub const max_cache_count: i32 = 500;") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "pub fn save(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "pub fn findByPk(dal: *zcode.Dal, s: *zcode.Session, pk: i64) !?@This()") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "pub fn cache(dal: *zcode.Dal) zcode.cache.Cache(@This())") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "pub fn singleCache(dal: *zcode.Dal) zcode.cache.SingleCache(@This())") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "pub fn valid(self: *const @This()) ?[]const u8") != null);

    // 业务文件：单向依赖 + 不被覆盖的标记
    const biz = try bizTemplateAlloc(std.testing.allocator, t, .{ .out_dir = "", .import = "zcode" });
    defer std.testing.allocator.free(biz);
    try std.testing.expect(std.mem.indexOf(u8, biz, "不会被覆盖") != null);
    try std.testing.expect(std.mem.indexOf(u8, biz, "const Article = @import(\"Article.zig\").Article;") != null);
    try std.testing.expect(std.mem.indexOf(u8, biz, "pub fn valid(e: *const Article) ?[]const u8") != null);
    // 基础文件不得反向 import 业务文件（否则循环导入）
    try std.testing.expect(std.mem.indexOf(u8, base, ".biz.zig") == null);

    // 索引：可选导出 Biz 模块
    const idx = try moduleIndexAllocOpt(std.testing.allocator, &.{"Article"}, true);
    defer std.testing.allocator.free(idx);
    try std.testing.expect(std.mem.indexOf(u8, idx, "pub const ArticleBiz = @import(\"Article.biz.zig\");") != null);
    const idx2 = try moduleIndexAllocOpt(std.testing.allocator, &.{"Article"}, false);
    defer std.testing.allocator.free(idx2);
    try std.testing.expect(std.mem.indexOf(u8, idx2, "ArticleBiz") == null);
}
