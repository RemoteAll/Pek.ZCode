//! 登录提供者（对应 C# `Membership/IManageProvider.cs` 的 `ManageProvider`）。
//!
//! 只迁移**登录/注册/改密**这三条主流程的判定逻辑；数据读写通过 `UserStore` 注入，
//! 这样规则可以单测（真实落库由 `zcode.entity` 实现后注入即可），也不会把 ORM 细节耦合进来。
//!
//! `LoginCore` 严格按 C# 八步（`IManageProvider.cs` 的 `LoginCore`）：
//! 1. 用户名空 → 报错；
//! 2. `Trim()` 后**必须从库查**（缓存里的用户可能没有密码字段）；
//! 3. 找不到 → 「用户名或密码不正确！」；被禁用 → 「账号{0}被禁用！」；
//! 4. 口令提供者必须存在（本仓固定 `md5+sha1`）；
//! 5. **库密码为空 → 任何密码都可登录**，并把该密码散列后落库；
//! 6. 旧格式（不含 `$`）自动升级为 `$md5+sha1$…`；
//! 7. 保存登录信息（登录次数 +1、最后登录时间/IP、在线）；
//! 8. 失败写日志后**重抛**（不吞异常）。

const std = @import("std");
const zzig = @import("zzig");
const entities = @import("entities/mod.zig");
const password = @import("password.zig");
const log_mod = @import("log.zig");

/// 登录失败原因（对应 C# 抛出的异常类型 + 文案）。
pub const LoginError = error{
    EmptyUsername,
    UserNotFound,
    Disabled,
    BadPassword,
    StoreFailed,
};

/// 失败原因 → 面向用户的文案（与 C# 逐字一致）。
///
/// `account` 用于 `"账号{0}被禁用！"` 的格式化；其它错误不需要。
pub fn errorMessage(err: anyerror, a: std.mem.Allocator, account: []const u8) ![]u8 {
    return switch (err) {
        error.EmptyUsername, error.UserNotFound, error.BadPassword => try a.dupe(u8, "用户名或密码不正确！"),
        error.Disabled => try std.fmt.allocPrint(a, "账号{s}被禁用！", .{account}),
        error.StoreFailed => try a.dupe(u8, "保存用户信息失败！"),
        else => try std.fmt.allocPrint(a, "{s}", .{@errorName(err)}),
    };
}

/// 用户读写注入点（真实实现用 `zcode.entity` 的 `findByPk` / `update` / `insert`）。
pub const UserStore = struct {
    ctx: *anyopaque,
    /// 按账号查（C# `User.FindForLogin`，支持账号 / 邮箱 / 手机 / 代码）
    findByNameFn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, name: []const u8) anyerror!?entities.User,
    /// 保存用户（新增或更新）；`true` 表示落库成功
    saveFn: *const fn (ctx: *anyopaque, user: *entities.User) anyerror!void,

    fn findByName(self: UserStore, a: std.mem.Allocator, name: []const u8) !?entities.User {
        return self.findByNameFn(self.ctx, a, name);
    }

    fn save(self: UserStore, user: *entities.User) !void {
        try self.saveFn(self.ctx, user);
    }
};

/// 登录结果。
pub const LoginOutcome = struct {
    /// 登录成功后的用户（可能被就地修改：口令升级、登录信息）
    user: entities.User,
    /// 是否发生了口令格式升级（旧格式 → `$md5+sha1$`）
    upgraded: bool,
    /// 是否把「库密码为空」时的明文散列写进了内存对象（调用方负责落库）
    wrote_password: bool,
};

