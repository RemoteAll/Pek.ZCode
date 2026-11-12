//! 口令散列（对应 C# `NewLife.Security.SaltPasswordProvider`，本子系统固定 `md5+sha1` 档）。
//!
//! **必须与 C# 字节级互通**——同一份库、同一套账号，C# 写的口令 Zig 要认，反之亦然。
//! 算法逐字照抄 `DH.NCore/Security/IPasswordProvider.cs`：
//!
//! ```text
//! salt = 16 个字符，取自 "a-zA-Z0-9./"
//! hash = Base64( HMAC-SHA1( key = UTF8(salt), msg = MD5(UTF8(password)) ) )
//! 存储 = "$md5+sha1$" + salt + "$" + hash
//! ```
//!
//! 关键细节（源码依据）：
//! - `SaltPasswordProvider.Hash` 对 `md5+sha1` 走 `password.GetBytes().MD5().SHA1(salt.GetBytes())`，
//!   而 `SecurityHelper.SHA1(data, key)` 带 key 时是 **HMACSHA1(key).ComputeHash(data)**（`SecurityHelper.cs:87`），
//!   即 **HMAC-SHA1，key 是盐、消息是 MD5 的 16 字节**（不是"MD5 的 hex 文本"，也不是"MD5 再拼盐"）。
//! - `String.MD5()` 输出 **32 位大写 hex**（`IOHelper.cs:1094` 的 `GetHexValue` 用 `'A'`），
//!   所以写入"裸 MD5"（`User.Add` 场景）时用大写；比较一律忽略大小写。
//! - `ToHex(String)` 是 **hex → 字节**（`IOHelper.cs:1101`），因此 `md5+sha1` 的第三个校验分支
//!   是把传输来的 32 位 MD5 文本解成 16 字节再 HMAC。
//!
//! 口令传输口径（用户级指令）：前端先 `md5(明文)` 再提交，后端**同时接受明文与 MD5**；
//! 设置/改密接口收明文，由服务端 `hash` 入库。

const std = @import("std");
const zzig = @import("zzig");

/// 本子系统固定使用的算法档（对齐 C# 共库口径 `md5+sha1`）。
///
/// C# `SaltPasswordProvider.Algorithm` 默认是 `sha512`，但 `sha1` / `sha512` 两档**只认明文**，
/// 一选就丢掉「前端 MD5 传输」能力；共库项目必须显式切到 `md5+sha1`。
pub const algorithm = "md5+sha1";

/// 盐字符表（与 C# 的 `_cs` 完全一致）。
const salt_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./";

/// 盐长度（C# `CreateSalt` 固定 16）。
pub const salt_len = 16;

/// 32 位大写 hex 的 MD5（`String.MD5()` 口径；用于"裸 MD5"入库与前端传输值）。
pub fn md5HexUpper(buf: *[32]u8, text: []const u8) void {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(text, &digest, .{});
    const upper = "0123456789ABCDEF";
    for (digest, 0..) |b, i| {
        buf[i * 2] = upper[b >> 4];
        buf[i * 2 + 1] = upper[b & 0x0F];
    }
}

/// 32 位小写 hex 的 MD5（浏览器 `md5(明文)` 的常见输出；比较时与大小写无关）。
pub fn md5HexLower(buf: *[32]u8, text: []const u8) void {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(text, &digest, .{});
    const lower = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        buf[i * 2] = lower[b >> 4];
        buf[i * 2 + 1] = lower[b & 0x0F];
    }
}

/// 生成 16 字符随机盐（写进 `allocated`）。
pub fn makeSalt(allocated: *[salt_len]u8) void {
    const io_source = std.Random.IoSource{ .io = std.Io.Threaded.global_single_threaded.io() };
    const rand = io_source.interface();
    for (allocated) |*c| {
        // `uintLessThan` 避免取模偏差（与 zzig.Randoms 同口径）
        c.* = salt_chars[rand.uintLessThan(usize, salt_chars.len)];
    }
}

/// 用指定盐算出 `md5+sha1` 的 Base64 摘要（`out` 为 28 字符）。
pub fn digestWithSalt(out: *[28]u8, password: []const u8, salt: []const u8) void {
    var md5_bytes: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(password, &md5_bytes, .{});

    var mac: [20]u8 = undefined;
    std.crypto.auth.hmac.HmacSha1.create(&mac, &md5_bytes, salt);

    _ = std.base64.standard.Encoder.encode(out, &mac);
}

