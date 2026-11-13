//! 地区（行政区划）算法（对应 C# `DH.NCode/Membership/地区.Biz.cs`）。
//!
//! 已迁移：
//! - 纯计算：`fixLevel` / `fixName`（含简称表与 56 个民族名去尾）/ `getBig` / `getParent`
//! - 解析：`parse` / `parseLevel4`（民政部行政区划页 HTML）
//! - 落库：`create` / `findById` / `mergeLevel3` / `mergeLevel4` / `scanFixLevel`
//! - 数据交换：`exportCsv` / `importCsv`（本地 CSV）
//!
//! **明确未做**（不静默降级）：
//! - `Import` 的 `http(s)://` 远程下载与 `.gz` 解压：本仓无 gzip 与 HTTP 客户端依赖，
//!   调用时返回 `error.Unsupported` 并提示先下载到本地；
//! - `FetchAndSave`（抓取民政部页面）：同上，页面下载交给调用方；
//! - `Preload`：C# 是给 `Meta.Cache` 预热两级子节点，本仓没有该缓存形态，
//!   等价能力是 `countByLevel`（统计各级数量），命名上不假装是预热。

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("../root.zig");
const entities = @import("entities/mod.zig");
const pinyin = @import("../pinyin.zig");

const Area = entities.Area;
const Field = zcode.sqlbuild.Field;

// ── 纯计算：后缀修剪 ──────────────────────────────────────────

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (suffix.len > s.len) return false;
    return std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