/// 登录核心（不写日志、不落库，只做判定与内存态更新；落库由调用方 `store.save`）。
///
/// 与 C# 一致的关键行为：
/// - **库密码为空 → 任何密码可登录**（并把该密码散列后写入 `user.Password`）；
/// - 旧格式（不含 `$`）→ 用当前密码重新散列并标记 `upgraded`；
/// - 禁用账号直接拒绝（在口令校验之前）。
pub fn loginCore(
    a: std.mem.Allocator,
    store: UserStore,
    username: []const u8,
    plain_or_md5: []const u8,
    now: zzig.DateTime,
    ip: []const u8,
) !LoginOutcome {
    // 1. 用户名空
    if (username.len == 0) return LoginError.EmptyUsername;

    // 2. Trim 后必须从库查（缓存里的用户可能没有密码字段）
    const account = std.mem.trim(u8, username, " \t\r\n");
    if (account.len == 0) return LoginError.EmptyUsername;

    // 查库失败与"查不到"要区分：前者是存储层问题，后者才是账号不存在
    var user = (store.findByName(a, account) catch return LoginError.StoreFailed) orelse return LoginError.UserNotFound;

    // 3. 禁用
    if (!user.@"Enable") return LoginError.Disabled;

    var upgraded = false;
    var wrote_password = false;

    // 5. 库密码为空 → 任意密码可登录，并写回散列
    if (user.@"Password".len == 0) {
        user.@"Password" = try password.hashAlloc(a, plain_or_md5);
        wrote_password = true;
    } else {
        // 校验失败一律"用户名或密码不正确"
        if (!password.verify(plain_or_md5, user.@"Password")) return LoginError.BadPassword;

        // 6. 旧格式自动升级
        if (password.needsUpgrade(user.@"Password")) {
            user.@"Password" = try password.hashAlloc(a, plain_or_md5);
            upgraded = true;
        }
    }

    // 7. 登录信息
    user.@"Logins" += 1;
    user.@"LastLogin" = now;
    user.@"LastLoginIP" = ip;
    user.@"Online" = true;
    user.setLogins(user.@"Logins");
    user.setLastLogin(now);
    user.setLastLoginIP(ip);
    user.setOnline(true);

    return .{ .user = user, .upgraded = upgraded, .wrote_password = wrote_password };
}

/// 注册判定（C# `ManageProvider.Register`）：
/// 已存在 → 「用户[{name}]已存在！」；否则散列口令并返回待保存的用户。
pub const RegisterError = error{ AlreadyExists, EmptyUsername };

pub fn registerCore(
    a: std.mem.Allocator,
    store: UserStore,
    username: []const u8,
    plain_password: []const u8,
    role_id: i32,
    enable: bool,
) !entities.User {
    if (username.len == 0) return RegisterError.EmptyUsername;
    const account = std.mem.trim(u8, username, " \t\r\n");
    if (account.len == 0) return RegisterError.EmptyUsername;

    if (try store.findByName(a, account) != null) return RegisterError.AlreadyExists;

    var user = entities.User{};
    user.@"Name" = account;
    user.@"Password" = try password.hashAlloc(a, plain_password);
    user.@"Enable" = enable; // C# 默认 false（待审核）
    user.@"RoleID" = role_id;
    user.@"RoleIds" = "";
    user.@"RegisterTime" = zzig.DateTime.nowLocal();
    return user;
}

/// 改密判定（C# `ManageProvider.ChangePassword`）：
/// 账号不存在 → `UserNotFound`；禁用 → `Disabled`；
/// **旧密码非空且库密码非空时才校验**；通过后写新散列。
pub fn changePasswordCore(
    a: std.mem.Allocator,
    store: UserStore,
    username: []const u8,
    new_password: []const u8,
    old_password: []const u8,
) !entities.User {
    if (username.len == 0) return LoginError.UserNotFound;
    const account = std.mem.trim(u8, username, " \t\r\n");

    var user = (store.findByName(a, account) catch return LoginError.StoreFailed) orelse return LoginError.UserNotFound;
    if (!user.@"Enable") return LoginError.Disabled;

    if (old_password.len > 0 and user.@"Password".len > 0) {
        if (!password.verify(old_password, user.@"Password")) return LoginError.BadPassword;
    }

    user.@"Password" = try password.hashAlloc(a, new_password);
    user.setPassword(user.@"Password");
    return user;
}

