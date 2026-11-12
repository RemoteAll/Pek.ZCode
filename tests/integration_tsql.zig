//! SQL Server 接线的集成用例：连接串解析 + 用**脚本化假 TDS 服务端**跑通
//! `Dal.syncSchema` 的建表链路（真 socket + 真 TDS 帧）。
//!
//! 本机没有 SQL Server 实例，所以协议层由 `zzig/src/db/tds.zig` 自带的回环用例覆盖；
//! 这里单独再起一个「更小」的假服务端，只为验证 **ZCode 侧接线**：
//! 连接串 → `Session` → `tableExists`/`indexExists` 探测 → `CREATE TABLE` / `CREATE INDEX`
//! 这些 SQL 确实按 SQL Server 方言发出去了，且返回的令牌流能被正确解析。

const std = @import("std");
const zcode = @import("zcode");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="Tsql" TableName="demo">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Name" DataType="String" Length="50" />
    \\    </Columns>
    \\    <Indexes><Index Columns="Name" /></Indexes>
    \\  </Table>
    \\</Tables></EntityModel>
;

// ── 假 TDS 服务端（只够回答表存在性探测 + 建表/建索引）───────────────────────

const Ctx = struct {
    io: std.Io,
    server: std.Io.net.Server,
    port: u16 = 0,
    ok: bool = false,
    /// 抓到的所有语句（UTF-8，按顺序）
    sql_log: [16][512]u8 = undefined,
    sql_len: [16]usize = [_]usize{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    sql_count: usize = 0,
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

    fn fail(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch "假服务端失败";
        self.err_len = text.len;
    }

    fn hasSql(self: *const Ctx, needle: []const u8) bool {
        for (0..self.sql_count) |i| {
            if (std.mem.indexOf(u8, self.sql_log[i][0..self.sql_len[i]], needle) != null) return true;
        }
        return false;
    }
};

fn serverMain(ctx: *Ctx) void {
    runServer(ctx) catch |e| {
        if (ctx.err_len == 0) ctx.fail("假服务端异常：{s}", .{@errorName(e)});
        return;
    };
    ctx.ok = true;
}

fn readExact(stream: std.Io.net.Stream, io: std.Io, dst: []u8) !void {
    var got: usize = 0;
    while (got < dst.len) {
        var slices = [_][]u8{dst[got..]};
        const r = io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &slices } }) catch return error.ReadFailed;
        const res = r.net_read catch return error.ReadFailed;
        if (res.data_len == 0) return error.ConnectionClosed;
        got += res.data_len;
    }
}

fn writeAll(stream: std.Io.net.Stream, io: std.Io, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        var slices = [_][]const u8{bytes[sent..]};
        const r = try io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &slices } });
        const n = try r.net_write;
        if (n == 0) return error.WriteFailed;
        sent += n;
    }
}

const Msg = struct { type: u8, len: usize };

fn readMessage(stream: std.Io.net.Stream, io: std.Io, buf: []u8) !Msg {
    var total: usize = 0;
    var msg_type: u8 = 0;
    while (true) {
        var hdr: [8]u8 = undefined;
        try readExact(stream, io, &hdr);
        const len = std.mem.readInt(u16, hdr[2..4], .big);
        if (len < 8 or total + (len - 8) > buf.len) return error.Protocol;
        msg_type = hdr[0];
        const body = @as(usize, len) - 8;
        if (body > 0) try readExact(stream, io, buf[total..][0..body]);
        total += body;
        if ((hdr[1] & 0x01) != 0) break;
    }
    return .{ .type = msg_type, .len = total };
}

fn writeMessage(stream: std.Io.net.Stream, io: std.Io, pkt_type: u8, payload: []const u8) !void {
    var hdr: [8]u8 = undefined;
    hdr[0] = pkt_type;
    hdr[1] = 0x01;
    std.mem.writeInt(u16, hdr[2..4], @intCast(8 + payload.len), .big);
    std.mem.writeInt(u16, hdr[4..6], 0, .big);
    hdr[6] = 1;
    hdr[7] = 0;
    try writeAll(stream, io, &hdr);
    if (payload.len > 0) try writeAll(stream, io, payload);
}