/// 字符数（C# `String.Length` 是 UTF-16 码元数；汉字与 ASCII 都是 1，与码点数一致）。
fn cpLen(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// 对应 C# `StringHelper.TrimSuffix`：逐个后缀匹配，去掉一个后**从头再来**。
pub fn trimEnd(text: []const u8, ends: []const []const u8) []const u8 {
    if (text.len == 0 or ends.len == 0) return text;

    var s = text;
    while (true) {
        var changed = false;
        for (ends) |e| {
            if (e.len == 0) continue;
            if (endsWithIgnoreCase(s, e)) {
                s = s[0 .. s.len - e.len];
                if (s.len == 0) return s;
                changed = true;
                break;
            }
        }
        if (!changed) return s;
    }
}

/// 对应 C# `FixHelper.TrimName`：逐个后缀去尾，**长度 <= 2 就停**。
pub fn trimName(text: []const u8, ends: []const []const u8) []const u8 {
    var s = text;
    for (ends) |e| {
        if (cpLen(s) <= 2) break;
        s = trimEnd(s, &.{e});
    }
    return s;
}

// ── 纯计算：层级 / 父级 / 大区 ────────────────────────────────

/// 按编码推算层级（对应 C# `Area.FixLevel`）：1 省 / 2 市 / 3 区县 / 4 街道乡镇。
pub fn fixLevel(area: *Area) void {
    const id = area.ID;
    if (id <= 0) return;
    if (id <= 99_99_99) {
        if (@rem(id, 10000) == 0) {
            area.setLevel(1);
        } else if (@rem(id, 100) == 0) {
            area.setLevel(2);
        } else {
            area.setLevel(3);
        }
    } else if (id <= 99_99_99_999) {
        area.setLevel(4);
    }
}

/// 由子级编码推算父级编码（对应 C# `GetParent`）。
pub fn getParent(id: i32) i32 {
    if (id <= 0) return 0;
    if (@rem(id, 10000) == 0) return 0;
    if (@rem(id, 100) == 0) return id - @rem(id, 10000);
    if (id <= 99_99_99) return id - @rem(id, 100);
    return 0;
}

const big_regions = [_]struct { big: []const u8, provinces: []const []const u8 }{
    .{ .big = "华北", .provinces = &.{ "北京", "天津", "河北", "山西", "内蒙古" } },
    .{ .big = "东北", .provinces = &.{ "辽宁", "吉林", "黑龙江" } },
    .{ .big = "华东", .provinces = &.{ "上海", "江苏", "浙江", "安徽", "福建", "江西", "山东" } },
    .{ .big = "华中", .provinces = &.{ "河南", "湖北", "湖南" } },
    .{ .big = "华南", .provinces = &.{ "广东", "广西", "海南" } },
    .{ .big = "西南", .provinces = &.{ "重庆", "四川", "贵州", "云南", "西藏" } },
    .{ .big = "西北", .provinces = &.{ "陕西", "甘肃", "青海", "宁夏", "新疆" } },
    .{ .big = "港澳台", .provinces = &.{ "香港", "澳门", "台湾" } },
};

/// 所属大区（对应 C# `Area.GetBig`）；不在表里返回 null。
pub fn getBig(name: []const u8) ?[]const u8 {
    for (big_regions) |r| {
        for (r.provinces) |p| {
            if (std.mem.eql(u8, p, name)) return r.big;
        }
    }
    return null;
}

// ── 纯计算：简称 ─────────────────────────────────────────────

const short_pairs = [_]struct { full: []const u8, short: []const u8 }{
    .{ .full = "市辖区", .short = "市辖区" },
    .{ .full = "直辖县", .short = "直辖县" },
    .{ .full = "直辖镇", .short = "直辖镇" },
    .{ .full = "万柏林区", .short = "万柏林" },
    .{ .full = "白云鄂博矿区", .short = "白云矿区" },
    .{ .full = "沈北新区", .short = "沈北新区" },
    .{ .full = "金林区", .short = "金林区" },
    .{ .full = "士林区", .short = "士林区" },
    .{ .full = "杉林区", .short = "杉林区" },
    .{ .full = "茂林区", .short = "茂林区" },
    .{ .full = "坪林区", .short = "坪林区" },
    .{ .full = "树林区", .short = "树林区" },
    .{ .full = "巴林左旗", .short = "左旗" },
    .{ .full = "巴林右旗", .short = "右旗" },
    .{ .full = "克什克腾旗", .short = "克旗" },
    .{ .full = "土默特左旗", .short = "土左旗" },
    .{ .full = "土默特右旗", .short = "土右旗" },
    .{ .full = "达尔罕茂明安联合旗", .short = "达茂旗" },
    .{ .full = "阿鲁科尔沁旗", .short = "阿旗" },
    .{ .full = "翁牛特旗", .short = "翁旗" },
    .{ .full = "喀喇沁旗", .short = "喀旗" },
    .{ .full = "科尔沁左翼中旗", .short = "科左中旗" },
    .{ .full = "科尔沁左翼后旗", .short = "科左后旗" },
    .{ .full = "鄂托克前旗", .short = "鄂前旗" },
    .{ .full = "杭锦旗", .short = "杭锦旗" },
    .{ .full = "乌审旗", .short = "乌审旗" },
    .{ .full = "阿荣旗", .short = "阿荣旗" },
    .{ .full = "莫力达瓦达斡尔族自治旗", .short = "莫旗" },
    .{ .full = "鄂温克族自治旗", .short = "鄂温克旗" },
    .{ .full = "陈巴尔虎旗", .short = "陈旗" },
    .{ .full = "新巴尔虎左旗", .short = "新左旗" },
    .{ .full = "新巴尔虎右旗", .short = "新右旗" },
    .{ .full = "乌拉特前旗", .short = "乌前旗" },
    .{ .full = "乌拉特中旗", .short = "乌中旗" },
    .{ .full = "乌拉特后旗", .short = "乌后旗" },
    .{ .full = "杭锦后旗", .short = "杭锦后旗" },
    .{ .full = "察哈尔右翼前旗", .short = "察右前旗" },
    .{ .full = "察哈尔右翼中旗", .short = "察右中旗" },
    .{ .full = "察哈尔右翼后旗", .short = "察右后旗" },
    .{ .full = "四子王旗", .short = "四子王旗" },
    .{ .full = "科尔沁右翼前旗", .short = "科右前旗" },
    .{ .full = "科尔沁右翼中旗", .short = "科右中旗" },
    .{ .full = "扎赉特旗", .short = "扎赉特旗" },
    .{ .full = "阿巴嘎旗", .short = "阿巴嘎旗" },
    .{ .full = "苏尼特左旗", .short = "东苏旗" },
    .{ .full = "苏尼特右旗", .short = "西苏旗" },
    .{ .full = "东乌珠穆沁旗", .short = "东乌旗" },
    .{ .full = "西乌珠穆沁旗", .short = "西乌旗" },
    .{ .full = "太仆寺旗", .short = "太旗" },
    .{ .full = "镶黄旗", .short = "镶黄旗" },
    .{ .full = "正镶白旗", .short = "正镶白旗" },
    .{ .full = "正蓝旗", .short = "正蓝旗" },
    .{ .full = "阿拉善左旗", .short = "阿左旗" },
    .{ .full = "阿拉善右旗", .short = "阿右旗" },
    .{ .full = "六枝特区", .short = "六枝" },
    .{ .full = "博尔塔拉蒙古自治州", .short = "博州" },
    .{ .full = "巴音郭楞蒙古自治州", .short = "巴州" },
    .{ .full = "克孜勒苏柯尔克孜自治州", .short = "克州" },
};

const minzu = [_][]const u8{
    "汉族",
    "壮族",
    "满族",
    "回族",
    "苗族",
    "维吾尔族",
    "土家族",
    "彝族",
    "蒙古族",
    "藏族",
    "布依族",
    "侗族",
    "瑶族",
    "朝鲜族",
    "白族",
    "哈尼族",
    "哈萨克族",
    "黎族",
    "傣族",
    "畲族",
    "傈僳族",
    "仡佬族",
    "东乡族",
    "高山族",
    "拉祜族",
    "水族",
    "佤族",
    "纳西族",
    "羌族",
    "土族",
    "仫佬族",
    "锡伯族",
    "柯尔克孜族",
    "达斡尔族",
    "景颇族",
    "毛南族",
    "撒拉族",
    "布朗族",
    "塔吉克族",
    "阿昌族",
    "普米族",
    "鄂温克族",
    "怒族",
    "京族",
    "基诺族",
    "德昂族",
    "保安族",
    "俄罗斯族",
    "裕固族",
    "乌孜别克族",
    "门巴族",
    "鄂伦春族",
    "独龙族",
    "塔塔尔族",
    "赫哲族",
    "珞巴族",
};

fn lookupShort(name: []const u8) ?[]const u8 {
    for (short_pairs) |p| {
        if (std.mem.eql(u8, p.full, name)) return p.short;
    }
    return null;
}

/// 由全称推算简称（对应 C# `Area.FixName`）。纯计算，返回的子串仍指向 `FullName`（或常量表）。
pub fn fixName(area: *const Area) []const u8 {
    var name = area.FullName;
    if (name.len == 0) return area.Name;

    if (lookupShort(name)) |s| return s;

    if (area.ParentID == 0) {
        name = trimEnd(name, &.{ "省", "市", "自治区", "壮族", "回族", "维吾尔", "特别行政区" });
    } else if (area.Level <= 3) {
        if (cpLen(name) > 8) name = trimEnd(name, &.{"经济技术开发区"});
        if (cpLen(name) > 6) name = trimEnd(name, &.{ "技术开发区", "经济开发区", "产业开发区", "旅游开发区" });
        if (cpLen(name) > 4) name = trimEnd(name, &.{ "开发区", "管理区", "风景区" });
        if (cpLen(name) > 3) name = trimEnd(name, &.{ "地区", "林区", "矿区", "新区" });
        if (cpLen(name) > 2) name = trimName(name, &.{ "县", "市", "区", "盟", "旗", "州" });
        if (cpLen(name) > 3) name = trimEnd(name, &.{ "自治", "联合", "各族" });

        // 去掉结尾的民族名称（C# 里去掉后 `i = -1` 从头再扫）
        var i: usize = 0;
        while (i < minzu.len) {
            const item = minzu[i];
            if (cpLen(name) > cpLen(item) + 1 and endsWithIgnoreCase(name, item)) {
                name = trimEnd(name, &.{item});
                i = 0;
                continue;
            }
            if (item.len >= 3 and endsWithIgnoreCase(item, "族")) {
                const item2 = trimEnd(item, &.{"族"});
                if (cpLen(name) > cpLen(item2) + 1 and endsWithIgnoreCase(name, item2)) {
                    name = trimEnd(name, &.{item2});
                    i = 0;
                    continue;
                }
            }
            i += 1;
        }

        // 数据错误导致多一个字
        if (cpLen(name) > 2) name = trimEnd(name, &.{"自"});
    } else if (area.Level == 4) {
        if (cpLen(name) > 3) {
            name = trimEnd(name, &.{"街道"});
        } else if (cpLen(name) > 2) {
            name = trimEnd(name, &.{ "乡", "镇" });
        }
    }

    return name;
}

// ── HTML 解析（民政部行政区划页）──────────────────────────────

/// 按两个分隔符切分，**去掉空片段**（对应 NewLife `StringHelper.Split(params String[])`
/// —— 它传的是 `StringSplitOptions.RemoveEmptyEntries`）。
fn splitEither(a: std.mem.Allocator, text: []const u8, sep1: []const u8, sep2: []const u8) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(a);

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        var hit: ?usize = null;
        if (sep1.len > 0 and i + sep1.len <= text.len and std.mem.eql(u8, text[i .. i + sep1.len], sep1)) {
            hit = sep1.len;
        } else if (sep2.len > 0 and i + sep2.len <= text.len and std.mem.eql(u8, text[i .. i + sep2.len], sep2)) {
            hit = sep2.len;
        }
        if (hit) |n| {
            if (i > start) try out.append(a, text[start..i]);
            i += n;
            start = i;
        } else {
            i += 1;
        }
    }
    if (text.len > start) try out.append(a, text[start..]);
    return out.toOwnedSlice(a);
}