/// 口令散列，返回 `"$md5+sha1$<salt>$<base64>"`（调用方负责释放）。
pub fn hashAlloc(a: std.mem.Allocator, password: []const u8) ![]u8 {
    var salt: [salt_len]u8 = undefined;
    makeSalt(&salt);
    return hashWithSaltAlloc(a, password, &salt);
}

/// 指定盐的口令散列（迁移/对拍测试用；正常登录流程用 `hashAlloc`）。
pub fn hashWithSaltAlloc(a: std.mem.Allocator, password: []const u8, salt: []const u8) ![]u8 {
    var digest: [28]u8 = undefined;
    digestWithSalt(&digest, password, salt);
    return std.fmt.allocPrint(a, "${s}${s}${s}", .{ algorithm, salt, digest });
}

/// 常量时间字节比较（避免按字符提前返回泄露长度/前缀信息）。
fn eqlConstantTime(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= (x ^ y);
    return diff == 0;
}

/// 忽略大小写的等值比较（hex 文本用；内部走常量时间比较）。
fn eqlIgnoreCaseConstantTime(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= (std.ascii.toLower(x) ^ std.ascii.toLower(y));
    return diff == 0;
}

/// 把 32 位 hex 文本解成 16 字节；输入不合法返回 null。
fn unhexMd5(text: []const u8) ?[16]u8 {
    var t: [32]u8 = undefined;
    if (text.len != 32) return null;
    @memcpy(&t, text);
    var out: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = std.fmt.charToDigit(t[i * 2], 16) catch return null;
        const lo = std.fmt.charToDigit(t[i * 2 + 1], 16) catch return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

/// 校验口令。`stored` 是库里的值，可能是：
/// - `"$md5+sha1$salt$base64"` —— 标准（本仓写入格式）
/// - `"$md5$..."` / `"$sha1$..."` / `"$sha512$..."` —— 其它档，这里**只认 md5 档**的两条分支
/// - 老式**裸 MD5**（32 位 hex）或明文 —— 与 `password` 的明文/大写小写 MD5 直接比
///
/// `password` 可以是明文，也可以是前端传来的 32 位 MD5 hex（第三个兼容分支）。
pub fn verify(password: []const u8, stored: []const u8) bool {
    if (stored.len == 0) return false;

    // 老式：没有 '$' → 明文或裸 MD5（C# `hash.EqualIgnoreCase(password, password.MD5())`）
    if (std.mem.indexOfScalar(u8, stored, '$') == null) {
        if (eqlIgnoreCaseConstantTime(stored, password)) return true;
        var upper: [32]u8 = undefined;
        md5HexUpper(&upper, password);
        if (eqlIgnoreCaseConstantTime(stored, &upper)) return true;
        // password 可能本身就是 MD5 hex，而库里也存 MD5 hex
        return eqlIgnoreCaseConstantTime(stored, password);
    }

    // `$alg$salt$hash`
    var it = std.mem.splitScalar(u8, stored, '$');
    _ = it.next(); // 开头的空段
    const alg = it.next() orelse return false;
    const salt = it.next() orelse return false;
    const want = it.next() orelse return false;
    if (it.next() != null) return false; // 段数必须正好 4

    if (std.ascii.eqlIgnoreCase(alg, "md5")) {
        // `md5` 档：库值 = MD5(MD5(明文)+盐) 或 MD5(传输值+盐)
        var pw_md5: [32]u8 = undefined;
        md5HexUpper(&pw_md5, password);
        var buf: [128]u8 = undefined;
        if (pw_md5.len + salt.len <= buf.len) {
            @memcpy(buf[0..pw_md5.len], &pw_md5);
            @memcpy(buf[pw_md5.len..][0..salt.len], salt);
            var got: [32]u8 = undefined;
            md5HexUpper(&got, buf[0 .. pw_md5.len + salt.len]);
            if (eqlIgnoreCaseConstantTime(want, &got)) return true;
        }
        if (password.len + salt.len <= buf.len) {
            @memcpy(buf[0..password.len], password);
            @memcpy(buf[password.len..][0..salt.len], salt);
            var got: [32]u8 = undefined;
            md5HexUpper(&got, buf[0 .. password.len + salt.len]);
            if (eqlIgnoreCaseConstantTime(want, &got)) return true;
        }
        return false;
    }

    if (std.ascii.eqlIgnoreCase(alg, algorithm)) {
        var digest: [28]u8 = undefined;

        // 分支 1（标准）：password 是明文
        digestWithSalt(&digest, password, salt);
        if (eqlConstantTime(want, &digest)) return true;

        // 分支 2（兼容 sha1 档）：password 直接 HMAC
        {
            var mac: [20]u8 = undefined;
            std.crypto.auth.hmac.HmacSha1.create(&mac, password, salt);
            var b64: [28]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&b64, &mac);
            if (eqlConstantTime(want, &b64)) return true;
        }

        // 分支 3（传输 MD5）：password 是 32 位 hex，先解成 16 字节再 HMAC
        if (unhexMd5(password)) |bytes| {
            var mac: [20]u8 = undefined;
            std.crypto.auth.hmac.HmacSha1.create(&mac, &bytes, salt);
            var b64: [28]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&b64, &mac);
            if (eqlConstantTime(want, &b64)) return true;
        }
        return false;
    }

    // `sha1` / `sha512` 档只认明文（不接前端 MD5），本仓不使用；显式拒绝而不是猜。
    return false;
}

