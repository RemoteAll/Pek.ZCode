//! 操作日志（对应 C# `Membership/LogProvider.cs` + `Membership/LogEntity.cs`）。
//!
//! 口径逐条对齐 C#（`LogProvider.cs:151-245`）：
//! - `CreateLog` 构造实体**不落库**；`LinkID` 从 `remark` 的 `ID=xxx,` 前缀解析（`:55-58`）；
//! - 修改动作写**脏字段差量** `Name=旧值 -> 新值`，其它动作写**全字段** `Name=值`；
//! - `pass` / `password` 字段值**强制屏蔽**（写空），日志里永不出现口令；
//! - 非修改动作跳过「空串 / false / 0 / DateTime.MinValue」；
//! - 字段之间用 `,` 分隔（C# `sb.Separate(",")`）。
//!
//! **已知差异（显式记录，不悄悄改）**：
//! 1. C# 的脏字段字典 `Dirtys.GetDictionary()` **带旧值**，所以能写 `旧 -> 新`；
//!    本仓实体的脏位图只记录"哪些列被改过"，不存旧值。因此本实现要求调用方**可选**传入
//!    `old_values`；不传时只写新值（`Name=新值`），并在文档里说明这是精度降级。
//! 2. C# 源码 `if (error.IsNullOrEmpty()) sb.Append(error);`（`:160`）只在**错误为空**时追加，
//!    等于从不写错误信息——那是笔误。本实现按显式意图追加 `error`，并在 `--` 后注明。
//!
//! 表归属：`Log` 表在 `Log` 连接（`Member.xml` 表级 `ConnName="Log"`），
//! 所以写日志必须用**连到 Log 库**的 `Dal`；不要拿 Membership 库的 Dal 去写。

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("../root.zig");
const entities = @import("entities/mod.zig");

const Value = zzig.db.Value;

/// 动作常量（C# 里是字面量比较，这里收敛成常量，避免各处拼错）。
pub const action = struct {
    pub const insert = "添加";
    pub const update = "修改";
    pub const delete = "删除";
    pub const login = "登录";
    pub const logout = "注销";
    pub const register = "注册";
    pub const change_password = "修改密码";
};

/// 当前登录用户（`CreateLog` 缺 `userid` / `name` 时用它补齐）。
pub const CurrentUser = struct {
    id: i32 = 0,
    name: []const u8 = "",
};

/// 判断是否"修改"动作（C# 大小写敏感地比 `"修改"` 与 `"Update"`，这里保持一致）。
pub fn isUpdateAction(a: []const u8) bool {
    return std.mem.eql(u8, a, action.update) or std.mem.eql(u8, a, "Update");
}

/// 是否需要跳过"空值"字段（C# 只对这四个动作做过滤）。
fn skipEmptyFields(a: []const u8) bool {
    return std.mem.eql(u8, a, action.insert) or
        std.mem.eql(u8, a, action.delete) or
        std.mem.eql(u8, a, "Insert") or
        std.mem.eql(u8, a, "Delete");
}

/// 是否口令字段（`pass` / `password`，忽略大小写）。
pub fn isPasswordField(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "pass") or std.ascii.eqlIgnoreCase(name, "password");
}

/// 从 `remark` 解析关联编号：`"ID=123,..."` → 123（C# `:55-58`）。
///
/// 只在 `remark` **以 `ID=`（忽略大小写）开头**时解析；取 `ID=` 到下一个 `,` 之间。
/// 解析失败返回 null（C# `ToLong()` 失败给 0，这里用 null 区分"没有"与"0"）。
pub fn parseLinkId(remark: []const u8) ?i64 {
    if (remark.len < 3) return null;
    if (!std.ascii.eqlIgnoreCase(remark[0..3], "ID=")) return null;

    const rest = remark[3..];
    const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
    if (end == 0) return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, rest[0..end], " \t"), 10) catch null;
}

/// 值的文本化（对齐 C# `entity[fi.Name]` 的 `ToString`）：
/// - null → 空串（与 `$"{null}"` 一致）
/// - bool → `True` / `False`（C# `Boolean.ToString()`）
/// - 日期 → `DateTime.formatAlloc()`（本仓全精度格式；C# 是 `ToFullString()`）
/// - 其它 → 原样文本 / 数字
fn pushValue(a: std.mem.Allocator, b: *zzig.Buf, v: Value) !void {
    switch (v) {
        .null => {},
        .boolean => |x| try b.add(if (x) "True" else "False"),
        .int => |x| try b.fmt("{d}", .{x}),
        .float => |x| try b.fmt("{d}", .{x}),
        .decimal => |x| try b.fmt("{d}", .{x.toF64()}),
        .text => |t| try b.add(t),
        .blob => |x| try b.fmt("System.Byte[{d}]", .{x.len}),
        .datetime => |dt| {
            const s = try dt.formatAlloc(a);
            defer a.free(s);
            try b.add(s);
        },
    }
}

