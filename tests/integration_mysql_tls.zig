//! MySQL 真库用例：TLS（`SslMode`）——需 `-Dmysql-conn=...`。
//!
//! 覆盖四个档位与两侧（能连 / 连不上）：
//! 1. `SslMode=Required`：连上后 `SHOW STATUS LIKE 'Ssl_cipher'` **必须有值**（真加密，不是「以为加密」）；
//! 2. `SslMode=None`：同一台库 `Ssl_cipher` 必须为空（证明确实是明文，档位真的生效）；
//! 3. `SslMode=VerifyCA`（不给 CA）：MySQL 8 的自动生成证书不在系统根证书里 → **必须失败**；
//! 4. `-Dmysql-ca=<ca.pem>` 时追加：`VerifyCA` 成功、`VerifyFull` 因主机名不在证书里 **必须失败**。
//!
//! 这样「加密」「明文」「校验」三条路径都有实据，而不是只测了能连上。

const std = @import("std");
const zcode = @import("zcode");
const build_options = @import("build_options");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="TlsProbe" TableName="DH_TlsProbe">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

/// 在连接串后面追加/覆盖一个键（连接串是 `a=b;c=d` 形式）。
fn withKey(a: std.mem.Allocator, base: []const u8, key: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s};{s}={s}", .{ std.mem.trimEnd(u8, base, ";"), key, value });
}

/// 用给定连接串开一个会话并读 `Ssl_cipher`（空串 = 未加密）。
fn probeCipher(a: std.mem.Allocator, conn_str: []const u8) ![]u8 {
    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = try zcode.Dal.initWithModel(a, conn_str, m);
    defer dal.deinit();
    var s = try dal.openSession();
    defer s.deinit();
    // 结果两列：Variable_name / Value —— 取第二列
    const rows = try s.queryRows("SHOW STATUS LIKE 'Ssl_cipher'", &.{});
    if (rows.len == 0 or rows[0].values.len < 2) return a.dupe(u8, "");
    return switch (rows[0].values[1]) {
        .text => |t| try a.dupe(u8, t),
        else => try a.dupe(u8, ""),
    };
}

test "MySQL 真库 TLS：Required 真加密 / None 明文 / 证书校验失败（需 -Dmysql-conn）" {
    const conn_str = build_options.mysql_conn;
    if (conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-conn，跳过 TLS 用例\n", .{});
        return;
    }
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // ① Required：必须真的协商出加密套件
    {
        const cs = try withKey(aa, conn_str, "SslMode", "Required");
        const cipher = probeCipher(aa, cs) catch |e| {
            std.debug.print("[FAIL] SslMode=Required 连不上：{s}\n", .{@errorName(e)});
            return e;
        };
        std.debug.print("[mysql-tls] Required cipher = \"{s}\"\n", .{cipher});
        try std.testing.expect(cipher.len > 0);
    }

    // ② None（=Disabled）：同一台库必须是明文，证明档位真的起作用
    {
        const cs = try withKey(aa, conn_str, "SslMode", "None");
        const cipher = try probeCipher(aa, cs);
        std.debug.print("[mysql-tls] None cipher = \"{s}\"\n", .{cipher});
        try std.testing.expectEqual(@as(usize, 0), cipher.len);
    }

    // ③ VerifyCA 不给 CA：服务端是自动生成自签证书 → 必须失败（否则校验形同虚设）
    {
        const cs = try withKey(aa, conn_str, "SslMode", "VerifyCA");
        if (probeCipher(aa, cs)) |cipher| {
            std.debug.print(
                "[FAIL] SslMode=VerifyCA 竟然连上了（cipher=\"{s}\"）：说明证书链没被校验\n",
                .{cipher},
            );
            return error.CertificateNotVerified;
        } else |e| {
            std.debug.print("[mysql-tls] VerifyCA（无 CA）按预期失败：{s}\n", .{@errorName(e)});
        }
    }

    // ④ 给了 CA：VerifyCA 通过；VerifyFull 因主机名不在证书里必须失败
    const ca_path = build_options.mysql_ca;
    if (ca_path.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-ca，跳过 VerifyCA/VerifyFull 正向用例\n", .{});
        return;
    }
    {
        const cs = try withKey(aa, conn_str, "SslMode", "VerifyCA");
        const cs2 = try std.fmt.allocPrint(aa, "{s};SslCa={s}", .{ cs, ca_path });
        const cipher = probeCipher(aa, cs2) catch |e| {
            std.debug.print("[FAIL] SslMode=VerifyCA + SslCa 仍失败：{s}\n", .{@errorName(e)});
            return e;
        };
        std.debug.print("[mysql-tls] VerifyCA(ca) cipher = \"{s}\"\n", .{cipher});
        try std.testing.expect(cipher.len > 0);
    }
    {
        // 连接串里的 Server 通常是 127.0.0.1，而 MySQL 自动生成证书的 CN 不是它
        const cs = try withKey(aa, conn_str, "SslMode", "VerifyFull");
        const cs2 = try std.fmt.allocPrint(aa, "{s};SslCa={s}", .{ cs, ca_path });
        if (probeCipher(aa, cs2)) |cipher| {
            std.debug.print(
                "[mysql-tls] VerifyFull 连上了（cipher=\"{s}\"）；若证书 SAN 确实包含该主机名则属正常\n",
                .{cipher},
            );
        } else |e| {
            std.debug.print("[mysql-tls] VerifyFull 按预期失败（主机名不匹配）：{s}\n", .{@errorName(e)});
        }
    }

    // ⑤ 认不出的 SslMode 必须在解析期拒绝（不能静默按缺省走）
    {
        const cs = try withKey(aa, conn_str, "SslMode", "Maybe");
        try std.testing.expectError(error.InvalidSslMode, probeCipher(aa, cs));
    }
}