fn lastIndexByte(text: []const u8, ch: u8) ?usize {
    return std.mem.lastIndexOfScalar(u8, text, ch);
}

fn indexOfFrom(text: []const u8, needle: []const u8, from: usize) ?usize {
    if (from >= text.len) return null;
    const rel = std.mem.indexOf(u8, text[from..], needle) orelse return null;
    return from + rel;
}

/// 从 HTML 解析三级地区（对应 C# `Area.Parse`）。返回的实体只有 `ID` 与 `FullName`。
pub fn parseAlloc(a: std.mem.Allocator, html: []const u8) ![]Area {
    var out: std.ArrayListUnmanaged(Area) = .empty;
    errdefer out.deinit(a);
    if (html.len == 0) return out.toOwnedSlice(a);

    var p: usize = 0;
    while (true) {
        const s = indexOfFrom(html, "<tr ", p) orelse break;
        const e = indexOfFrom(html, "</tr>", s) orelse break;

        const cells = try splitEither(a, html[s..e], "<td", "</td>");
        defer a.free(cells);

        if (cells.len >= 6) {
            var id = cells[3];
            if (lastIndexByte(id, '>')) |k| id = id[k + 1 ..];

            var name = cells[5];
            if (lastIndexByte(name, '>')) |k| {
                const ns = try splitEither(a, name, "<span", "</span>");
                defer a.free(ns);
                if (ns.len > 1) {
                    name = "";
                    for (ns) |piece| {
                        if (std.mem.indexOfScalar(u8, piece, '>') == null) {
                            name = piece;
                            break;
                        }
                    }
                } else {
                    name = name[k + 1 ..];
                }
            }
            name = std.mem.trim(u8, std.mem.trim(u8, name, " \t\r\n"), "*");
            name = std.mem.trim(u8, name, " \t\r\n");

            const id_num = std.fmt.parseInt(i64, id, 10) catch 0;
            if (id.len > 0 and id_num > 100_000 and name.len > 0) {
                var r = Area{};
                r.ID = @intCast(id_num);
                r.FullName = name;
                try out.append(a, r);
            }
        }

        p = e;
    }
    return out.toOwnedSlice(a);
}

