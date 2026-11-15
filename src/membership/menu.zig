//! 菜单索引与查询（≂ C# `Membership/IMenuFactory.cs` + `菜单.Biz.cs` 的查找/子菜单部分）。
//!
//! ## 为什么要索引
//!
//! 菜单是**热数据**（每个请求都可能做权限判断/渲染导航），C# 侧靠 `Meta.Cache`（整表缓存）
//! 支撑 `FindByName/FullName/Url` 这些「忽略大小写的等值查找」。本仓 `tree.zig` 提供的是
//! **查库版**（`children`/`roots`/`pathToRoot`），每渲染一次导航就多几条 SQL，不合适。
//! 这里补的是**内存索引版**：一次建索引，之后都是 O(1) / O(子菜单数)。
//!
//! ## 与 C# 的差异（有意）
//!
//! - C# `MenuFactory` 是「实体工厂 + 静态缓存」，`Root` 是工厂上的属性；本仓不猜 Root 的口径，
//!   只提供 `roots(out)`（`ParentID == 0` 的节点）。需要「唯一根」时由调用方从结果里取；
//! - 索引**不复制**菜单实体（只存下标），`list` 的生命周期必须覆盖索引的使用期。

const std = @import("std");
const Menu = @import("entities/Menu.zig").Menu;

/// 子菜单排序：`Sort` 降序、`ID` 升序（≂ C# `OrderByDescending(e => e.Sort).ThenBy(e => e.ID)`）。
fn lessThanSortId(_: void, x: *const Menu, y: *const Menu) bool {
    if (x.Sort != y.Sort) return x.Sort > y.Sort;
    return x.ID < y.ID;
}

