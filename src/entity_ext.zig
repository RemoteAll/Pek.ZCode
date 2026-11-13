//! 实体扩展（对应 C# `Entity/EntityExtension.cs` + `EntityBase.CopyFrom` 的可用部分）。
//!
//! 设计口径（对应"减少往返 + 不带无关列进 SQL"）：
//! - **脏数据是列裁剪的唯一依据**：`dirtyUnionOf` 求一批实体的脏列并集，
//!   批量写只带「主键 + 脏列」，未改动的列不进 SQL；
//! - **合并（merge）用哈希索引**，不是 C# 那种每行 `FirstOrDefault` 的线性扫描（N×M → N+M）；
//! - **批量落库一次往返**：更新与新增各一条多行语句，不再逐条 `UPDATE`。
//!
//! 已迁移：`cloneAlloc` / `copyFrom` / `hasDirty` / `dirtyNamesAlloc` / `dirtyUnionOf` /
//! `trimExtraLong` / `indexByAlloc`（≈ `ToDictionary`）/ `merge` / `saveCsvAlloc` / `loadCsvAlloc`。
//!
//! 与 C# 的显式差异：
//! - C# `Valid(list, isNew)` 依赖代码生成的逐实体非空判断 + 拦截器；本仓的等价能力是
//!   `checkRequired`（按模型 `Nullable` 判定必填列，返回第一个空列名），拦截器仍走 `interceptor.Chain`；
//! - C# `CopyFrom` 支持「不同实体类型 + 字典 + 反射对象」，本仓只做**同类型**复制（跨类型请转成
//!   `Value` 后逐列 `setColumnValue`，不猜字段映射）。

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("root.zig");
const csv = @import("csv.zig");

const Value = zzig.db.Value;
const DateTime = zzig.DateTime;
const FieldMeta = zcode.entity.FieldMeta;

// ── 脏数据 ──────────────────────────────────────────────────

/// 是否有脏列（对应 C# `IEntity.HasDirty`）。
pub fn hasDirty(e: anytype) bool {
    return e.dirty != 0;
}

/// 清空脏标记（对应 C# `entity.Dirtys.Clear()`）。
pub fn clearDirty(e: anytype) void {
    e.dirty = 0;
}

/// 脏列数。
pub fn dirtyCount(e: anytype) usize {
    const T = @TypeOf(e.*);
    var n: usize = 0;
    for (T.meta.fields, 0..) |_, i| {
        if (zcode.entity.isDirty(e.dirty, i)) n += 1;
    }
    return n;
}

/// 脏列名（按模型字段顺序）。
pub fn dirtyNamesAlloc(a: std.mem.Allocator, e: anytype) ![]const []const u8 {
    const T = @TypeOf(e.*);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(a);
    for (T.meta.fields, 0..) |f, i| {
        if (zcode.entity.isDirty(e.dirty, i)) try out.append(a, f.name);
    }
    return out.toOwnedSlice(a);
}

/// 一批实体脏列并集的泛型实现（`T` 显式给出）。
pub fn dirtyUnionOf(comptime T: type, a: std.mem.Allocator, list: []const T) ![]bool {
    const mask = try a.alloc(bool, T.meta.fields.len);
    @memset(mask, false);
    for (list) |e| {
        for (mask, 0..) |*m, i| {
            if (zcode.entity.isDirty(e.dirty, i)) m.* = true;
        }
    }
    return mask;
}

/// 一批实体（指针形式）的脏列并集。
pub fn dirtyUnionOfPtrs(comptime T: type, a: std.mem.Allocator, list: []const *T) ![]bool {
    const mask = try a.alloc(bool, T.meta.fields.len);
    @memset(mask, false);
    for (list) |e| {
        for (mask, 0..) |*m, i| {
            if (zcode.entity.isDirty(e.dirty, i)) m.* = true;
        }
    }
    return mask;
}

// ── 克隆 / 复制 ─────────────────────────────────────────────

/// 深拷贝实体：值拷贝 + 所有 `[]const u8` 字段重新分配。
///
/// 为什么必须 dupe：`entity.queryRows` / `findByPk` 返回的字符串指向会话 arena，
/// 会话一关就失效（实测表现为 union 标签错乱 / `incorrect alignment` 崩溃）。
pub fn cloneAlloc(comptime T: type, a: std.mem.Allocator, src: T) !T {
    var out = src;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        if (FT == []const u8) {
            @field(out, name) = try a.dupe(u8, @field(src, name));
        }
    }
    return out;
}