const Out = struct {
    list: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    fn deinit(self: *Out) void {
        self.list.deinit(self.a);
    }
    fn u8v(self: *Out, v: u8) !void {
        try self.list.append(self.a, v);
    }
    fn u16v(self: *Out, v: u16) !void {
        try self.u8v(@truncate(v));
        try self.u8v(@truncate(v >> 8));
    }
    fn u64v(self: *Out, v: u64) !void {
        var i: usize = 0;
        while (i < 8) : (i += 1) try self.u8v(@truncate((v >> @intCast(i * 8)) & 0xFF));
    }
    fn bytes(self: *Out, b: []const u8) !void {
        try self.list.appendSlice(self.a, b);
    }
    fn bVarChar(self: *Out, text: []const u8) !void {
        const units = try std.unicode.utf8ToUtf16LeAlloc(self.a, text);
        defer self.a.free(units);
        try self.u8v(@intCast(units.len));
        for (units) |u| try self.u16v(u);
    }
};

/// 一列（INTN）的 COLMETADATA + 空结果集 + DONE
fn writeEmptySingleColumn(o: *Out) !void {
    try o.u8v(0x81); // COLMETADATA
    try o.u16v(1);
    try o.u16v(0); // UserType（低 2 字节）——客户端按 u32 读，下面再补 2 字节
    try o.u16v(0);
    try o.u16v(0); // Flags
    try o.bytes(&[_]u8{ 0x26, 0x04 }); // INTN(4)
    try o.bVarChar("");
    try writeDone(o, 0x10, 0);
}

fn writeDone(o: *Out, status: u16, row_count: u64) !void {
    try o.u8v(0xFD);
    try o.u16v(status);
    try o.u16v(0);
    try o.u64v(row_count);
}

fn utf16ToBuf(dst: []u8, raw: []const u8) !usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 2) {
        const u = std.mem.readInt(u16, raw[i..][0..2], .little);
        if (u < 0x80) {
            if (out + 1 > dst.len) return error.NoSpace;
            dst[out] = @intCast(u);
            out += 1;
        } else if (u < 0x800) {
            if (out + 2 > dst.len) return error.NoSpace;
            dst[out] = @intCast(0xC0 | (u >> 6));
            dst[out + 1] = @intCast(0x80 | (u & 0x3F));
            out += 2;
        } else {
            if (out + 3 > dst.len) return error.NoSpace;
            dst[out] = @intCast(0xE0 | (u >> 12));
            dst[out + 1] = @intCast(0x80 | ((u >> 6) & 0x3F));
            dst[out + 2] = @intCast(0x80 | (u & 0x3F));
            out += 3;
        }
    }
    return out;
}

/// 从 RPC（sp_executesql）载荷里取出 `@stmt` 文本。
fn readRpcStmt(dst: []u8, payload: []const u8) !usize {
    if (payload.len < 8) return error.Protocol;
    var pos: usize = 4; // AllHeaders
    pos += 2; // ProcID
    pos += 2; // OptionFlags
    const name_len = payload[pos];
    pos += 1 + @as(usize, name_len) * 2;
    pos += 1; // Status
    if (payload[pos] != 0xE7) return error.Protocol; // NVARCHAR
    pos += 1;
    const max_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
    pos += 2;
    if (max_len != 0xFFFF) return error.Protocol;
    pos += 5; // collation
    const total = std.mem.readInt(u64, payload[pos..][0..8], .little);
    pos += 8;
    if (total == 0xFFFF_FFFF_FFFF_FFFF) return 0;
    const chunk_len = std.mem.readInt(u32, payload[pos..][0..4], .little);
    pos += 4;
    if (pos + chunk_len > payload.len) return error.Protocol;
    return utf16ToBuf(dst, payload[pos..][0..chunk_len]);
}