/// 菜单索引（≂ C# `MenuFactory` 的缓存查找）。
pub const Index = struct {
    gpa: std.mem.Allocator,
    /// 小写化字符串的存放区（`by_name`/`by_full_name`/`by_url` 的键都指向这里）
    arena: std.heap.ArenaAllocator,
    list: []const Menu,

    by_id: std.AutoHashMapUnmanaged(i32, usize) = .empty,
    by_name: std.StringHashMapUnmanaged(usize) = .empty,
    by_full_name: std.StringHashMapUnmanaged(usize) = .empty,
    by_url: std.StringHashMapUnmanaged(usize) = .empty,
    /// 父编号 → 子节点下标（已按 `Sort` 降序 + `ID` 升序排好）
    children: std.AutoHashMapUnmanaged(i32, []usize) = .empty,

    /// 建索引。`list` 不复制（索引只存下标），调用方须保证它活得比索引久。
    pub fn buildAlloc(gpa: std.mem.Allocator, list: []const Menu) !Index {
        var self = Index{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa), .list = list };
        errdefer self.deinit();

        const a = self.arena.allocator();

        // 第一遍：按 id 建索引 + 收集「父 → 子」原始下标
        var children_raw: std.AutoHashMapUnmanaged(i32, std.ArrayListUnmanaged(usize)) = .empty;
        defer {
            var it = children_raw.valueIterator();
            while (it.next()) |v| v.deinit(gpa);
            children_raw.deinit(gpa);
        }

        for (list, 0..) |*e, i| {
            try self.by_id.put(gpa, e.ID, i);
            const gop = try children_raw.getOrPut(gpa, e.ParentID);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, i);
        }

        // 第二遍：小写键（忽略大小写等值查找，≂ C# `EqualIgnoreCase`）
        for (list) |*e| {
            if (e.Name.len > 0) try self.by_name.put(gpa, try lowerAlloc(a, e.Name), indexOfId(&self.by_id, e.ID));
            if (e.FullName.len > 0) try self.by_full_name.put(gpa, try lowerAlloc(a, e.FullName), indexOfId(&self.by_id, e.ID));
            if (e.Url.len > 0) try self.by_url.put(gpa, try lowerAlloc(a, e.Url), indexOfId(&self.by_id, e.ID));
        }

        // 第三遍：子菜单排序（Sort 降序 + ID 升序）
        var it = children_raw.iterator();
        while (it.next()) |kv| {
            const ids = kv.value_ptr.items;
            const owned = try gpa.alloc(usize, ids.len);
            errdefer gpa.free(owned);
            @memcpy(owned, ids);

            // 按指针排序：需要拿到 `*const Menu` 才能比 Sort/ID
            std.mem.sort(usize, owned, list, struct {
                fn lt(ctx: []const Menu, x: usize, y: usize) bool {
                    return lessThanSortId({}, &ctx[x], &ctx[y]);
                }
            }.lt);
            try self.children.put(gpa, kv.key_ptr.*, owned);
        }

        return self;
    }

    pub fn deinit(self: *Index) void {
        var cit = self.children.valueIterator();
        while (cit.next()) |v| self.gpa.free(v.*);
        self.children.deinit(self.gpa);
        self.by_id.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.by_full_name.deinit(self.gpa);
        self.by_url.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn findById(self: *const Index, id: i32) ?*const Menu {
        const i = self.by_id.get(id) orelse return null;
        return &self.list[i];
    }

    pub fn findByName(self: *const Index, name: []const u8) ?*const Menu {
        return self.lookupLower(&self.by_name, name);
    }

    pub fn findByFullName(self: *const Index, full_name: []const u8) ?*const Menu {
        return self.lookupLower(&self.by_full_name, full_name);
    }

    pub fn findByUrl(self: *const Index, url: []const u8) ?*const Menu {
        return self.lookupLower(&self.by_url, url);
    }

    /// 大小写不敏感查找：把查询键按同一口径小写化后查表（栈上小写化，避免每次分配）。
    fn lookupLower(self: *const Index, map: *const std.StringHashMapUnmanaged(usize), key: []const u8) ?*const Menu {
        if (key.len == 0) return null;
        if (key.len <= 128) {
            var buf: [128]u8 = undefined;
            for (key, 0..) |c, i| buf[i] = std.ascii.toLower(c);
            const i = map.get(buf[0..key.len]) orelse return null;
            return &self.list[i];
        }
        // 超长键（正常不会出现）：退化成不敏感遍历，避免堆分配
        var it = map.iterator();
        while (it.next()) |kv| {
            if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, key)) return &self.list[kv.value_ptr.*];
        }
        return null;
    }

    /// 根节点（`ParentID == 0`），按 `Sort` 降序 + `ID` 升序。
    pub fn rootsAlloc(self: *const Index, a: std.mem.Allocator) ![]const *const Menu {
        const ids = self.children.get(0) orelse return &.{};
        var out = try a.alloc(*const Menu, ids.len);
        for (ids, 0..) |i, k| out[k] = &self.list[i];
        return out;
    }

    /// 某父节点的子菜单（已排序）：`incl_invisible = false` 时只要 `Visible` 的。
    pub fn childrenAlloc(
        self: *const Index,
        parent_id: i32,
        incl_invisible: bool,
        a: std.mem.Allocator,
    ) ![]const *const Menu {
        const ids = self.children.get(parent_id) orelse return &.{};
        var out: std.ArrayListUnmanaged(*const Menu) = .empty;
        errdefer out.deinit(a);
        for (ids) |i| {
            const e = &self.list[i];
            if (!incl_invisible and !e.Visible) continue;
            try out.append(a, e);
        }
        return out.toOwnedSlice(a);
    }

    /// 指定用户（资源白名单）在 `parent_id` 下**有权访问**的子菜单
    /// （≂ C# `MenuFactory.GetMySubMenus` 里 `GetSubMenus(resources, inclInvisible)` 那段）。
    ///
    /// `resource_ids` = 该用户所有角色的资源（菜单 ID）并集；`parent_id <= 0` 时从根开始。
    pub fn mySubMenusAlloc(
        self: *const Index,
        parent_id: i32,
        resource_ids: []const i32,
        incl_invisible: bool,
        a: std.mem.Allocator,
    ) ![]const *const Menu {
        const all = try self.childrenAlloc(parent_id, incl_invisible, a);
        defer a.free(all);
        if (all.len == 0) return &.{};

        var out: std.ArrayListUnmanaged(*const Menu) = .empty;
        errdefer out.deinit(a);
        for (all) |e| {
            if (!containsId(resource_ids, e.ID)) continue;
            try out.append(a, e);
        }
        return out.toOwnedSlice(a);
    }

    /// 从某节点向上拼全路径（≂ C# `IMenu.GetFullPath`），分隔符由调用方给（如 `"/"`、`"\\"`）。
    ///
    /// 取的是 `Name`（C# 的 `GetFullPath(true, sep, e => e.FriendName)` 用的是显示相关字段，
    /// 本仓默认用 `Name`；要别的字段请用 `fullPathWithAlloc`）。
    pub fn fullPathAlloc(self: *const Index, a: std.mem.Allocator, id: i32, include_self: bool, sep: []const u8) ![]u8 {
        return self.fullPathWithAlloc(a, id, include_self, sep, false);
    }

    /// `use_display_name = true` 时用 `DisplayName`（为空则退回 `Name`），否则用 `Name`。
    pub fn fullPathWithAlloc(
        self: *const Index,
        a: std.mem.Allocator,
        id: i32,
        include_self: bool,
        sep: []const u8,
        use_display_name: bool,
    ) ![]u8 {
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer parts.deinit(a);

        // 先自下而上收集（带环保护：最多 list.len 层）
        var cur: ?*const Menu = self.findById(id);
        var steps: usize = 0;
        while (cur) |e| {
            if (steps > self.list.len) break;
            const is_self = steps == 0;
            steps += 1;
            if (!is_self or include_self) {
                const name = if (use_display_name and e.DisplayName.len > 0) e.DisplayName else e.Name;
                if (name.len > 0) try parts.append(a, name);
            }
            // 上溯：`ParentID == 0` **不是**终点——C# 的 Root 就是 `ID == 0` 的实体，
            // 所以继续找 `findById(0)`；找不到才停（普通表没有 ID=0 的根，自然就停）。
            if (e.ParentID == e.ID) break; // 自己指向自己（根）→ 停
            cur = self.findById(e.ParentID);
        }

        var b: std.ArrayListUnmanaged(u8) = .empty;
        errdefer b.deinit(a);
        var i = parts.items.len;
        while (i > 0) {
            i -= 1;
            if (b.items.len > 0) try b.appendSlice(a, sep);
            try b.appendSlice(a, parts.items[i]);
        }
        return b.toOwnedSlice(a);
    }
};