/// 该字段在"非修改"动作下是否应跳过（空串 / false / 0 / 最小日期）。
fn shouldSkip(v: Value) bool {
    return switch (v) {
        .null => true,
        .text => |t| t.len == 0,
        .boolean => |x| !x,
        .int => |x| x == 0,
        .float => |x| x == 0,
        .datetime => |dt| dt.eql(.{}),
        else => false,
    };
}

/// 构造实体日志的 `Remark`（C# `WriteLog(action, entity, error)` 的拼接部分）。
///
/// `old_values` 若给出，长度必须与 `T.meta.fields` 一致（未脏的位置忽略），
/// 用于输出 `Name=旧 -> 新`；不给出则只写 `Name=新`。
pub fn buildRemarkAlloc(
    a: std.mem.Allocator,
    act: []const u8,
    e: anytype,
    old_values: ?[]const Value,
) ![]u8 {
    const T = @TypeOf(e.*);
    const meta = T.meta;

    var b = zzig.Buf.init(a);
    defer b.deinit();

    var first = true;
    if (isUpdateAction(act)) {
        inline for (meta.fields, 0..) |f, i| {
            if (f.primary_key) {
                // 主键：总是写 `Name=值`
                if (!first) try b.addByte(',');
                first = false;

                const new_value: Value = if (comptime isPasswordField(f.name)) .null else e.columnValue(i);
                try b.fmt("{s}=", .{f.name});
                try pushValue(a, &b, new_value);
            } else if (zcode.entity.isDirty(e.dirty, i)) {
                // 非主键：只写脏字段（C# `ds.TryGetValue` 不命中就 continue）
                if (!first) try b.addByte(',');
                first = false;

                const new_value: Value = if (comptime isPasswordField(f.name)) .null else e.columnValue(i);
                var old_value: Value = if (old_values) |ov| ov[i] else .null;
                if (comptime isPasswordField(f.name)) old_value = .null;

                try b.fmt("{s}=", .{f.name});
                try pushValue(a, &b, old_value);
                try b.add(" -> ");
                try pushValue(a, &b, new_value);
            }
        }
    } else {
        const skip_empty = skipEmptyFields(act);
        inline for (meta.fields, 0..) |f, i| {
            var v: Value = e.columnValue(i);
            // 非修改动作跳过空值（C# 只对 添加/删除/Insert/Delete 过滤）
            if (!(skip_empty and shouldSkip(v))) {
                if (comptime isPasswordField(f.name)) v = .null;

                if (!first) try b.addByte(',');
                first = false;
                try b.fmt("{s}=", .{f.name});
                try pushValue(a, &b, v);
            }
        }
    }

    return b.toOwnedSlice();
}

/// 日志提供者（C# `LogProvider`）。
///
/// `enable == false` 时 `write` 直接返回（C# `if (!Enable) return;`）。
pub const LogProvider = struct {
    enable: bool = true,
    /// 当前登录用户（补齐 `CreateUserID` / `UserName`）
    current: ?CurrentUser = null,
    /// 缺省 IP（C# `ManageProvider.UserHost`）
    host: []const u8 = "",

    /// 构造日志实体（**不落库**）。
    ///
    /// 字段值是**借引用**（不复制）：`category` / `act` / `remark` / `name` / `ip`
    /// 必须在握手中活到 `insert` 之后（`write` 里已经保证这一点）。
    pub fn createLog(
        self: LogProvider,
        category: []const u8,
        act: []const u8,
        success: bool,
        remark: []const u8,
        user_id: i32,
        user_name: []const u8,
        ip: []const u8,
    ) !entities.Log {
        if (category.len == 0) return error.MissingCategory;

        var log = entities.Log{};
        log.Category = category;
        log.Action = act;
        log.Success = success;
        log.Remark = remark;
        log.CreateTime = zzig.DateTime.nowLocal();

        if (parseLinkId(remark)) |link| log.LinkID = link;

        var uid = user_id;
        var name = user_name;
        if (ip.len > 0) {
            log.CreateIP = ip;
        } else if (self.host.len > 0) {
            log.CreateIP = self.host;
        }
        if (uid == 0 or name.len == 0) {
            if (self.current) |u| {
                if (uid == 0) uid = u.id;
                if (name.len == 0) name = u.name;
            }
        }
        log.CreateUserID = uid;
        log.UserName = name;
        return log;
    }

    /// 写一条实体日志（异步落库在 C# 是 `SaveAsync()`；Zig 侧同步写，调用方自行决定是否放队列）。
    ///
    /// `dal` 必须连到 **Log 库**（`Log` 表级 `ConnName="Log"`）。
    pub fn write(
        self: LogProvider,
        a: std.mem.Allocator,
        dal: *zcode.Dal,
        s: *zcode.Session,
        category: []const u8,
        act: []const u8,
        e: anytype,
        err_msg: []const u8,
        old_values: ?[]const Value,
    ) !i64 {
        if (!self.enable) return 0;

        const remark = try buildRemarkAlloc(a, act, e, old_values);
        defer a.free(remark);

        // C# 的 `if (error.IsNullOrEmpty()) sb.Append(error);` 是笔误（从不写错误），
        // 这里按显式意图把错误附在后面。
        const full = if (err_msg.len > 0)
            try std.fmt.allocPrint(a, "{s},{s}", .{ remark, err_msg })
        else
            try a.dupe(u8, remark);
        defer a.free(full);

        var log = try self.createLog(category, act, err_msg.len == 0, full, 0, "", "");
        return try zcode.entity.insert(dal, &log, s);
    }
};

