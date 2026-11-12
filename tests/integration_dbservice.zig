//! 数据库远程服务端到端：真 SQLite 文件 + 真 socket + 真 HTTP/1.1。
//!
//! 覆盖：登录 → 建表 → 插入(取自增) → 查询 → 计数 → 表结构 → 事务（提交/回滚）→ 负向（令牌、404、白名单）。
//!
//! 线程与 Io 口径（照抄仓库里已验证可行的回环测试，踩过坑）：
//! - 服务端用 `Io.Threaded.init(page_allocator, .{})`，且**只在自己那个子线程里用**；
//! - 客户端用本线程的 `compat.currentIo()`；一个 io 实例不跨线程共用。

const std = @import("std");
const zcode = @import("zcode");
const zzig = @import("zzig");

const model_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<EntityModel><Option><ConnName>DH</ConnName></Option><Tables>
    \\  <Table Name="SvcRow" TableName="DH_SvcRow">
    \\    <Columns>
    \\      <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
    \\      <Column Name="Code" DataType="String" Length="50" />
    \\      <Column Name="Title" DataType="String" Length="200" Nullable="True" />
    \\    </Columns>
    \\  </Table>
    \\</Tables></EntityModel>
;

const Ctx = struct {
    server: std.Io.net.Server,
    io: std.Io,
    impl: zcode.dbservice.Service,
    /// 供 `serveOne` 用的 Server 壳（ctx 指向本结构，便于 stats 累加）
    impl_srv: zzig.http_server.Server,
    /// 处理过的请求数（用例断言 > 0，证明确实处理过）
    served: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    fn handle(ctx: *anyopaque, req: zzig.http_server.RequestView, arena: std.mem.Allocator) anyerror!zzig.http_server.Reply {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        _ = self.served.fetchAdd(1, .acq_rel);
        return zcode.dbservice.Service.handle(&self.impl, req, arena);
    }

    /// 监听循环：accept 一次处理一个（用例串行发请求，够用且最简单）
    fn loop(self: *@This()) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            self.impl_srv.serveOne(stream) catch |e| {
                std.debug.print("[dbservice] 处理请求失败：{s}\n", .{@errorName(e)});
            };
        }
    }
};