/// 是否需要"登录成功后自动升级"：非 `$md5+sha1$` 格式（C# `LoginCore` 的旧格式判断 `!Password.Contains("$")`
/// 更宽松，这里按"目标格式"判断，连 `$md5$` / `$sha512$` 这类旧档也一并升级）。
pub fn needsUpgrade(stored: []const u8) bool {
    if (!std.mem.startsWith(u8, stored, "$")) return true;
    return !std.mem.startsWith(u8, stored, "$" ++ algorithm ++ "$");
}

test "md5+sha1：格式、盐长度、摘要可往返" {
    const a = std.testing.allocator;
    const hashed = try hashAlloc(a, "admin123");
    defer a.free(hashed);

    try std.testing.expect(std.mem.startsWith(u8, hashed, "$md5+sha1$"));
    try std.testing.expect(needsUpgrade(hashed) == false);

    // 段数 4：$md5+sha1$salt$hash
    var it = std.mem.splitScalar(u8, hashed, '$');
    _ = it.next();
    try std.testing.expectEqualStrings("md5+sha1", it.next().?);
    const salt = it.next().?;
    try std.testing.expectEqual(@as(usize, salt_len), salt.len);
    const digest = it.next().?;
    try std.testing.expectEqual(@as(usize, 28), digest.len); // 20 字节 → Base64 28 字符
    try std.testing.expect(it.next() == null);

    // 明文可验
    try std.testing.expect(verify("admin123", hashed));
    try std.testing.expect(!verify("admin124", hashed));
}

test "md5+sha1：兼容前端 MD5 传输（第三分支）" {
    const a = std.testing.allocator;
    const hashed = try hashAlloc(a, "P@ssw0rd");
    defer a.free(hashed);

    var lower: [32]u8 = undefined;
    md5HexLower(&lower, "P@ssw0rd");

    // 前端只传 MD5（小写），后端必须认
    try std.testing.expect(verify(&lower, hashed));

    // 错误的 MD5 不认
    var bad: [32]u8 = undefined;
    md5HexLower(&bad, "P@ssw0rX");
    try std.testing.expect(!verify(&bad, hashed));
}

test "老式裸 MD5：明文与 MD5 都能登、并标记需要升级" {
    const a = std.testing.allocator;
    var upper: [32]u8 = undefined;
    md5HexUpper(&upper, "admin");
    const stored = try a.dupe(u8, &upper);
    defer a.free(stored);

    try std.testing.expect(verify("admin", stored)); // 明文直接比 MD5
    try std.testing.expect(verify(&upper, stored)); // 传 MD5 也认
    try std.testing.expect(!verify("admiN", stored));
    try std.testing.expect(needsUpgrade(stored));
}

test "md5 档与未支持档" {
    const a = std.testing.allocator;
    var upper: [32]u8 = undefined;
    md5HexUpper(&upper, "123456");
    // $md5$salt$MD5(明文MD5+盐)
    var cat: [64]u8 = undefined;
    @memcpy(cat[0..32], &upper);
    @memcpy(cat[32..40], "abcdefgh");
    var want: [32]u8 = undefined;
    md5HexUpper(&want, cat[0..40]);
    const stored = try std.fmt.allocPrint(a, "$md5$abcdefgh${s}", .{want});
    defer a.free(stored);
    try std.testing.expect(verify("123456", stored));
    try std.testing.expect(needsUpgrade(stored));

    // sha512 档只认明文、本仓不实现 → 显式 false（不猜）
    try std.testing.expect(!verify("123456", "$sha512$abcdefgh$AAAA"));
}