/// 当前登录用户持有者（C# `IManageProvider.Current`）。
pub const ManageProvider = struct {
    current: ?entities.User = null,
    log_provider: log_mod.LogProvider = .{},

    pub fn logout(self: *ManageProvider) void {
        self.current = null;
    }

    /// 是否已登录
    pub fn isLoggedIn(self: *const ManageProvider) bool {
        return self.current != null;
    }
};

// ---------------------------------------------------------------------------
// 单测：用内存假 store
// ---------------------------------------------------------------------------

const FakeStore = struct {
    users: std.ArrayList(entities.User) = .empty,
    gpa: std.mem.Allocator,
    saves: usize = 0,

    fn init(a: std.mem.Allocator) FakeStore {
        return .{ .gpa = a };
    }

    fn deinit(self: *FakeStore) void {
        self.users.deinit(self.gpa);
    }

    fn add(self: *FakeStore, u: entities.User) !void {
        try self.users.append(self.gpa, u);
    }

    fn findByNameFn(ctx: *anyopaque, a: std.mem.Allocator, name: []const u8) anyerror!?entities.User {
        _ = a;
        const self: *FakeStore = @ptrCast(@alignCast(ctx));
        for (self.users.items) |u| {
            if (std.ascii.eqlIgnoreCase(u.@"Name", name)) return u;
        }
        return null;
    }

    fn saveFn(ctx: *anyopaque, user: *entities.User) anyerror!void {
        const self: *FakeStore = @ptrCast(@alignCast(ctx));
        self.saves += 1;
        for (self.users.items, 0..) |*u, i| {
            if (u.@"ID" == user.@"ID") {
                self.users.items[i] = user.*;
                return;
            }
        }
        try self.users.append(self.gpa, user.*);
    }

    fn store(self: *FakeStore) UserStore {
        return .{ .ctx = self, .findByNameFn = findByNameFn, .saveFn = saveFn };
    }
};

test "LoginCore：用户名空 / 不存在 / 禁用 / 密码错" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = FakeStore.init(a);
    defer fake.deinit();

    var u = entities.User{};
    u.@"ID" = 2;
    u.@"Name" = "alice";
    u.@"Enable" = true;
    u.@"Password" = try password.hashAlloc(a, "p@ss");
    try fake.add(u);

    const now = zzig.DateTime.fromUnixSeconds(1_700_000_000);
    try std.testing.expectError(LoginError.EmptyUsername, loginCore(a, fake.store(), "", "x", now, "1.2.3.4"));
    try std.testing.expectError(LoginError.UserNotFound, loginCore(a, fake.store(), "bob", "x", now, "1.2.3.4"));
    try std.testing.expectError(LoginError.BadPassword, loginCore(a, fake.store(), "alice", "wrong", now, "1.2.3.4"));

    var disabled = entities.User{};
    disabled.@"Name" = "carol";
    disabled.@"Enable" = false;
    disabled.@"Password" = try password.hashAlloc(a, "x");
    try fake.add(disabled);
    try std.testing.expectError(LoginError.Disabled, loginCore(a, fake.store(), "carol", "x", now, "1.2.3.4"));
}

test "LoginCore：成功登录会累加次数并写最后登录信息" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = FakeStore.init(a);
    defer fake.deinit();

    var u = entities.User{};
    u.@"ID" = 3;
    u.@"Name" = "dave";
    u.@"Enable" = true;
    u.@"Logins" = 5;
    u.@"Password" = try password.hashAlloc(a, "secret");
    try fake.add(u);

    const now = zzig.DateTime.fromUnixSeconds(1_700_000_000);
    const r = try loginCore(a, fake.store(), "  dave  ", "secret", now, "9.9.9.9");
    try std.testing.expectEqual(@as(i32, 6), r.user.@"Logins");
    try std.testing.expect(r.user.@"Online");
    try std.testing.expectEqualStrings("9.9.9.9", r.user.@"LastLoginIP");
    try std.testing.expect(!r.upgraded);

    // 前端 MD5 传输也应能登录
    var md5: [32]u8 = undefined;
    password.md5HexLower(&md5, "secret");
    const r2 = try loginCore(a, fake.store(), "dave", &md5, now, "");
    try std.testing.expectEqual(@as(i32, 6), r2.user.@"Logins");
}

