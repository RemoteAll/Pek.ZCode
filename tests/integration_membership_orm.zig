//! 集成测试：Membership 的真实数据访问（`OrmStore`）——注册 / 登录 / 改密 / 退出。
//!
//! 用**真 `Model.xml`**（`tests/fixtures/dh-ncode-model.xml`）+ 真 SQLite：
//! `User` 在模型默认连接 `Membership`，`Log` 表级 `ConnName="Log"` → 一并验证
//! 「表在哪个库由模型决定、调用方不拼连接名」这条口径。

const std = @import("std");
const zcode = @import("zcode");
const zzig = @import("zzig");

const provider = zcode.membership.provider;
const User = zcode.membership.entities.User;

const Env = struct {
    gpa: std.mem.Allocator,
    dal: zcode.Dal,
    user_db: []u8,
    log_db: []u8,

    fn open(gpa: std.mem.Allocator) !Env {
        const user_db = try zcode.File.UniqueTempName(gpa, "morm-user", ".db");
        errdefer gpa.free(user_db);
        const log_db = try zcode.File.UniqueTempName(gpa, "morm-log", ".db");
        errdefer gpa.free(log_db);

        const m = try zcode.EntityModel.load(gpa, "tests/fixtures/dh-ncode-model.xml");
        const conn = try std.fmt.allocPrint(gpa, "Data Source={s};Provider=SQLite", .{user_db});
        defer gpa.free(conn);
        var dal = try zcode.Dal.initWithModel(gpa, conn, m);
        errdefer dal.deinit();

        // `Log` 表级 `ConnName="Log"`：必须显式挂载，否则 `syncSchema` 会拒绝静默建到主库
        const log_conn = try std.fmt.allocPrint(gpa, "Data Source={s};Provider=SQLite", .{log_db});
        defer gpa.free(log_conn);
        try dal.attachConnection("Log", log_conn);

        return .{ .gpa = gpa, .dal = dal, .user_db = user_db, .log_db = log_db };
    }

    fn deinit(self: *Env) void {
        self.dal.deinit();
        zcode.File.DeleteQuiet(self.user_db);
        zcode.File.DeleteQuiet(self.log_db);
        self.gpa.free(self.user_db);
        self.gpa.free(self.log_db);
    }
};

fn schemaReady(env: *Env) !void {
    var s = try env.dal.openSession();
    defer s.deinit();
    const report = try env.dal.syncSchema(&s);
    try std.testing.expect(report.tables_created > 0);
}

test "OrmStore：注册落库、登录累加、四类账号可查（Name/Mail/Mobile/Code）" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const old_setting = zcode.setting.snapshot();
    defer zcode.setting.restore(old_setting);

    var env = try Env.open(gpa);
    defer env.deinit();
    try schemaReady(&env);

    var store = provider.OrmStore.init(&env.dal);
    var mp = provider.ManageProvider{};
    mp.bindStore(store.store());

    // 1) 注册：口令以 `$md5+sha1$` 落库，自增 ID 回写
    const created = try mp.register(a, "  admin  ", "pass123", 3, true);
    try std.testing.expect(created.ID > 0);
    try std.testing.expectEqualStrings("admin", created.Name);
    try std.testing.expect(std.mem.startsWith(u8, created.Password, "$md5+sha1$"));

    const from_db = (try store.findByAlloc(a, "Name", "admin")).?;
    try std.testing.expectEqual(created.ID, from_db.ID);
    try std.testing.expect(from_db.Enable);
    try std.testing.expectEqual(@as(i32, 3), from_db.RoleID);

    // 重复注册 → AlreadyExists
    try std.testing.expectError(error.AlreadyExists, mp.register(a, "admin", "x", 0, false));

    // 2) 四类账号：Mail / Mobile / Code（C# `User.FindForLogin` 顺序）
    {
        var u = (try store.findByAlloc(a, "Name", "admin")).?;
        u.setMail("admin@example.com");
        u.setMobile("13800138000");
        u.setCode("E1001");
        _ = try store.saveUser(&u);
    }
    try std.testing.expect((try store.findForLoginAlloc(a, "admin")) != null);
    try std.testing.expect((try store.findForLoginAlloc(a, "admin@example.com")) != null);
    try std.testing.expect((try store.findForLoginAlloc(a, "13800138000")) != null);
    try std.testing.expect((try store.findForLoginAlloc(a, "E1001")) != null);
    try std.testing.expect((try store.findForLoginAlloc(a, "no-such-account")) == null);

    // 3) 登录：次数 +1 / 在线 / 最后登录信息，而且**真的写回库**
    const now = zzig.DateTime.nowLocal();
    const r = try mp.login(a, "admin", "pass123", now, "1.2.3.4");
    try std.testing.expectEqual(@as(i32, 1), r.user.Logins);
    try std.testing.expect(r.user.Online);
    try std.testing.expect(mp.isLoggedIn());

    const after_login = (try store.findByPkAlloc(a, created.ID)).?;
    try std.testing.expectEqual(@as(i32, 1), after_login.Logins);
    try std.testing.expect(after_login.Online);
    try std.testing.expectEqualStrings("1.2.3.4", after_login.LastLoginIP);

    // 4) 密码错 / 账号不存在 → 统一文案的错误
    try std.testing.expectError(error.BadPassword, mp.login(a, "admin", "wrong", now, ""));
    try std.testing.expectError(error.UserNotFound, mp.login(a, "ghost", "x", now, ""));
}