/// 从 HTML 解析四级地区（街道乡镇，对应 C# `Area.ParseLevel4`）。
pub fn parseLevel4Alloc(a: std.mem.Allocator, html: []const u8) ![]Area {
    var out: std.ArrayListUnmanaged(Area) = .empty;
    errdefer out.deinit(a);
    if (html.len == 0) return out.toOwnedSlice(a);

    var p: usize = 0;
    while (true) {
        const s = indexOfFrom(html, "<tr class='towntr'>", p) orelse break;
        const e = indexOfFrom(html, "</tr>", s) orelse break;

        const cells = try splitEither(a, html[s..e], "'>", "</a>");
        defer a.free(cells);

        if (cells.len > 4) {
            const id = trimEnd(std.mem.trim(u8, cells[2], " \t\r\n"), &.{"000"});
            const name = std.mem.trim(u8, cells[4], " \t\r\n");

            const id_num = std.fmt.parseInt(i64, id, 10) catch 0;
            if (id.len > 0 and id_num > 100_000 and name.len > 0) {
                var r = Area{};
                r.ID = @intCast(id_num);
                r.FullName = name;
                try out.append(a, r);
            }
        }

        p = e;
    }
    return out.toOwnedSlice(a);
}

// ── 落库 ────────────────────────────────────────────────────

fn areaSession(dal: *zcode.Dal) !zcode.Session {
    return dal.openSessionForTable(Area.meta.table_name);
}

/// 按主键查（结果深拷贝到 `a`）。
pub fn findByIdAlloc(dal: *zcode.Dal, a: std.mem.Allocator, id: i32) !?Area {
    var s = try areaSession(dal);
    defer s.deinit();
    const found = try zcode.entity.findByPk(dal, Area, &s, &.{.{ .int = id }});
    const r = found orelse return null;
    return try @import("provider.zig").deepCopyAlloc(Area, a, r);
}

/// 查找或创建地区（对应 C# `Area.Create`）；编码非法返回 null。
pub fn create(dal: *zcode.Dal, a: std.mem.Allocator, id: i32, name: []const u8, parentid: i32, remark: []const u8) !?Area {
    if (id <= 0) return null;
    if (id < 100000) return null;
    if (id > 999999) {
        if (parentid < 100000 or parentid > 999999) return null;
        if (id < 100000000) return null;
        if (id > 999999999) return null;
    }

    if (try findByIdAlloc(dal, a, id)) |r| return r;

    var buf: [32]u8 = undefined;
    const fallback = std.fmt.bufPrint(&buf, "{d}", .{id}) catch "";
    const nm = if (name.len > 0) name else fallback;

    var r = Area{};
    r.ID = id;
    r.setName(nm);
    r.setFullName(nm);
    r.setParentID(parentid);
    r.setRemark(remark);

    var s = try areaSession(dal);
    defer s.deinit();
    _ = try zcode.entity.insert(dal, &r, &s);
    r.dirty = 0;
    return r;
}

/// 把实体转成整行字段（`upsertBatch` 的口径；跳过自增列）。
fn rowFields(a: std.mem.Allocator, area: *const Area) ![]Field {
    var n: usize = 0;
    for (Area.meta.fields) |f| {
        if (!f.identity) n += 1;
    }
    const fields = try a.alloc(Field, n);
    var i: usize = 0;
    for (Area.meta.fields, 0..) |f, idx| {
        if (f.identity) continue;
        fields[i] = .{ .name = f.name, .value = area.columnValue(idx) };
        i += 1;
    }
    return fields;
}

/// 合并字段（对应 C# `MergeLevel3/4` 里那段 `if (!r.X.IsNullOrEmpty()) r2.X = r.X`）。
fn mergeFields(dst: *Area, src: *const Area) void {
    if (src.English.len > 0) dst.setEnglish(src.English);
    if (src.TelCode.len > 0) dst.setTelCode(src.TelCode);
    if (src.ZipCode.len > 0) dst.setZipCode(src.ZipCode);
    if (src.Kind.len > 0) dst.setKind(src.Kind);
    if (@abs(src.Longitude) > 0.001) dst.setLongitude(src.Longitude);
    if (@abs(src.Latitude) > 0.001) dst.setLatitude(src.Latitude);
}

const MergeOutcome = struct {
    /// 新增 + 有字段变化的已存在数（C# `MergeLevel3` 的返回值）
    count: usize = 0,
    /// 未知父级的输入（C# 只打日志；这里回传给调用方，别静默）
    unknown_parents: usize = 0,
};