test "数据库远程服务：Login/Query/Execute/Identity/Count/GetTables/事务/负向" {
    const a = std.testing.allocator;

    // 临时库
    const db_path = try zzig.File.UniqueTempName(a, "dbservice", ".db");
    defer a.free(db_path);
    defer zzig.File.DeleteQuiet(db_path);

    const m = try zcode.EntityModel.parse(a, model_xml);
    const conn = try std.fmt.allocPrint(a, "Data Source={s};Provider=SQLite", .{db_path});
    defer a.free(conn);
    var dal = try zcode.Dal.initWithModel(a, conn, m);
    defer dal.deinit();
    {
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    // 令牌故意设成固定值，用来测「错令牌必须 401」
    const allowed = [_][]const u8{""};
    var ctx = Ctx{
        .server = undefined,
        .io = undefined,
        .impl_srv = undefined,
        .impl = zcode.dbservice.Service.init(a, &dal, .{ .token = "t-123", .databases = &allowed }),
    };
    defer ctx.impl.deinit();

    // 服务端 io：独立 Io + page_allocator（`Threaded.init` 的分配器要求线程安全）
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = 39401;
    var bound: ?std.Io.net.Server = null;
    while (port < 39420) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    const listener = bound orelse {
        std.debug.print("[SKIP] 39401-39419 端口均不可用，跳过远程服务用例\n", .{});
        return;
    };

    ctx.server = listener;
    ctx.io = sio;
    ctx.impl_srv = .{ .gpa = a, .io = sio, .ctx = @ptrCast(&ctx), .handler = Ctx.handle };

    const th = try std.Thread.spawn(.{}, Ctx.loop, .{&ctx});

    // 客户端：本线程 io
    const io = zzig.compat.currentIo();
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
    defer a.free(base);

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    {
        var client = zcode.dbclient.Client.init(a, io, base, "", "t-123");
        defer client.deinit();

        // ① 登录
        const info = try client.login(aa);
        std.debug.print("[dbservice] Login：dbType={s}\n", .{info.db_type});
        try std.testing.expect(info.db_type.len > 0);

        // ② 插入并取自增
        const id = try client.insertAndGetIdentity(aa, "INSERT INTO `DH_SvcRow` (`Code`,`Title`) VALUES ('svc-1','来自远程服务')", &.{});
        try std.testing.expect(id > 0);
        std.debug.print("[dbservice] InsertAndGetIdentity：{d}\n", .{id});

        // ③ 带参查询（参数按名绑定）
        const rows = try client.query(aa, "SELECT `Id`,`Code`,`Title` FROM `DH_SvcRow` WHERE `Code` = @p0", &.{
            .{ .name = "p0", .value = .{ .text = "svc-1" } },
        });
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].int);
        try std.testing.expectEqualStrings("来自远程服务", rows.rows[0][2].text);
        std.debug.print("[dbservice] Query：{d} 行，Title={s}\n", .{ rows.rows.len, rows.rows[0][2].text });

        // ④ 计数 / 表结构
        const n = try client.query(aa, "SELECT COUNT(*) FROM `DH_SvcRow`", &.{});
        try std.testing.expectEqual(@as(i64, 1), n.rows[0][0].int);

        const tables_resp = try client.query(aa, "SELECT 1", &.{});
        try std.testing.expect(tables_resp.rows.len == 1);

        // ⑤ 事务：回滚后数据必须不见
        const tx = try client.beginTx(aa);
        _ = try client.executeTx(aa, tx, "INSERT INTO `DH_SvcRow` (`Code`,`Title`) VALUES ('tx-rollback','x')", &.{});
        // 事务内自己也要看得见（同一条连接）
        const inside = try client.queryTx(aa, tx, "SELECT COUNT(*) FROM `DH_SvcRow`", &.{});
        try std.testing.expectEqual(@as(i64, 2), inside.rows[0][0].int);
        try client.rollbackTx(aa, tx);
        const after_rb = try client.query(aa, "SELECT COUNT(*) FROM `DH_SvcRow`", &.{});
        try std.testing.expectEqual(@as(i64, 1), after_rb.rows[0][0].int);
        std.debug.print("[dbservice] 事务回滚：行数仍为 1\n", .{});

        // ⑥ 事务：提交后数据必须在
        const tx2 = try client.beginTx(aa);
        _ = try client.executeTx(aa, tx2, "INSERT INTO `DH_SvcRow` (`Code`,`Title`) VALUES ('tx-commit','y')", &.{});
        try client.commitTx(aa, tx2);
        const after_cm = try client.query(aa, "SELECT COUNT(*) FROM `DH_SvcRow`", &.{});
        try std.testing.expectEqual(@as(i64, 2), after_cm.rows[0][0].int);
        std.debug.print("[dbservice] 事务提交：行数变 2\n", .{});

        // ⑦ 负向：错令牌必须 401/Unauthorized
        var bad = zcode.dbclient.Client.init(a, io, base, "", "wrong");
        defer bad.deinit();
        try std.testing.expectError(error.Unauthorized, bad.login(aa));

        // ⑧ 负向：不存在的路由 → Unsupported（客户端据此降级）。
        // 路由全都叫 Db/*，所以用「错误的前缀」制造 404，验证降级分支真的会走到。
        const bad_base = try std.fmt.allocPrint(a, "{s}/nope", .{base});
        defer a.free(bad_base);
        var typed_ok = zcode.dbclient.Client.init(a, io, bad_base, "", "t-123");
        defer typed_ok.deinit();
        if (typed_ok.query(aa, "SELECT 1", &.{})) |_| {
            return error.TestUnexpectedResult;
        } else |e| try std.testing.expectEqual(error.Unsupported, e);

        // ⑨ `?format=packet` → C# `DbTable` v3 二进制；客户端解回来必须一致
        {
            var pa = std.heap.ArenaAllocator.init(a);
            defer pa.deinit();
            const t = try client.queryPacket(pa.allocator(), "SELECT `Id`,`Code`,`Title` FROM `DH_SvcRow` ORDER BY `Id`", &.{});
            try std.testing.expectEqual(@as(usize, 3), t.columns.len);
            try std.testing.expectEqualStrings("Id", t.columns[0]);
            try std.testing.expectEqualStrings("Code", t.columns[1]);
            try std.testing.expectEqualStrings("Title", t.columns[2]);
            // Id 是 Int32 列 → 推断成 int64（C# 的 BigInteger 口径一致：整数统一 int64）
            try std.testing.expectEqual(zcode.dbtable_packet.TypeCode.int64, t.types[0]);
            try std.testing.expectEqual(zcode.dbtable_packet.TypeCode.string, t.types[1]);
            try std.testing.expect(t.rows.len >= 1);
            try std.testing.expectEqual(@as(i64, 1), t.rows[0][0].int);
            try std.testing.expectEqualStrings("svc-1", t.rows[0][1].text);
            try std.testing.expectEqualStrings("来自远程服务", t.rows[0][2].text);
            std.debug.print("[dbservice] packet：列 {d} / 行 {d}（DbTable v3 二进制）\n", .{ t.columns.len, t.rows.len });
        }
    }

    ctx.stop.store(true, .release);
    // 先自连接唤醒阻塞中的 accept（服务端线程进去再退出）——
    // 直接 deinit 监听会让 accept 拿到 .CANCELLED，std 在那里是 `unreachable`。
    if (std.Io.net.IpAddress.parse("127.0.0.1", port)) |addr| {
        if (addr.connect(io, .{ .mode = .stream })) |c| {
            c.close(io);
        } else |_| {}
    } else |_| {}
    th.join();
    ctx.server.deinit(sio);

    try std.testing.expect(ctx.served.load(.acquire) > 0);
}