test "OrmStore：改密（旧密码校验 + 只写 Password 一列）与退出落库" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const old_setting = zcode.setting.snapshot();
    defer zcode.setting.restore(old_setting);

    var env = try Env.open(gpa);
    defer env.deinit();
    try schemaReady(&env);

    var store = provider.OrmStore.init(&env.dal);
    var mp = provider.ManageProvider{};
    mp.bindStore(store.store());

    const created = try mp.register(a, "admin", "pass123", 1, true);
    const now = zzig.DateTime.nowLocal();

    // 旧密码错 → BadPassword，且库里的散列不变
    const before = (try store.findByPkAlloc(a, created.ID)).?.Password;
    try std.testing.expectError(error.BadPassword, mp.changePassword(a, "admin", "newpw", "wrong-old"));
    try std.testing.expectEqualStrings(before, (try store.findByPkAlloc(a, created.ID)).?.Password);

    // 改密成功 → 新密码可登、旧密码失效
    _ = try mp.changePassword(a, "admin", "newpw", "pass123");
    try std.testing.expectError(error.BadPassword, mp.login(a, "admin", "pass123", now, ""));
    const ok = try mp.login(a, "admin", "newpw", now, "10.0.0.1");
    try std.testing.expect(ok.user.Online);

    // 退出 → Online 落库为 false（C# `Logout` 同口径）
    try mp.logoutPersist();
    try std.testing.expect(!mp.isLoggedIn());
    try std.testing.expect(!(try store.findByPkAlloc(a, created.ID)).?.Online);
}

test "OrmStore：库密码为空 → 任意密码可登，并把散列**写回库**（脏位图回归）" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const old_setting = zcode.setting.snapshot();
    defer zcode.setting.restore(old_setting);

    var env = try Env.open(gpa);
    defer env.deinit();
    try schemaReady(&env);

    var store = provider.OrmStore.init(&env.dal);
    var mp = provider.ManageProvider{};
    mp.bindStore(store.store());

    // 直接落一个空口令用户（对应 C# 里历史数据/第三方导入）
    var blank = User{};
    blank.setName("nopass");
    blank.setEnable(true);
    const id = try store.saveUser(&blank);
    try std.testing.expect(id > 0);
    try std.testing.expectEqualStrings("", (try store.findByPkAlloc(a, @intCast(id))).?.Password);

    const now = zzig.DateTime.nowLocal();
    const r = try mp.login(a, "nopass", "whatever", now, "");
    try std.testing.expect(r.wrote_password);

    // 关键：必须真的写回库（`loginCore` 走 setter 置脏，`entity.update` 才写这一列）
    const from_db = (try store.findByPkAlloc(a, @intCast(id))).?;
    try std.testing.expect(std.mem.startsWith(u8, from_db.Password, "$md5+sha1$"));
    // 重新登录用同一密码应该走正常校验分支
    const again = try mp.login(a, "nopass", "whatever", now, "");
    try std.testing.expect(!again.wrote_password);
}

test "OrmStore：老格式裸 MD5 登录后自动升级为 md5+sha1 并落库" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const old_setting = zcode.setting.snapshot();
    defer zcode.setting.restore(old_setting);

    var env = try Env.open(gpa);
    defer env.deinit();
    try schemaReady(&env);

    var store = provider.OrmStore.init(&env.dal);
    var mp = provider.ManageProvider{};
    mp.bindStore(store.store());

    var legacy = User{};
    legacy.setName("legacy");
    legacy.setEnable(true);
    var md5buf: [32]u8 = undefined;
    zcode.membership.password.md5HexLower(&md5buf, "oldpw");
    legacy.setPassword(&md5buf);
    const id = try store.saveUser(&legacy);

    const now = zzig.DateTime.nowLocal();
    const r = try mp.login(a, "legacy", "oldpw", now, "");
    try std.testing.expect(r.upgraded);

    const from_db = (try store.findByPkAlloc(a, @intCast(id))).?;
    try std.testing.expect(std.mem.startsWith(u8, from_db.Password, "$md5+sha1$"));
    // 升级后仍能用同一密码登录（不再触发升级）
    const again = try mp.login(a, "legacy", "oldpw", now, "");
    try std.testing.expect(!again.upgraded);
}

test "ManageProvider：未绑定 store 时明确报 StoreNotBound（不假装成功）" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var mp = provider.ManageProvider{};
    const now = zzig.DateTime.nowLocal();
    try std.testing.expectError(error.StoreNotBound, mp.login(a, "admin", "x", now, ""));
    try std.testing.expectError(error.StoreNotBound, mp.register(a, "admin", "x", 0, false));
    try std.testing.expectError(error.StoreNotBound, mp.changePassword(a, "admin", "x", "y"));
    // 未登录时 `logoutPersist` 是空操作（C# `Logout` 同口径，不因为没绑 store 就报错）
    try mp.logoutPersist();
}