/// 合并三级地区（对应 C# `Area.MergeLevel3`）。
///
/// `add_lose = false` 时只走字段合并；四个直辖镇特例（东莞 441999 / 中山 442099 /
/// 儋州 460499 / 嘉峪关 620299）只在新增时生效。
pub fn mergeLevel3(dal: *zcode.Dal, list: []const Area, add_lose: bool, enable: bool) !MergeOutcome {
    var arena = std.heap.ArenaAllocator.init(dal.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var s = try areaSession(dal);
    defer s.deinit();

    // 一次性加载三级地址
    var w = zcode.Where.init(a);
    _ = try w.lt("ID", .{ .int = 99_99_99 });
    var q = zcode.Query.init(a);
    _ = q.filterWhere(&w);
    const existing = try zcode.entity.queryRows(dal, Area, &s, &q);

    var out = MergeOutcome{};
    var rows: std.ArrayListUnmanaged([]const Field) = .empty;

    for (list) |*r_in| {
        var r = r_in.*;
        if (r.ID < 10_00_00 or r.ID > 99_99_99) continue;

        var found: ?*Area = null;
        for (existing) |*e| {
            if (e.ID == r.ID) {
                found = e;
                break;
            }
        }

        if (found) |r2| {
            mergeFields(r2, &r);
            if (r2.dirty != 0) {
                try rows.append(a, try rowFields(a, r2));
                out.count += 1;
            }
        } else {
            if (!add_lose) continue;

            if (r.ID == 441999 and std.mem.eql(u8, r.Name, "东莞")) {
                r.setName("直辖镇");
                r.setFullName("直辖镇");
                r.setParentID(441900);
                r.setEnable(true);
            } else if (r.ID == 442099 and std.mem.eql(u8, r.Name, "中山")) {
                r.setName("直辖镇");
                r.setFullName("直辖镇");
                r.setParentID(442000);
                r.setEnable(true);
            } else if (r.ID == 460499 and std.mem.eql(u8, r.Name, "儋州")) {
                r.setName("直辖镇");
                r.setFullName("直辖镇");
                r.setParentID(460400);
                r.setEnable(true);
            } else if (r.ID == 620299 and std.mem.eql(u8, r.Name, "嘉峪关")) {
                r.setName("直辖镇");
                r.setFullName("直辖镇");
                r.setParentID(620200);
                r.setEnable(true);
            } else {
                // 三沙和港澳台强制启用
                const force = r.ParentID == 460300 or r.ParentID > 700000 or std.mem.startsWith(u8, r.Name, "直辖");
                r.setEnable(enable or force);
            }

            if (r.ParentID > 0) {
                var parent_known = false;
                for (existing) |e| {
                    if (e.ID == r.ParentID) {
                        parent_known = true;
                        break;
                    }
                }
                if (!parent_known) out.unknown_parents += 1;
            }

            r.setPinYin("");
            r.setJianPin("");
            const now = zzig.DateTime.nowLocal();
            r.setCreateTime(now);
            r.setUpdateTime(now);

            try rows.append(a, try rowFields(a, &r));
            out.count += 1;
        }
    }

    if (rows.items.len > 0) {
        const t = try dal.table(Area.meta.table_name);
        _ = try t.upsertBatch(&s, rows.items, .upsert);
    }
    return out;
}

/// 合并四级地区（对应 C# `Area.MergeLevel4`）。
pub fn mergeLevel4(dal: *zcode.Dal, list: []const Area, add_lose: bool, enable: bool) !MergeOutcome {
    var arena = std.heap.ArenaAllocator.init(dal.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var s = try areaSession(dal);
    defer s.deinit();

    var w = zcode.Where.init(a);
    _ = try w.lt("ID", .{ .int = 99_99_99_999 });
    var q = zcode.Query.init(a);
    _ = q.filterWhere(&w);
    const existing = try zcode.entity.queryRows(dal, Area, &s, &q);

    var out = MergeOutcome{};
    var rows: std.ArrayListUnmanaged([]const Field) = .empty;

    for (list) |*r_in| {
        var r = r_in.*;
        if (r.ID < 10_00_00_000 or r.ID > 99_99_99_999) continue;

        var found: ?*Area = null;
        for (existing) |*e| {
            if (e.ID == r.ID) {
                found = e;
                break;
            }
        }

        if (found) |r2| {
            mergeFields(r2, &r);
            if (r2.dirty != 0) {
                try rows.append(a, try rowFields(a, r2));
                out.count += 1;
            }
        } else {
            if (!add_lose) continue;

            if (r.ParentID > 0) {
                var parent_known = false;
                for (existing) |e| {
                    if (e.ID == r.ParentID) {
                        parent_known = true;
                        break;
                    }
                }
                if (!parent_known) out.unknown_parents += 1;
            }

            r.setPinYin("");
            r.setJianPin("");
            r.setEnable(enable);
            const now = zzig.DateTime.nowLocal();
            r.setCreateTime(now);
            r.setUpdateTime(now);

            try rows.append(a, try rowFields(a, &r));
            out.count += 1;
        }
    }

    if (rows.items.len > 0) {
        const t = try dal.table(Area.meta.table_name);
        _ = try t.upsertBatch(&s, rows.items, .upsert);
    }
    return out;
}

/// 扫描并修正层级为 0 的地区（对应 C# `ScanFixLevel`，按 1000 条分页）。
/// 返回扫描到的条数（C# 同口径）；修正条数通过 `fixed` 字段带出。
pub const ScanFixOutcome = struct { scanned: usize = 0, fixed: usize = 0 };

pub fn scanFixLevel(dal: *zcode.Dal) !ScanFixOutcome {
    var arena = std.heap.ArenaAllocator.init(dal.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var s = try areaSession(dal);
    defer s.deinit();

    var out = ScanFixOutcome{};
    var offset: usize = 0;
    while (true) {
        _ = arena.reset(.retain_capacity);

        var w = zcode.Where.init(a);
        _ = try w.eq("Level", .{ .int = 0 });
        var q = zcode.Query.init(a);
        _ = q.filterWhere(&w);
        _ = try q.orderBy("ID", false);
        _ = q.skip(offset).take(1000);

        const list = try zcode.entity.queryRows(dal, Area, &s, &q);
        if (list.len == 0) break;

        for (list) |*item| {
            fixLevel(item);
        }
        const report = try zcode.entity.saveBatch(dal, Area, blk: {
            const ptrs = try a.alloc(*Area, list.len);
            for (list, 0..) |*item, i| ptrs[i] = item;
            break :blk ptrs;
        }, &s);
        out.fixed += report.updated;

        offset += list.len;
        out.scanned += list.len;
    }
    return out;
}

/// 各层级数量（替代 C# `Preload`：本仓没有 `Meta.Cache` 那种预热形态，
/// 需要的是「数据齐不齐」的可见指标）。
pub fn countByLevel(dal: *zcode.Dal) ![5]i64 {
    var arena = std.heap.ArenaAllocator.init(dal.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var s = try areaSession(dal);
    defer s.deinit();

    var counts: [5]i64 = .{ 0, 0, 0, 0, 0 };
    for (0..5) |level| {
        var w = zcode.Where.init(a);
        _ = try w.eq("Level", .{ .int = @intCast(level) });
        counts[level] = try zcode.entity.count(dal, Area, &s, &w);
        w.deinit();
    }
    return counts;
}

// ── CSV 导入导出 ─────────────────────────────────────────────

pub const CsvError = error{ Unsupported, InvalidCsv };

/// 导出到 CSV（对应 C# `Area.Export`）：`Level <= level`，去掉 CreateTime/UpdateTime/Remark。
/// 返回导出行数。
pub fn exportCsv(dal: *zcode.Dal, path: []const u8, level: i32) !usize {
    var arena = std.heap.ArenaAllocator.init(dal.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var s = try areaSession(dal);
    defer s.deinit();

    var w = zcode.Where.init(a);
    _ = try w.le("Level", .{ .int = level });
    var q = zcode.Query.init(a);
    _ = q.filterWhere(&w);
    _ = try q.orderBy("ID", false);
    const list = try zcode.entity.queryRows(dal, Area, &s, &q);

    const skip = [_][]const u8{ "CreateTime", "UpdateTime", "Remark" };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);

    // 表头
    var first = true;
    for (Area.meta.fields) |f| {
        if (isSkipped(&skip, f.name)) continue;
        if (!first) try buf.append(a, ',');
        first = false;
        try buf.appendSlice(a, f.name);
    }
    try buf.append(a, '\n');

    for (list) |item| {
        first = true;
        for (Area.meta.fields, 0..) |f, idx| {
            if (isSkipped(&skip, f.name)) continue;
            if (!first) try buf.append(a, ',');
            first = false;
            try appendCsvValue(&buf, a, item.columnValue(idx));
        }
        try buf.append(a, '\n');
    }

    try zzig.File.WriteAll(path, buf.items);
    return list.len;
}

fn isSkipped(skip: []const []const u8, name: []const u8) bool {
    for (skip) |x| {
        if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

fn appendCsvValue(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: zcode.Value) !void {
    switch (v) {
        .null => {},
        .boolean => |x| try buf.appendSlice(a, if (x) "1" else "0"),
        .int => |x| {
            var nb: [32]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "{d}", .{x}) catch "");
        },
        .float => |x| {
            var nb: [40]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "{d}", .{x}) catch "");
        },
        .decimal => |x| {
            var nb: [64]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "{}", .{x}) catch "");
        },
        .datetime => |x| {
            var nb: [64]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "{}", .{x}) catch "");
        },
        .text => |t| try appendCsvText(buf, a, t),
        .blob => |t| {
            var nb: [32]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&nb, "[{d}]0x{x}", .{ t.len, t[0..@min(t.len, 8)] }) catch "");
        },
    }
}