test "LinkID：只认 ID= 前缀，取到下一个逗号" {
    try std.testing.expectEqual(@as(?i64, 123), parseLinkId("ID=123,其它"));
    try std.testing.expectEqual(@as(?i64, 123), parseLinkId("id=123"));
    try std.testing.expectEqual(@as(?i64, 123), parseLinkId("ID=123"));
    try std.testing.expectEqual(@as(?i64, null), parseLinkId("ID=abc,x"));
    try std.testing.expectEqual(@as(?i64, null), parseLinkId("编号=123"));
    try std.testing.expectEqual(@as(?i64, null), parseLinkId(""));
    try std.testing.expectEqual(@as(?i64, null), parseLinkId("ID=,x"));
}

test "口令字段识别" {
    try std.testing.expect(isPasswordField("pass"));
    try std.testing.expect(isPasswordField("Password"));
    try std.testing.expect(!isPasswordField("PasswordUpdated"));
}

test "修改动作：只写脏字段，口令屏蔽，格式 Name=旧 -> 新" {
    const a = std.testing.allocator;
    const Row = struct {
        dirty: zcode.entity.DirtyBits = 0,
        ID: i32 = 7,
        Name: []const u8 = "新名",
        Password: []const u8 = "secret",

        pub const meta = zcode.entity.EntityMeta{
            .name = "Row",
            .table_name = "Row",
            .fields = &.{
                .{ .name = "ID", .data_type = .int32, .primary_key = true },
                .{ .name = "Name", .data_type = .string },
                .{ .name = "Password", .data_type = .string },
            },
        };

        pub fn columnValue(self: @This(), i: usize) Value {
            return switch (i) {
                0 => .{ .int = self.ID },
                1 => .{ .text = self.Name },
                2 => .{ .text = self.Password },
                else => .null,
            };
        }
    };

    var r = Row{};
    zcode.entity.markDirty(&r.dirty, 1); // Name
    zcode.entity.markDirty(&r.dirty, 2); // Password

    // 无旧值：只写新值
    const s1 = try buildRemarkAlloc(a, action.update, &r, null);
    defer a.free(s1);
    try std.testing.expectEqualStrings("ID=7,Name= -> 新名,Password= -> ", s1);

    // 有旧值：写 旧 -> 新
    const old = [_]Value{ .{ .int = 7 }, .{ .text = "旧名" }, .{ .text = "old-secret" } };
    const s2 = try buildRemarkAlloc(a, action.update, &r, &old);
    defer a.free(s2);
    try std.testing.expectEqualStrings("ID=7,Name=旧名 -> 新名,Password= -> ", s2);
}

test "添加动作：写全字段、跳过空值、口令屏蔽" {
    const a = std.testing.allocator;
    const Row = struct {
        dirty: zcode.entity.DirtyBits = 0,
        ID: i32 = 5,
        Name: []const u8 = "",
        Score: i32 = 0,
        Ok: bool = false,
        Password: []const u8 = "secret",

        pub const meta = zcode.entity.EntityMeta{
            .name = "Row",
            .table_name = "Row",
            .fields = &.{
                .{ .name = "ID", .data_type = .int32, .primary_key = true },
                .{ .name = "Name", .data_type = .string },
                .{ .name = "Score", .data_type = .int32 },
                .{ .name = "Ok", .data_type = .boolean },
                .{ .name = "Password", .data_type = .string },
            },
        };

        pub fn columnValue(self: @This(), i: usize) Value {
            return switch (i) {
                0 => .{ .int = self.ID },
                1 => .{ .text = self.Name },
                2 => .{ .int = self.Score },
                3 => .{ .boolean = self.Ok },
                4 => .{ .text = self.Password },
                else => .null,
            };
        }
    };

    const r = Row{};
    const s = try buildRemarkAlloc(a, action.insert, &r, null);
    defer a.free(s);
    // Name/Score/Ok 被跳过；Password 不跳过（它不是空值），但值屏蔽
    try std.testing.expectEqualStrings("ID=5,Password=", s);
}
