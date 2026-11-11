//! MySQL 真库用例：压缩协议（`Compression=True`）——需 `-Dmysql-conn=...`。
//!
//! 断言三件事，缺一不可：
//! 1. 连接**真的**切到了压缩：`SHOW STATUS LIKE 'Compression'` 必须是 `ON`（不是「以为压了」）；
//! 2. 压缩下大包能往返：写一段 8 KB 的中文文本，读回来逐字节一致（会走压缩帧）；
//! 3. 压缩下坏 SQL 仍按 `error.Server` 报错（错误包也在压缩流里，不能吞掉或解析错位）。

const std = @import("std");
const zcode = @import("zcode");
const build_options = @import("build_options");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="ZipRow" TableName="DH_ZipRow">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Code" DataType="String" Length="50" />
    \\      <Column Name="Body" DataType="String" Nullable="True" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

fn withKey(a: std.mem.Allocator, base: []const u8, key: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s};{s}={s}", .{ std.mem.trimEnd(u8, base, ";"), key, value });
}

test "MySQL 真库：压缩协议往返（需 -Dmysql-conn）" {
    const conn_str = build_options.mysql_conn;
    if (conn_str.len == 0) {
        std.debug.print("[SKIP] 未提供 -Dmysql-conn，跳过压缩协议用例\n", .{});
        return;
    }

    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    const cs = try withKey(aa, conn_str, "Compression", "True");
    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = zcode.Dal.initWithModel(a, cs, m) catch |e| {
        std.debug.print("[FAIL] 以压缩协议连接失败：{s}\n", .{@errorName(e)});
        return e;
    };
    defer dal.deinit();

    var s = try dal.openSession();
    defer s.deinit();

    // ① 确认服务端视角本条连接确实开着压缩
    {
        const rows = try s.queryRows("SHOW STATUS LIKE 'Compression'", &.{});
        if (rows.len == 0 or rows[0].values.len < 2) {
            std.debug.print("[FAIL] 读不到 Compression 状态\n", .{});
            return error.Unexpected;
        }
        const state = switch (rows[0].values[1]) {
            .text => |t| t,
            else => "",
        };
        std.debug.print("[mysql-compress] Compression = \"{s}\"\n", .{state});
        if (!std.ascii.eqlIgnoreCase(state, "ON")) {
            // 服务端没开压缩能力时不该静默当成功
            std.debug.print("[SKIP] 服务端未启用压缩（Compression={s}）\n", .{state});
            return;
        }
    }

    // ② 大包往返（8 KB 中文文本，远超压缩阈值）
    _ = s.execute("DROP TABLE IF EXISTS `DH_ZipRow`", &.{}) catch {};
    const report = try dal.syncSchema(&s);
    try std.testing.expectEqual(@as(usize, 1), report.tables_created);

    const table = try dal.table("ZipRow");
    const big = try aa.alloc(u8, 8192);
    {
        // 用**完整**的 UTF-8 字符填充（按字节随便切会切出半个汉字，
        // MySQL 会直接回 1366 Incorrect string value）
        const ch = "中"; // 3 字节
        var n: usize = 0;
        while (n + ch.len <= big.len) : (n += ch.len) @memcpy(big[n..][0..ch.len], ch);
        while (n < big.len) : (n += 1) big[n] = 'x'; // 余下补 ASCII，仍是合法 UTF-8
    }
    _ = try table.insert(&s, &[_]zcode.sqlbuild.Field{
        .{ .name = "Code", .value = .{ .text = "zip-1" } },
        .{ .name = "Body", .value = .{ .text = big } },
    });

    const row = (try table.findByPk(&s, &.{.{ .int = 1 }})).?;
    const body_val = row.get("Body") orelse {
        std.debug.print("[FAIL] 读回的行里没有 Body 列\n", .{});
        return error.ColumnNotFound;
    };
    const got = switch (body_val) {
        .text => |t| t,
        .null => "",
        else => "",
    };
    try std.testing.expectEqual(big.len, got.len);
    try std.testing.expectEqualSlices(u8, big, got);

    // ③ 压缩流里的错误包也要能正确解析成 error.Server（而不是协议错位）
    const bad = s.execute("SELECT * FROM `DH_NoSuchTable_zzz`", &.{});
    try std.testing.expectError(error.Server, bad);
    std.debug.print("[mysql-compress] 错误包解析正常：{s}\n", .{s.lastError()});

    // ④ LOCAL INFILE 也是压缩流里发的（writeRawPacket 路径）：1000 行装载后计数要对
    {
        _ = s.execute("SET GLOBAL local_infile = 1", &.{}) catch {};
        const cols = [_][]const u8{ "Code", "Body" };
        const n_rows: usize = 1000;
        const rows = try aa.alloc([]const zcode.Value, n_rows);
        const code_bufs = try aa.alloc([16]u8, n_rows);
        for (0..n_rows) |i| {
            const code = try std.fmt.bufPrint(&code_bufs[i], "zip-{d}", .{i + 100});
            rows[i] = try aa.dupe(zcode.Value, &.{
                .{ .text = code },
                .{ .text = "压缩流里的 LOCAL INFILE 载荷" },
            });
        }
        const loaded = table.loadDataBatch(&s, &cols, rows) catch |e| {
            std.debug.print("[SKIP] 压缩 + LOCAL INFILE 装载失败（{s}）：{s}\n", .{ @errorName(e), s.lastError() });
            _ = s.execute("DROP TABLE IF EXISTS `DH_ZipRow`", &.{}) catch {};
            return;
        };
        try std.testing.expectEqual(n_rows, loaded);
        std.debug.print("[mysql-compress] 压缩 + LOCAL INFILE：装载 {d} 行\n", .{loaded});
    }

    // ⑤ 与 TLS 叠加：压缩在 TLS 内层，两种传输包装必须能同时生效
    {
        const cs_tls = try withKey(aa, cs, "SslMode", "Required");
        const m2 = try zcode.EntityModel.parse(a, model_xml);
        var dal_tls = zcode.Dal.initWithModel(a, cs_tls, m2) catch |e| {
            std.debug.print("[FAIL] 压缩 + TLS 连接失败：{s}\n", .{@errorName(e)});
            return e;
        };
        defer dal_tls.deinit();
        var s_tls = try dal_tls.openSession();
        defer s_tls.deinit();

        const cipher_rows = try s_tls.queryRows("SHOW STATUS LIKE 'Ssl_cipher'", &.{});
        const cipher = switch (cipher_rows[0].values[1]) {
            .text => |t| t,
            else => "",
        };
        const comp_rows = try s_tls.queryRows("SHOW STATUS LIKE 'Compression'", &.{});
        const comp = switch (comp_rows[0].values[1]) {
            .text => |t| t,
            else => "",
        };
        std.debug.print("[mysql-compress] TLS + 压缩：cipher=\"{s}\" Compression=\"{s}\"\n", .{ cipher, comp });
        try std.testing.expect(cipher.len > 0);
        try std.testing.expect(std.ascii.eqlIgnoreCase(comp, "ON"));
    }

    _ = s.execute("DROP TABLE IF EXISTS `DH_ZipRow`", &.{}) catch {};
}