fn appendCsvText(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, t: []const u8) !void {
    const need_quote = std.mem.indexOfAny(u8, t, ",\"\r\n") != null;
    if (!need_quote) {
        try buf.appendSlice(a, t);
        return;
    }
    try buf.append(a, '"');
    for (t) |ch| {
        if (ch == '"') try buf.append(a, '"');
        try buf.append(a, ch);
    }
    try buf.append(a, '"');
}

/// 解析 CSV（引号转义、CRLF/LF）；首行为表头。
pub fn parseCsvAlloc(a: std.mem.Allocator, text: []const u8) ![][]const []const u8 {
    var rows: std.ArrayListUnmanaged([]const []const u8) = .empty;
    errdefer rows.deinit(a);

    var row: std.ArrayListUnmanaged([]const u8) = .empty;
    var cell: std.ArrayListUnmanaged(u8) = .empty;

    var i: usize = 0;
    var in_quote = false;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        const ch: u8 = if (at_end) '\n' else text[i];

        if (in_quote) {
            if (ch == '"') {
                if (i + 1 < text.len and text[i + 1] == '"') {
                    try cell.append(a, '"');
                    i += 1;
                } else {
                    in_quote = false;
                }
            } else {
                try cell.append(a, ch);
            }
            continue;
        }

        switch (ch) {
            '"' => in_quote = true,
            ',' => {
                try row.append(a, try cell.toOwnedSlice(a));
                cell = .empty;
            },
            '\r' => {},
            '\n' => {
                try row.append(a, try cell.toOwnedSlice(a));
                cell = .empty;
                // 末尾空行不算一行
                if (!(row.items.len == 1 and row.items[0].len == 0)) {
                    try rows.append(a, try row.toOwnedSlice(a));
                } else {
                    row.deinit(a);
                }
                row = .empty;
            },
            else => try cell.append(a, ch),
        }
    }
    return rows.toOwnedSlice(a);
}