fn runServer(ctx: *Ctx) !void {
    var stream = try ctx.server.accept(ctx.io);
    defer stream.close(ctx.io);
    const io = ctx.io;

    var buf: [8192]u8 = undefined;

    // PRELOGIN
    const pre = try readMessage(stream, io, &buf);
    if (pre.type != 0x12) {
        ctx.fail("期望 PRELOGIN，收到 0x{X:0>2}", .{pre.type});
        return error.Protocol;
    }
    {
        var o = Out{ .a = std.heap.page_allocator };
        defer o.deinit();
        const table_len = 2 * 5 + 1;
        try o.bytes(&[_]u8{ 0x00, 0, table_len, 0, 6 });
        try o.bytes(&[_]u8{ 0x01, 0, table_len + 6, 0, 1 });
        try o.u8v(0xFF);
        try o.bytes(&[_]u8{ 0, 0, 0, 0, 0, 0 });
        try o.u8v(0); // ENCRYPTION = OFF
        try writeMessage(stream, io, 0x04, o.list.items);
    }

    // LOGIN7 → LOGINACK + DONE
    const login = try readMessage(stream, io, &buf);
    if (login.type != 0x10) {
        ctx.fail("期望 LOGIN7，收到 0x{X:0>2}", .{login.type});
        return error.Protocol;
    }
    {
        var o = Out{ .a = std.heap.page_allocator };
        defer o.deinit();
        try o.u8v(0xAD);
        const len_slot = o.list.items.len;
        try o.u16v(0);
        const start = o.list.items.len;
        try o.u8v(1);
        try o.bytes(&[_]u8{ 0x74, 0x00, 0x00, 0x04 });
        try o.bVarChar("Microsoft SQL Server");
        try o.bytes(&[_]u8{ 15, 0, 0x07, 0xD0 });
        const len: u16 = @intCast(o.list.items.len - start);
        std.mem.writeInt(u16, o.list.items[len_slot..][0..2], len, .little);
        try writeDone(&o, 0x00, 0);
        try writeMessage(stream, io, 0x04, o.list.items);
    }

    // 命令循环
    while (true) {
        const msg = readMessage(stream, io, &buf) catch |e| switch (e) {
            error.ConnectionClosed, error.ReadFailed => return,
            else => return e,
        };
        var sql_buf: [512]u8 = undefined;
        var sql_len: usize = 0;
        if (msg.type == 0x01) {
            // SQL 批处理：载荷就是 UTF-16LE 文本
            sql_len = try utf16ToBuf(&sql_buf, buf[0..msg.len]);
        } else if (msg.type == 0x03) {
            // RPC（带参）：`@stmt` 是第一个参数
            sql_len = readRpcStmt(&sql_buf, buf[0..msg.len]) catch 0;
        } else {
            ctx.fail("未预期的包类型 0x{X:0>2}", .{msg.type});
            return error.Protocol;
        }
        if (ctx.sql_count < ctx.sql_log.len) {
            const i = ctx.sql_count;
            @memcpy(ctx.sql_log[i][0..sql_len], sql_buf[0..sql_len]);
            ctx.sql_len[i] = sql_len;
            ctx.sql_count += 1;
        }

        var o = Out{ .a = std.heap.page_allocator };
        defer o.deinit();
        if (std.mem.startsWith(u8, sql_buf[0..sql_len], "SELECT TOP 1 1 FROM information_schema.tables") or
            std.mem.startsWith(u8, sql_buf[0..sql_len], "SELECT TOP 1 1 FROM sys.indexes"))
        {
            // 表 / 索引都不存在 → 空结果集
            try writeEmptySingleColumn(&o);
        } else {
            // 建表 / 建索引等 DDL：只回 DONE
            try writeDone(&o, 0x00, 0);
        }
        try writeMessage(stream, io, 0x04, o.list.items);
    }
}

test "SQL Server：连接串键名与端口回落" {
    const a = std.testing.allocator;

    var opts = try zcode.parseConnectionString(
        a,
        "Provider=SqlServer;Server=127.0.0.1;Port=1444;Database=demo;User ID=sa;Password=P@ss",
    );
    defer opts.deinit(a);

    try std.testing.expectEqual(zcode.DatabaseKind.sqlserver, opts.provider);
    try std.testing.expectEqual(@as(u16, 1444), opts.port);
    try std.testing.expectEqualStrings("sa", opts.user);
    try std.testing.expectEqualStrings("demo", opts.database);

    const m = try zcode.EntityModel.parse(a, model_xml);
    var dal = try zcode.Dal.initWithModel(a, "Provider=SqlServer;Server=127.0.0.1;Database=demo;User ID=sa;Password=x", m);
    defer dal.deinit();
    // 端口回落到 SQL Server 的 1433（不能沿用 MySQL 的 3306）
    try std.testing.expectEqual(@as(u16, 1433), dal.opts.port);
    try std.testing.expect(dal.supportsPooling());

    const m2 = try zcode.EntityModel.parse(a, model_xml);
    try std.testing.expectError(
        error.NoDatabase,
        zcode.Dal.initWithModel(a, "Provider=SqlServer;Server=127.0.0.1;User ID=sa;Password=x", m2),
    );
}