/// 复制同类型实体的成员（对应 C# `EntityBase.CopyFrom`）。
///
/// - `set_dirty`：目标被复制的列置脏（后续 `update` 才会写这些列）；
/// - `get_dirty`：只复制**源**上已置脏的列（局部复制）；
/// - 返回实际复制的函数。
///
/// 走 `columnValue` / `setColumnValue` 而不是 `@field`：索引天然与 `meta.fields` 对齐，
/// 生成器改了字段名也不用改这里。
pub fn copyFrom(comptime T: type, dst: *T, src: T, set_dirty: bool, get_dirty: bool) !usize {
    var n: usize = 0;
    inline for (T.meta.fields, 0..) |_, i| {
        if (!get_dirty or zcode.entity.isDirty(src.dirty, i)) {
            try dst.setColumnValue(i, src.columnValue(i));
            if (set_dirty) zcode.entity.markDirty(&dst.dirty, i);
            n += 1;
        }
    }
    return n;
}

// ── 校验 / 截断 ─────────────────────────────────────────────

/// 必填列校验（对应 C# 生成代码里的 `IsNullOrEmpty` 判断）。
///
/// 口径：模型里 `!Nullable` 的 **字符串** 列视为必填，空串即不通过。
/// 返回第一个不通过的列名（`null` = 全部通过）。
pub fn checkRequired(e: anytype) ?[]const u8 {
    const T = @TypeOf(e.*);
    inline for (T.meta.fields, 0..) |f, i| {
        if (f.data_type == .string and !f.nullable) {
            const v = e.columnValue(i);
            const t: []const u8 = if (v == .text) v.text else "";
            if (t.len == 0) return f.name;
        }
    }
    return null;
}

fn cpLen(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// 按码点截断到 `max` 个字符（不会切开多字节序列）。
pub fn truncateCodepoints(s: []const u8, max: usize) []const u8 {
    if (max == 0) return s[0..0];
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + n > s.len) break;
        count += 1;
        i += n;
        if (count == max) break;
    }
    return s[0..i];
}