/// 从本地 CSV 导入并合并（对应 C# `Area.Import` 的本地文件分支）。
///
/// C# 还支持 `http(s)://` 与 `.gz`，本仓**没有**这些依赖：遇到直接 `error.Unsupported`，
/// 并提示先下载/解压到本地，绝不静默跳过。
pub fn importCsv(dal: *zcode.Dal, path: []const u8, add_lose: bool, level: i32, enable: bool) !MergeOutcome {
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
        std.debug.print(
            "[zcode] Area.importCsv 不支持远程地址（没有 HTTP 客户端依赖）：{s}\n" ++
                "  请先下载到本地（.gz 需先解压）再导入\n",
            .{path},
        );
        return error.Unsupported;
    }
    if (std.mem.endsWith(u8, path, ".gz")) {
        std.debug.print(
            "[zcode] Area.importCsv 不支持 .gz（没有 gzip 依赖）：{s}\n  请先解压成 .csv\n",
            .{path},
        );
        return error.Unsupported;
    }

    var arena = std.heap.ArenaAllocator.init(dal.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 0.17 已移除 `std.fs.cwd()`，统一走 `zzig.File` 的兼容封装
    const text = try zzig.File.ReadAllAlloc(a, path, 256 * 1024 * 1024);

    const rows = try parseCsvAlloc(a, text);
    if (rows.len < 2) return MergeOutcome{};

    const header = rows[0];
    var list: std.ArrayListUnmanaged(Area) = .empty;

    for (rows[1..]) |cells| {
        var r = Area{};
        var has_id = false;
        for (header, 0..) |col, idx| {
            if (idx >= cells.len) break;
            const v = cells[idx];
            if (std.mem.eql(u8, col, "ID")) {
                r.ID = std.fmt.parseInt(i32, v, 10) catch 0;
                has_id = r.ID > 0;
            } else if (std.mem.eql(u8, col, "Name")) {
                r.Name = v;
            } else if (std.mem.eql(u8, col, "FullName")) {
                r.FullName = v;
            } else if (std.mem.eql(u8, col, "ParentID")) {
                r.ParentID = std.fmt.parseInt(i32, v, 10) catch 0;
            } else if (std.mem.eql(u8, col, "Level")) {
                r.Level = std.fmt.parseInt(i32, v, 10) catch 0;
            } else if (std.mem.eql(u8, col, "Kind")) {
                r.Kind = v;
            } else if (std.mem.eql(u8, col, "English")) {
                r.English = v;
            } else if (std.mem.eql(u8, col, "PinYin")) {
                r.PinYin = v;
            } else if (std.mem.eql(u8, col, "JianPin")) {
                r.JianPin = v;
            } else if (std.mem.eql(u8, col, "TelCode")) {
                r.TelCode = v;
            } else if (std.mem.eql(u8, col, "ZipCode")) {
                r.ZipCode = v;
            } else if (std.mem.eql(u8, col, "Longitude")) {
                r.Longitude = std.fmt.parseFloat(f64, v) catch 0;
            } else if (std.mem.eql(u8, col, "Latitude")) {
                r.Latitude = std.fmt.parseFloat(f64, v) catch 0;
            } else if (std.mem.eql(u8, col, "GeoHash")) {
                r.GeoHash = v;
            } else if (std.mem.eql(u8, col, "Enable")) {
                r.Enable = v.len > 0 and !std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false");
            }
        }
        if (has_id) {
            r.dirty = 0;
            try list.append(a, r);
        }
    }

    var out = try mergeLevel3(dal, list.items, add_lose, enable);
    if (level >= 4) {
        const r4 = try mergeLevel4(dal, list.items, add_lose, enable);
        out.count += r4.count;
        out.unknown_parents += r4.unknown_parents;
    }
    return out;
}