test "SQL Server：syncSchema 走真实 TDS 帧建表（假服务端）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var ctx = Ctx{ .io = sio, .server = undefined };
    var port: u16 = 14400;
    var listening = false;
    while (port < 14420) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        ctx.server = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        ctx.port = port;
        listening = true;
        break;
    }
    if (!listening) {
        std.debug.print("[SKIP] 14400-14419 端口均不可用，跳过 SQL Server 接线用例\n", .{});
        return;
    }
    const th = try std.Thread.spawn(.{}, serverMain, .{&ctx});
    var joined = false;
    // 兜底：**不能在 accept 阻塞时直接 deinit 监听** —— std 会走 `.CANCELLED => unreachable`
    // 直接 panic（dbservice 那轮踩过的同一个坑）。这里先自连一次唤醒 accept，再 join。
    defer {
        if (!joined) {
            if (std.Io.net.IpAddress.resolve(sio, "127.0.0.1", ctx.port)) |addr| {
                if (std.Io.net.IpAddress.connect(&addr, sio, .{ .mode = .stream, .protocol = .tcp })) |st| {
                    var tmp = st;
                    tmp.close(sio);
                } else |_| {}
            } else |_| {}
            th.join();
        }
        ctx.server.deinit(sio);
    }

    const a = std.testing.allocator;
    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(
        a,
        "Provider=SqlServer;Server=127.0.0.1;Port={d};Database=demo;User ID=sa;Password=P@ssw0rd",
        .{ctx.port},
    );
    defer a.free(conn);

    var dal = zcode.Dal.initWithModel(a, conn, m) catch |e| {
        std.debug.print("[FAIL] initWithModel 失败：{s}\n", .{@errorName(e)});
        return e;
    };
    defer dal.deinit();
    var s = dal.openSession() catch |e| {
        std.debug.print("[FAIL] openSession 失败：{s}\n", .{@errorName(e)});
        return e;
    };

    const report = try dal.syncSchema(&s);
    if (report.tables_created != 1 or report.indexes_created != 1) {
        std.debug.print(
            "[FAIL] 建表报告不符：建表 {d} / 建索引 {d} / 捕获语句 {d} 条\n",
            .{ report.tables_created, report.indexes_created, ctx.sql_count },
        );
        for (0..ctx.sql_count) |i| std.debug.print("  [{d}] {s}\n", .{ i, ctx.sql_log[i][0..ctx.sql_len[i]] });
    }
    try std.testing.expectEqual(@as(usize, 1), report.tables_created);
    try std.testing.expectEqual(@as(usize, 1), report.indexes_created);

    // SQL Server 方言：`[x]` 引用符 + `IDENTITY(1,1)`
    try std.testing.expect(ctx.hasSql("CREATE TABLE [demo]"));
    try std.testing.expect(ctx.hasSql("IDENTITY(1,1)"));
    try std.testing.expect(ctx.hasSql("CREATE INDEX [ix_demo_Name] ON [demo]"));
    // 探测语句用 TOP 1（不是 LIMIT）
    try std.testing.expect(ctx.hasSql("SELECT TOP 1 1 FROM information_schema.tables"));

    // 先关会话（关 socket）再 join，否则假服务端会一直阻塞在读下一帧
    s.deinit();
    joined = true;
    th.join();
    if (!ctx.ok) {
        std.debug.print("[FAIL] 假 TDS 服务端未正常结束：{s}\n", .{ctx.err_buf[0..ctx.err_len]});
        return error.TestServerFailed;
    }
}