test "LoginCore：库密码为空 → 任意密码可登录并写回散列（C# 兼容行为）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = FakeStore.init(a);
    defer fake.deinit();

    var u = entities.User{};
    u.@"ID" = 4;
    u.@"Name" = "empty";
    u.@"Enable" = true;
    u.@"Password" = "";
    try fake.add(u);

    const now = zzig.DateTime.fromUnixSeconds(1_700_000_000);
    const r = try loginCore(a, fake.store(), "empty", "whatever", now, "");
    try std.testing.expect(r.wrote_password);
    try std.testing.expect(std.mem.startsWith(u8, r.user.@"Password", "$md5+sha1$"));
    try std.testing.expect(password.verify("whatever", r.user.@"Password"));
}

test "LoginCore：旧格式（裸 MD5）登录后自动升级" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = FakeStore.init(a);
    defer fake.deinit();

    var md5: [32]u8 = undefined;
    password.md5HexUpper(&md5, "legacy");

    var u = entities.User{};
    u.@"ID" = 5;
    u.@"Name" = "old";
    u.@"Enable" = true;
    u.@"Password" = &md5;
    try fake.add(u);

    const now = zzig.DateTime.fromUnixSeconds(1_700_000_000);
    const r = try loginCore(a, fake.store(), "old", "legacy", now, "");
    try std.testing.expect(r.upgraded);
    try std.testing.expect(std.mem.startsWith(u8, r.user.@"Password", "$md5+sha1$"));
}

test "Register：已存在则拒绝；否则口令散列且默认待审核" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = FakeStore.init(a);
    defer fake.deinit();

    var u = entities.User{};
    u.@"Name" = "taken";
    try fake.add(u);

    try std.testing.expectError(RegisterError.AlreadyExists, registerCore(a, fake.store(), "TAKEN", "x", 0, false));
    try std.testing.expectError(RegisterError.EmptyUsername, registerCore(a, fake.store(), "  ", "x", 0, false));

    const created = try registerCore(a, fake.store(), " newbie ", "pw", 3, false);
    try std.testing.expectEqualStrings("newbie", created.@"Name");
    try std.testing.expect(!created.@"Enable");
    try std.testing.expectEqual(@as(i32, 3), created.@"RoleID");
    try std.testing.expect(password.verify("pw", created.@"Password"));
}

test "ChangePassword：旧密码为空则跳过校验；旧密码错则拒绝" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = FakeStore.init(a);
    defer fake.deinit();

    var u = entities.User{};
    u.@"ID" = 6;
    u.@"Name" = "eve";
    u.@"Enable" = true;
    u.@"Password" = try password.hashAlloc(a, "old-pw");
    try fake.add(u);

    try std.testing.expectError(LoginError.BadPassword, changePasswordCore(a, fake.store(), "eve", "new-pw", "bad"));

    // 旧密码留空 → 直接改（C# 同）
    const changed = try changePasswordCore(a, fake.store(), "eve", "new-pw", "");
    try std.testing.expect(password.verify("new-pw", changed.@"Password"));

    // 旧密码正确
    const changed2 = try changePasswordCore(a, fake.store(), "eve", "newer", "old-pw");
    try std.testing.expect(password.verify("newer", changed2.@"Password"));

    try std.testing.expectError(LoginError.UserNotFound, changePasswordCore(a, fake.store(), "ghost", "x", ""));
}

test "失败文案与 C# 一致" {
    const a = std.testing.allocator;
    const m1 = try errorMessage(LoginError.BadPassword, a, "alice");
    defer a.free(m1);
    try std.testing.expectEqualStrings("用户名或密码不正确！", m1);

    const m2 = try errorMessage(LoginError.Disabled, a, "alice");
    defer a.free(m2);
    try std.testing.expectEqualStrings("账号alice被禁用！", m2);
}