/// 给地区补齐拼音 / 简拼（C# 没有这段，是 Area 表 `PinYin`/`JianPin` 两列的实际用途）。
pub fn fillPinyin(list: []Area, a: std.mem.Allocator) !void {
    for (list) |*item| {
        const src = if (item.FullName.len > 0) item.FullName else item.Name;
        item.setPinYin(try pinyin.fullAlloc(a, src));
        item.setJianPin(try pinyin.getFirstAlloc(a, src));
    }
}

// ── 用例 ────────────────────────────────────────────────────

const testing = std.testing;

test "FixLevel / GetParent / GetBig" {
    var prov = Area{ .ID = 110000 };
    fixLevel(&prov);
    try testing.expectEqual(@as(i32, 1), prov.Level);

    var city = Area{ .ID = 110100 };
    fixLevel(&city);
    try testing.expectEqual(@as(i32, 2), city.Level);

    var county = Area{ .ID = 110101 };
    fixLevel(&county);
    try testing.expectEqual(@as(i32, 3), county.Level);

    var town = Area{ .ID = 110101001 };
    fixLevel(&town);
    try testing.expectEqual(@as(i32, 4), town.Level);

    try testing.expectEqual(@as(i32, 0), getParent(110000));
    try testing.expectEqual(@as(i32, 110000), getParent(110100));
    try testing.expectEqual(@as(i32, 110100), getParent(110101));
    try testing.expectEqual(@as(i32, 0), getParent(110101001));

    try testing.expectEqualStrings("华北", getBig("北京").?);
    try testing.expectEqualStrings("港澳台", getBig("澳门").?);
    try testing.expect(getBig("不存在") == null);
}

test "FixName：简称表 / 省市区后缀 / 民族名 / 四级" {
    // 简称表
    {
        var r = Area{ .ID = 150125, .ParentID = 150100, .Level = 3, .FullName = "达尔罕茂明安联合旗" };
        try testing.expectEqualStrings("达茂旗", fixName(&r));
    }
    // 省（ParentID = 0）
    {
        var r = Area{ .ID = 450000, .ParentID = 0, .Level = 1, .FullName = "广西壮族自治区" };
        try testing.expectEqualStrings("广西", fixName(&r));
    }
    {
        var r = Area{ .ID = 810000, .ParentID = 0, .Level = 1, .FullName = "香港特别行政区" };
        try testing.expectEqualStrings("香港", fixName(&r));
    }
    // 三级：去 "市/区/县"，民族名去尾
    {
        var r = Area{ .ID = 110101, .ParentID = 110100, .Level = 3, .FullName = "东城区" };
        try testing.expectEqualStrings("东城", fixName(&r));
    }
    {
        var r = Area{ .ID = 120102, .ParentID = 120100, .Level = 3, .FullName = "河东区" };
        try testing.expectEqualStrings("河东", fixName(&r));
    }
    // 四级：去 "街道" / "乡镇"
    {
        var r = Area{ .ID = 110101001, .ParentID = 110101, .Level = 4, .FullName = "东华门街道" };
        try testing.expectEqualStrings("东华门", fixName(&r));
    }
}

test "TrimEnd：循环去后缀（C# TrimSuffix 同口径）" {
    try testing.expectEqualStrings("广西", trimEnd("广西壮族自治区", &.{ "省", "市", "自治区", "壮族", "回族", "维吾尔", "特别行政区" }));
    try testing.expectEqualStrings("abc", trimEnd("abcxyzxyz", &.{"xyz"}));
    try testing.expectEqualStrings("", trimEnd("市市", &.{"市"}));
}

test "Parse / ParseLevel4：从民政部页面片段解析（黄金片段）" {
    const a = testing.allocator;

    // 索引口径来自 C#：`cells[3]` 是编码、`cells[5]` 是名称（`cells[0]` 是 `<tr` 的残余片段）
    const html =
        \\<table><tr ><td>1</td><td>华北</td><td>110000</td><td>x</td><td>北京市</td></tr>
        \\<tr ><td>2</td><td>华北</td><td>110100</td><td>y</td><td>市辖区*</td></tr></table>
    ;
    const list = try parseAlloc(a, html);
    defer a.free(list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(i32, 110000), list[0].ID);
    try testing.expectEqualStrings("北京市", list[0].FullName);
    try testing.expectEqual(@as(i32, 110100), list[1].ID);
    // 末尾的 `*` 被 Trim 掉
    try testing.expectEqualStrings("市辖区", list[1].FullName);

    const html4 =
        \\<tr class='towntr'><td><a href='1'>110101001000</a></td><td><a href='2'>东华门街道</a></td></tr>
    ;
    const l4 = try parseLevel4Alloc(a, html4);
    defer a.free(l4);
    try testing.expectEqual(@as(usize, 1), l4.len);
    try testing.expectEqual(@as(i32, 110101001), l4[0].ID);
    try testing.expectEqualStrings("东华门街道", l4[0].FullName);
}