/// 截断超长字符串列（对应 C# `TrimExtraLong`）：按模型 `Length` 截断，返回被截断的列数。
///
/// `names` 为空 = 处理所有 `String` 且 `Length > 0` 的列。
pub fn trimExtraLong(e: anytype, names: []const []const u8) usize {
    const T = @TypeOf(e.*);
    var n: usize = 0;
    inline for (T.meta.fields, 0..) |f, i| {
        if (f.data_type == .string) {
            const max: usize = if (f.length > 0) @intCast(f.length) else 0;
            if (max > 0 and (names.len == 0 or containsName(names, f.name))) {
                const v = e.columnValue(i);
                if (v == .text and cpLen(v.text) > max) {
                    e.setColumnValue(i, .{ .text = truncateCodepoints(v.text, max) }) catch {};
                    zcode.entity.markDirty(&e.dirty, i);
                    n += 1;
                }
            }
        }
    }
    return n;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |x| {
        if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

// ── 列表索引（≈ C# `ToDictionary`）──────────────────────────

/// 按某一列的文本值建索引：值 → 下标（重复值保留第一个）。
///
/// C# `ToDictionary(list, valueField)` 的键也是这一列；本仓返回下标而不是实体副本，
/// 避免多一次深拷贝（调用方拿下标回列表取）。键归 `a`。
pub fn indexByAlloc(comptime T: type, comptime column: []const u8, a: std.mem.Allocator, list: []const T) !std.StringHashMapUnmanaged(usize) {
    const idx = comptime columnIndex(T, column) orelse @compileError("indexBy: 列不存在 " ++ column);

    var map: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer {
        var it = map.keyIterator();
        while (it.next()) |k| a.free(k.*);
        map.deinit(a);
    }

    for (list, 0..) |e, i| {
        const t = try csv.valueTextAlloc(a, e.columnValue(idx));
        errdefer a.free(t);
        const gop = try map.getOrPut(a, t);
        if (gop.found_existing) {
            a.free(t); // 重复键保留第一个
        } else {
            gop.value_ptr.* = i;
        }
    }
    return map;
}

fn columnIndex(comptime T: type, comptime name: []const u8) ?usize {
    inline for (T.meta.fields, 0..) |f, i| {
        if (comptime std.mem.eql(u8, f.name, name)) return i;
    }
    return null;
}

// ── 合并（对应 C# `EntityExtension.Merge`）──────────────────

pub const MergeReport = struct {
    inserted: usize = 0,
    updated: usize = 0,
    deleted: usize = 0,
};

/// 把 `news` 合并进 `source`（按 `keys` 各列全等匹配）：
/// - 命中 → 复制成员（脏合并），从 `source` 移除；
/// - 未命中 → 新增；
/// - `trim = true` → `source` 里没被命中的全部删除。
///
/// 落库顺序与 C# 一致：**先更新、再插入、最后删除**（避免主外键约束顺序问题）。
/// 全程只有三条语句（每类一条多行/批量语句），不是逐条往返。
///
/// `get_dirty = true` 时只复制 `news` 里已置脏的列——外部数据（直接赋值、未置脏）请传 `false`。
pub fn merge(
    dal: *zcode.Dal,
    comptime T: type,
    a: std.mem.Allocator,
    source: *std.ArrayListUnmanaged(T),
    news: []const T,
    comptime keys: []const []const u8,
    trim: bool,
    get_dirty: bool,
) !MergeReport {
    var report = MergeReport{};

    // 1) 键 → 下标索引（哈希，一次遍历；C# 是每行线性扫，O(N×M)）
    var map = std.StringHashMapUnmanaged(usize).empty;
    defer {
        var it = map.keyIterator();
        while (it.next()) |k| a.free(k.*);
        map.deinit(a);
    }
    for (source.items, 0..) |e, i| {
        const k = try keyOfAlloc(T, a, e, keys);
        const gop = try map.getOrPut(a, k);
        if (gop.found_existing) a.free(k) else gop.value_ptr.* = i;
    }

    var matched = try a.alloc(bool, source.items.len);
    defer a.free(matched);
    @memset(matched, false);

    var updates: std.ArrayListUnmanaged(T) = .empty;
    defer updates.deinit(a);
    var inserts: std.ArrayListUnmanaged(T) = .empty;
    defer inserts.deinit(a);

    for (news) |n| {
        const k = try keyOfAlloc(T, a, n, keys);
        defer a.free(k);

        if (map.get(k)) |i| {
            _ = try copyFrom(T, &source.items[i], n, true, get_dirty);
            try updates.append(a, source.items[i]);
            matched[i] = true;
            report.updated += 1;
        } else {
            try inserts.append(a, n);
            report.inserted += 1;
        }
    }

    // 2) 先更新
    if (updates.items.len > 0) try saveList(dal, T, updates.items, .upsert);
    // 3) 再插入
    if (inserts.items.len > 0) try saveList(dal, T, inserts.items, .insert);

    // 4) 最后删除多余的
    if (trim) {
        var keep: std.ArrayListUnmanaged(T) = .empty;
        defer keep.deinit(a);
        for (source.items, 0..) |e, i| {
            if (!matched[i]) {
                try keep.append(a, e);
            }
        }
        for (keep.items) |*e| {
            var s = try dal.openSessionForTable(T.meta.table_name);
            defer s.deinit();
            _ = try zcode.entity.delete(dal, e, &s);
            report.deleted += 1;
        }
    }

    return report;
}

fn keyOfAlloc(comptime T: type, a: std.mem.Allocator, e: T, comptime keys: []const []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    for (keys, 0..) |k, i| {
        const idx = comptime columnIndex(T, k) orelse @compileError("merge: 键列不存在 " ++ k);
        if (i > 0) try buf.append(a, 0x1F); // 列间分隔，避免 "ab"+"c" == "a"+"bc"
        const t = try csv.valueTextAlloc(a, e.columnValue(idx));
        defer a.free(t);
        try buf.appendSlice(a, t);
    }
    return buf.toOwnedSlice(a);
}

fn saveList(dal: *zcode.Dal, comptime T: type, list: []const T, mode: zcode.SaveModes) !void {
    if (list.len == 0) return;
    var s = try dal.openSessionForTable(T.meta.table_name);
    defer s.deinit();

    var arena = std.heap.ArenaAllocator.init(dal.gpa);
    defer arena.deinit();
    const ptrs = try arena.allocator().alloc(*T, list.len);
    // `saveBatchWith` 只读实体，不改内容；这里转指针只为复用批量实现
    for (list, 0..) |e, i| {
        const p = try arena.allocator().create(T);
        p.* = e;
        ptrs[i] = p;
    }
    _ = try zcode.entity.saveBatchWith(dal, T, ptrs, &s, mode);
}

// ── CSV（对应 C# `SaveCsv` / `LoadCsv`）─────────────────────

/// 实体列表 → CSV 文本（首行表头）。`fields` 为空时导出全部非自增列。
pub fn saveCsvAlloc(comptime T: type, a: std.mem.Allocator, list: []const T, fields: []const []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);

    var first = true;
    for (T.meta.fields) |f| {
        if (fields.len > 0 and !containsName(fields, f.name)) continue;
        if (!first) try buf.append(a, ',');
        first = false;
        try csv.appendText(&buf, a, f.name);
    }
    try buf.append(a, '\n');

    for (list) |e| {
        first = true;
        inline for (T.meta.fields, 0..) |f, i| {
            if (fields.len == 0 or containsName(fields, f.name)) {
                if (!first) try buf.append(a, ',');
                first = false;
                try csv.appendValue(&buf, a, e.columnValue(i));
            }
        }
        try buf.append(a, '\n');
    }
    return buf.toOwnedSlice(a);
}

/// CSV 文本 → 实体列表（按表头列名回填；未知列忽略，缺失列保持默认）。
///
/// **所有权**：返回的实体里字符串都由 `a` 分配（不指向解析缓冲），
/// 释放时要逐项 `free` 文本字段再 `free` 外层——或者直接用 arena。
pub fn loadCsvAlloc(comptime T: type, a: std.mem.Allocator, text: []const u8) ![]T {
    const rows = try csv.parseAlloc(a, text);
    defer csv.freeRows(a, rows);
    if (rows.len < 2) return a.alloc(T, 0);

    const header = rows[0];
    var out: std.ArrayListUnmanaged(T) = .empty;
    errdefer out.deinit(a);

    for (rows[1..]) |cells| {
        var e = T{};
        inline for (T.meta.fields, 0..) |f, idx| {
            // 表头是运行时数据，不能 comptime 求字段下标；反向做「字段 → 表头列」即可
            var ci: ?usize = null;
            for (header, 0..) |h, k| {
                if (std.mem.eql(u8, h, f.name)) {
                    ci = k;
                    break;
                }
            }
            if (ci) |k| {
                if (k < cells.len) {
                    // 解析结果的内存随 `freeRows` 一起释放，实体里的字符串必须**深拷贝**，
                    // 否则返回的实体指向已释放的 cell（实测读到垃圾字节）
                    const v = parseValueAt(T, idx, cells[k]);
                    if (v == .text) {
                        try e.setColumnValue(idx, .{ .text = try a.dupe(u8, v.text) });
                    } else {
                        try e.setColumnValue(idx, v);
                    }
                }
            }
        }
        e.dirty = 0;
        try out.append(a, e);
    }
    return out.toOwnedSlice(a);
}

fn parseValueAt(comptime T: type, comptime idx: usize, text: []const u8) Value {
    const f = T.meta.fields[idx];
    if (text.len == 0) {
        return switch (f.data_type) {
            .string, .json => .{ .text = "" },
            .datetime => .{ .datetime = DateTime{} },
            .boolean => .{ .boolean = false },
            .single, .double, .decimal => .{ .float = 0 },
            else => .{ .int = 0 },
        };
    }
    return switch (f.data_type) {
        .string, .json => .{ .text = text },
        .boolean => .{ .boolean = !(std.mem.eql(u8, text, "0") or std.ascii.eqlIgnoreCase(text, "false")) },
        .single, .double, .decimal => .{ .float = std.fmt.parseFloat(f64, text) catch 0 },
        .datetime => .{ .datetime = DateTime.parse(text) catch DateTime{} },
        else => .{ .int = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t"), 10) catch 0 },
    };
}

// ── 用例 ────────────────────────────────────────────────────

const testing = std.testing;

const Rec = struct {
    dirty: zcode.entity.DirtyBits = 0,
    Id: i32 = 0,
    Name: []const u8 = "",
    Note: []const u8 = "",

    pub const meta = zcode.entity.EntityMeta{
        .name = "Rec",
        .table_name = "Rec",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "Name", .data_type = .string, .length = 4 },
            .{ .name = "Note", .data_type = .string },
        },
    };

    pub fn columnValue(self: @This(), i: usize) Value {
        return switch (i) {
            0 => .{ .int = self.Id },
            1 => .{ .text = self.Name },
            2 => .{ .text = self.Note },
            else => .null,
        };
    }

    pub fn setColumnValue(self: *@This(), i: usize, v: Value) !void {
        switch (i) {
            0 => self.Id = v.asI32() orelse 0,
            1 => self.Name = if (v == .text) v.text else "",
            2 => self.Note = if (v == .text) v.text else "",
            else => {},
        }
    }

    pub fn setName(self: *@This(), v: []const u8) void {
        self.Name = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }

    pub fn setNote(self: *@This(), v: []const u8) void {
        self.Note = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
};

test "脏数据：统计 / 列名 / 并集 / 清空" {
    var e = Rec{ .Id = 1 };
    try testing.expect(!hasDirty(&e));
    try testing.expectEqual(@as(usize, 0), dirtyCount(&e));

    e.setName("张三");
    e.setNote("备注");
    try testing.expect(hasDirty(&e));
    try testing.expectEqual(@as(usize, 2), dirtyCount(&e));

    const names = try dirtyNamesAlloc(testing.allocator, &e);
    defer testing.allocator.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("Name", names[0]);
    try testing.expectEqualStrings("Note", names[1]);

    const list = [_]Rec{ e, Rec{ .Id = 2 } };
    const mask = try dirtyUnionOf(Rec, testing.allocator, &list);
    defer testing.allocator.free(mask);
    try testing.expect(!mask[0]); // 主键从不当脏列
    try testing.expect(mask[1]);
    try testing.expect(mask[2]);

    clearDirty(&e);
    try testing.expect(!hasDirty(&e));
}

test "CopyFrom：全量复制 / 只复制脏列 / set_dirty 控制" {
    var src = Rec{ .Id = 7, .Name = "源", .Note = "源备注" };
    src.setNote("改了备注"); // 只有 Note 是脏的

    var dst = Rec{};
    // get_dirty = true：只复制 Note
    const n1 = try copyFrom(Rec, &dst, src, true, true);
    try testing.expectEqual(@as(usize, 1), n1);
    try testing.expectEqualStrings("", dst.Name);
    try testing.expectEqualStrings("改了备注", dst.Note);
    try testing.expect(zcode.entity.isDirty(dst.dirty, 2));
    try testing.expect(!zcode.entity.isDirty(dst.dirty, 1));

    // get_dirty = false + set_dirty = false：全复制且不置脏
    var dst2 = Rec{};
    const n2 = try copyFrom(Rec, &dst2, src, false, false);
    try testing.expectEqual(@as(usize, 3), n2);
    try testing.expectEqualStrings("源", dst2.Name);
    try testing.expectEqual(@as(i32, 7), dst2.Id);
    try testing.expect(!hasDirty(&dst2));
}

test "Clone：字符串深拷贝（改副本不影响原件）" {
    const src = Rec{ .Id = 1, .Name = "原名" };
    const copy = try cloneAlloc(Rec, testing.allocator, src);
    defer {
        testing.allocator.free(copy.Name);
        testing.allocator.free(copy.Note);
    }
    try testing.expectEqualStrings("原名", copy.Name);
    try testing.expect(copy.Name.ptr != src.Name.ptr);
}

test "TrimExtraLong：按 Length 截断（按码点，不切多字节）" {
    var e = Rec{ .Name = "一二三四五六" }; // Length = 4
    const n = trimExtraLong(&e, &.{});
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("一二三四", e.Name);
    try testing.expect(zcode.entity.isDirty(e.dirty, 1));

    // 指定列范围：只处理 Note
    var e2 = Rec{ .Name = "一二三四五六", .Note = "无所谓" };
    try testing.expectEqual(@as(usize, 0), trimExtraLong(&e2, &.{"Note"}));
    try testing.expectEqualStrings("一二三四五六", e2.Name);
}

test "CheckRequired：非空字符串列判空" {
    var e = Rec{};
    try testing.expectEqualStrings("Name", checkRequired(&e).?);
    e.Name = "有值";
    try testing.expectEqualStrings("Note", checkRequired(&e).?); // Note 也是非空字符串列
    e.Note = "有值";
    try testing.expect(checkRequired(&e) == null);
}

test "IndexBy / CSV 往返" {
    const a = testing.allocator;
    const list = [_]Rec{
        .{ .Id = 1, .Name = "甲", .Note = "含,逗号" },
        .{ .Id = 2, .Name = "乙", .Note = "" },
    };

    var map = try indexByAlloc(Rec, "Name", a, &list);
    defer {
        var it = map.keyIterator();
        while (it.next()) |k| a.free(k.*);
        map.deinit(a);
    }
    try testing.expectEqual(@as(usize, 0), map.get("甲").?);
    try testing.expectEqual(@as(usize, 1), map.get("乙").?);

    const text = try saveCsvAlloc(Rec, a, &list, &.{});
    defer a.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Id,Name,Note") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"含,逗号\"") != null);

    const back = try loadCsvAlloc(Rec, a, text);
    defer {
        for (back) |e| {
            a.free(e.Name);
            a.free(e.Note);
        }
        a.free(back);
    }
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqual(@as(i32, 1), back[0].Id);
    try testing.expectEqualStrings("甲", back[0].Name);
    try testing.expectEqualStrings("含,逗号", back[0].Note);
    try testing.expectEqual(@as(i32, 2), back[1].Id);
}