fn indexOfId(map: *const std.AutoHashMapUnmanaged(i32, usize), id: i32) usize {
    return map.get(id).?;
}

fn containsId(list: []const i32, id: i32) bool {
    for (list) |v| {
        if (v == id) return true;
    }
    return false;
}

fn lowerAlloc(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

// ── 测试 ──────────────────────────────────────────────────────────────

fn menu(id: i32, parent: i32, name: []const u8, display: []const u8, full: []const u8, url: []const u8, sort: i32, visible: bool) Menu {
    return .{
        .ID = id,
        .ParentID = parent,
        .Name = name,
        .DisplayName = display,
        .FullName = full,
        .Url = url,
        .Sort = sort,
        .Visible = visible,
    };
}

test "菜单索引：按 ID/Name/FullName/Url 查找（后三者忽略大小写）" {
    const a = std.testing.allocator;
    const list = [_]Menu{
        menu(0, 0, "Root", "根", "Root", "", 100, true),
        menu(1, 0, "System", "系统", "System", "/system", 50, true),
        menu(2, 1, "User", "用户管理", "System/User", "/system/user", 10, true),
        menu(3, 1, "Role", "角色管理", "System/Role", "/system/role", 20, false),
    };

    var idx = try Index.buildAlloc(a, &list);
    defer idx.deinit();

    try std.testing.expectEqualStrings("System", idx.findById(1).?.Name);
    try std.testing.expect(idx.findById(99) == null);

    // 忽略大小写
    try std.testing.expectEqualStrings("User", idx.findByName("user").?.Name);
    try std.testing.expectEqualStrings("User", idx.findByFullName("system/USER").?.Name);
    try std.testing.expectEqualStrings("Role", idx.findByUrl("/SYSTEM/Role").?.Name);
    try std.testing.expect(idx.findByName("nope") == null);
    try std.testing.expect(idx.findByName("") == null);
}

test "菜单索引：子菜单按 Sort 降序 + ID 升序；可过滤不可见" {
    const a = std.testing.allocator;
    const list = [_]Menu{
        menu(0, 0, "Root", "根", "Root", "", 100, true),
        menu(1, 0, "A", "甲", "A", "/a", 10, true),
        menu(2, 0, "B", "乙", "B", "/b", 30, true),
        menu(3, 0, "C", "丙", "C", "/c", 30, true), // 与 B 同 Sort → 按 ID 升序
        menu(4, 0, "D", "丁", "D", "/d", 20, false), // 不可见
    };

    var idx = try Index.buildAlloc(a, &list);
    defer idx.deinit();

    const visible = try idx.childrenAlloc(0, false, a);
    defer a.free(visible);
    try std.testing.expectEqual(@as(usize, 4), visible.len); // Root/B/C/A（D 不可见）
    try std.testing.expectEqual(@as(i32, 0), visible[0].ID); // Sort 100
    try std.testing.expectEqual(@as(i32, 2), visible[1].ID); // Sort 30 且 ID 小
    try std.testing.expectEqual(@as(i32, 3), visible[2].ID);
    try std.testing.expectEqual(@as(i32, 1), visible[3].ID); // Sort 10

    const all = try idx.childrenAlloc(0, true, a);
    defer a.free(all);
    try std.testing.expectEqual(@as(usize, 5), all.len);
}

test "菜单索引：按用户资源白名单过滤子菜单（≂ GetMySubMenus）" {
    const a = std.testing.allocator;
    const list = [_]Menu{
        menu(1, 0, "A", "甲", "A", "/a", 10, true),
        menu(2, 0, "B", "乙", "B", "/b", 20, true),
        menu(3, 0, "C", "丙", "C", "/c", 30, false),
    };

    var idx = try Index.buildAlloc(a, &list);
    defer idx.deinit();

    // 只授权 A 与 C；C 不可见 → 只要 A
    const mine = try idx.mySubMenusAlloc(0, &.{ 1, 3 }, false, a);
    defer a.free(mine);
    try std.testing.expectEqual(@as(usize, 1), mine.len);
    try std.testing.expectEqual(@as(i32, 1), mine[0].ID);

    // 含不可见 → A + C
    const mine_all = try idx.mySubMenusAlloc(0, &.{ 1, 3 }, true, a);
    defer a.free(mine_all);
    try std.testing.expectEqual(@as(usize, 2), mine_all.len);

    // 没有任何资源 → 空
    const none = try idx.mySubMenusAlloc(0, &.{}, true, a);
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "菜单索引：全路径由下向上拼（含/不含自身、显示名优先）" {
    const a = std.testing.allocator;
    const list = [_]Menu{
        menu(0, 0, "Root", "根", "Root", "", 100, true),
        menu(1, 0, "System", "系统", "System", "/system", 50, true),
        menu(2, 1, "User", "用户管理", "System/User", "/system/user", 10, true),
    };

    var idx = try Index.buildAlloc(a, &list);
    defer idx.deinit();

    const p1 = try idx.fullPathAlloc(a, 2, true, "/");
    defer a.free(p1);
    try std.testing.expectEqualStrings("Root/System/User", p1);

    const p2 = try idx.fullPathAlloc(a, 2, false, "/");
    defer a.free(p2);
    try std.testing.expectEqualStrings("Root/System", p2);

    const p3 = try idx.fullPathWithAlloc(a, 2, true, "\\", true);
    defer a.free(p3);
    try std.testing.expectEqualStrings("根\\系统\\用户管理", p3);
}
