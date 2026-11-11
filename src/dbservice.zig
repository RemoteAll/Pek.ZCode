//! 数据库远程服务（对应 DH.NCode `Services` / Rust `Pek.RCode/src/db_service.rs` 的核心部分）。
//!
//! 定位：**把本进程的 Dal 暴露成 HTTP 接口**，让没有数据库直连条件的进程（前后端分离、
//! 跨网段、跨语言）通过 `DbClient` 访问。协议与 C#/Rust 对齐：
//!
//! | 路由 | 作用 | 响应 `data` |
//! |---|---|---|
//! | `POST Db/Login` | 登录（返回库类型/版本） | `{dbType, version}` |
//! | `POST Db/Query` | 查询 | `{columns:[...], rows:[[...]]}` |
//! | `POST Db/Execute` | 增删改 | 影响行数 |
//! | `POST Db/InsertAndGetIdentity` | 插入并取自增 | 自增 id |
//! | `POST Db/QueryCount` | 计数 | 行数 |
//! | `POST Db/GetTables` | 表结构 | `[{name, tableName, columns:[...]}]` |
//! | `POST Db/Begin` / `Db/Commit` / `Db/Rollback` | 事务（C# 无此三路由） | 事务令牌 |
//!
//! 统一信封 `{code, data, msg}`（`code=0` 成功），与 C# `ApiHelper.ProcessResponse` 兼容。
//!
//! ## 与 C# 的**已知差异**（不静默降级）
//!
//! C# `DbController.Query` 的应答是 **`DbTable` v3 二进制**（`rs.ToPacket()`），本实现返回
//! **JSON 行列**。因此「C# 客户端 ↔ Zig 服务端」调 `Db/Query` 不互通；其余路由是 JSON 信封，互通。
//! 需要二进制互通时再补 `DbTable` v3 编解码（本轮没做，已在 `docs/移植对照-NCode.md` 记明）。
//!
//! ## 事务
//!
//! HTTP 是无状态的，而事务要求「BEGIN 之后的语句落在同一条连接上」→ `Db/Begin` 时取一条会话
//! 并 `begin()`，之后凭令牌路由到该会话，直到 `Commit`/`Rollback`。
//! **防泄漏**：任何事务相关请求最多每 1 秒扫一次，空闲超时（默认 60 秒）自动回滚回收。

const std = @import("std");
const zcode = struct {
    // 本模块在库内部，直接用相对导入
    const session = @import("session.zig");
    const dal = @import("dal.zig");
    const model = @import("model.zig");
};

const Session = @import("session.zig").Session;
const Dal = @import("dal.zig").Dal;
const Value = @import("zzig").db.Value;
const http_server = @import("zzig").http_server;

pub const DEFAULT_TX_TIMEOUT_SECS: u64 = 60;

pub const Options = struct {
    /// 访问令牌；空表示不校验（只允许绑回环地址时这么用）
    token: []const u8 = "",
    /// 允许访问的库名（对应 `DbRequest.db`）；空表示不限制
    databases: []const []const u8 = &.{},
    /// 单条语句最长执行时间不在这里管（由调用方设 `Dal` 的超时/上游代理兜底）
    tx_timeout_secs: u64 = DEFAULT_TX_TIMEOUT_SECS,
};

/// 一个进行中的事务。
///
/// **`session` 必须是堆上的稳定地址**：`Session.stmt_cache` 里的 `Stmt` 指回
/// `session.driver.sqlite`，一旦 Session 被按值搬走（栈上临时变量），finalize 就会
/// 读到野指针（实测段错误 0x40）。故：先 `create(Session)` 再往里放，之后不再搬。
const TxSlot = struct {
    session: *Session,
    last_used_ms: i64,
    db: []const u8,
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    dal: *Dal,
    opts: Options,
    txs: std.StringHashMapUnmanaged(*TxSlot) = .empty,
    next_tx_id: u64 = 1,
    last_sweep_ms: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, dal: *Dal, opts: Options) Service {
        return .{ .gpa = gpa, .dal = dal, .opts = opts };
    }

    pub fn deinit(self: *Service) void {
        var it = self.txs.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.session.deinit();
            self.gpa.destroy(e.value_ptr.*.session);
            self.gpa.destroy(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.txs.deinit(self.gpa);
    }

    /// 挂到 `zzig.http_server.Server` 上的处理函数（`ctx` 必须指向 `Service`）。
    pub fn handle(ctx: *anyopaque, req: http_server.RequestView, arena: std.mem.Allocator) anyerror!http_server.Reply {
        const self: *Service = @ptrCast(@alignCast(ctx));
        defer self.sweepTxs();

        const path = trimLeadingSlash(req.path);
        const body = req.body;

        // 令牌：JSON 字段 `token` 或查询串 `?token=`；两边都没有就按未授权处理（除非服务端没设令牌）
        const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch null;
        const token = blk: {
            if (parsed) |p| {
                if (p.value == .object) {
                    if (p.value.object.get("token")) |t| {
                        if (t == .string) break :blk t.string;
                    }
                }
            }
            break :blk queryParam(req.query, "token") orelse "";
        };
        if (self.opts.token.len > 0 and !std.mem.eql(u8, token, self.opts.token)) {
            return replyErr(arena, .unauthorized, 401, "令牌无效");
        }

        if (std.mem.eql(u8, path, "Db/Login")) return self.login(arena);
        if (std.mem.eql(u8, path, "Db/Query")) return self.query(arena, body, parsed);
        if (std.mem.eql(u8, path, "Db/Execute")) return self.execute(arena, body, parsed);
        if (std.mem.eql(u8, path, "Db/InsertAndGetIdentity")) return self.insertIdentity(arena, body, parsed);
        if (std.mem.eql(u8, path, "Db/QueryCount")) return self.queryCount(arena, body, parsed);
        if (std.mem.eql(u8, path, "Db/GetTables")) return self.getTables(arena);
        if (std.mem.eql(u8, path, "Db/Begin")) return self.beginTx(arena, body, parsed);
        if (std.mem.eql(u8, path, "Db/Commit")) return self.commitTx(arena, body, parsed);
        if (std.mem.eql(u8, path, "Db/Rollback")) return self.rollbackTx(arena, body, parsed);

        // 未知路由：404（客户端据此降级为 Unsupported，与 Rust 版一致）
        return replyErr(arena, .not_found, 404, "未知接口");
    }

    // ── 各路由实现 ─────────────────────────────────────────────────────────

    fn login(self: *Service, arena: std.mem.Allocator) !http_server.Reply {
        const kind = @tagName(self.dal.opts.provider);
        const data = try std.fmt.allocPrint(arena, "{{\"dbType\":\"{s}\",\"version\":\"\"}}", .{kind});
        return replyOk(arena, data);
    }

    fn query(self: *Service, arena: std.mem.Allocator, body: []const u8, parsed: ?std.json.Parsed(std.json.Value)) !http_server.Reply {
        const sql = (try requireSql(arena, body, parsed)) orelse return replyErr(arena, .bad_request, 400, "缺少 sql");
        const params = try parseParams(arena, parsed);
        var tmp: Session = undefined;
        const acq = (try self.acquire(arena, parsed, &tmp)) orelse return replyErr(arena, .not_found, 404, "事务不存在或已过期");
        defer if (acq.owned) tmp.deinit();
        const s = acq.s;

        const rows = s.queryRows(sql, params.list) catch |e| {
            return replyErr(arena, .internal_server_error, 500, try std.fmt.allocPrint(arena, "{s}；{s}", .{ @errorName(e), s.lastError() }));
        };
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("{\"columns\":[");
        // 列名从第一行取不到（行里没有列清单），故按结果列顺序输出位置名
        const ncols = if (rows.len > 0) rows[0].values.len else 0;
        for (0..ncols) |i| {
            if (i > 0) try out.writer.writeAll(",");
            try out.writer.print("\"c{d}\"", .{i});
        }
        try out.writer.writeAll("],\"rows\":[");
        for (rows, 0..) |r, ri| {
            if (ri > 0) try out.writer.writeAll(",");
            try out.writer.writeAll("[");
            for (r.values, 0..) |v, vi| {
                if (vi > 0) try out.writer.writeAll(",");
                try writeJsonValue(&out.writer, v);
            }
            try out.writer.writeAll("]");
        }
        try out.writer.writeAll("]}");
        return replyOk(arena, out.writer.buffered());
    }

    fn execute(self: *Service, arena: std.mem.Allocator, body: []const u8, parsed: ?std.json.Parsed(std.json.Value)) !http_server.Reply {
        const sql = (try requireSql(arena, body, parsed)) orelse return replyErr(arena, .bad_request, 400, "缺少 sql");
        const params = try parseParams(arena, parsed);
        var tmp: Session = undefined;
        const acq = (try self.acquire(arena, parsed, &tmp)) orelse return replyErr(arena, .not_found, 404, "事务不存在或已过期");
        defer if (acq.owned) tmp.deinit();
        const s = acq.s;
        const n = s.execute(sql, params.list) catch |e| {
            return replyErr(arena, .internal_server_error, 500, try std.fmt.allocPrint(arena, "{s}；{s}", .{ @errorName(e), s.lastError() }));
        };
        return replyOk(arena, try std.fmt.allocPrint(arena, "{d}", .{n}));
    }

    fn insertIdentity(self: *Service, arena: std.mem.Allocator, body: []const u8, parsed: ?std.json.Parsed(std.json.Value)) !http_server.Reply {
        const sql = (try requireSql(arena, body, parsed)) orelse return replyErr(arena, .bad_request, 400, "缺少 sql");
        const params = try parseParams(arena, parsed);
        var tmp: Session = undefined;
        const acq = (try self.acquire(arena, parsed, &tmp)) orelse return replyErr(arena, .not_found, 404, "事务不存在或已过期");
        defer if (acq.owned) tmp.deinit();
        const s = acq.s;
        _ = s.execute(sql, params.list) catch |e| {
            return replyErr(arena, .internal_server_error, 500, try std.fmt.allocPrint(arena, "{s}；{s}", .{ @errorName(e), s.lastError() }));
        };
        return replyOk(arena, try std.fmt.allocPrint(arena, "{d}", .{s.lastInsertId()}));
    }

    fn queryCount(self: *Service, arena: std.mem.Allocator, body: []const u8, parsed: ?std.json.Parsed(std.json.Value)) !http_server.Reply {
        const sql = (try requireSql(arena, body, parsed)) orelse return replyErr(arena, .bad_request, 400, "缺少 sql");
        const params = try parseParams(arena, parsed);
        var tmp: Session = undefined;
        const acq = (try self.acquire(arena, parsed, &tmp)) orelse return replyErr(arena, .not_found, 404, "事务不存在或已过期");
        defer if (acq.owned) tmp.deinit();
        const s = acq.s;
        const rows = s.queryRows(sql, params.list) catch |e| {
            return replyErr(arena, .internal_server_error, 500, try std.fmt.allocPrint(arena, "{s}；{s}", .{ @errorName(e), s.lastError() }));
        };
        const n: i64 = if (rows.len > 0 and rows[0].values.len > 0) switch (rows[0].values[0]) {
            .int => |v| v,
            else => 0,
        } else 0;
        return replyOk(arena, try std.fmt.allocPrint(arena, "{d}", .{n}));
    }

    fn getTables(self: *Service, arena: std.mem.Allocator) !http_server.Reply {
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("[");
        for (self.dal.model.tables, 0..) |t, ti| {
            if (ti > 0) try out.writer.writeAll(",");
            try out.writer.print("{{\"name\":\"{s}\",\"tableName\":\"{s}\",\"columns\":[", .{ t.name, t.table_name });
            for (t.columns, 0..) |c, ci| {
                if (ci > 0) try out.writer.writeAll(",");
                try out.writer.print(
                    "{{\"name\":\"{s}\",\"columnName\":\"{?s}\",\"primaryKey\":{s},\"identity\":{s},\"nullable\":{s}}}",
                    .{
                        c.name,
                        c.column_name,
                        if (c.primary_key) "true" else "false",
                        if (c.identity) "true" else "false",
                        if (c.nullable) "true" else "false",
                    },
                );
            }
            try out.writer.writeAll("]}");
        }
        try out.writer.writeAll("]");
        return replyOk(arena, out.writer.buffered());
    }

    // ── 事务 ───────────────────────────────────────────────────────────────

    fn beginTx(self: *Service, arena: std.mem.Allocator, body: []const u8, parsed: ?std.json.Parsed(std.json.Value)) !http_server.Reply {
        _ = body;
        const db = dbName(parsed) orelse "";
        if (!self.dbAllowed(db)) return replyErr(arena, .forbidden, 403, "库不在白名单");

        // 会话必须落在堆上的固定地址：之后它要缓存预处理语句，不能再被搬动
        const s = try self.gpa.create(Session);
        s.* = try self.openSession(arena, parsed);
        errdefer {
            s.deinit();
            self.gpa.destroy(s);
        }
        _ = s.beginTransaction(.default) catch |e| {
            return replyErr(arena, .internal_server_error, 500, try std.fmt.allocPrint(arena, "开启事务失败：{s}；{s}", .{ @errorName(e), s.lastError() }));
        };

        const slot = try self.gpa.create(TxSlot);
        slot.* = .{ .session = s, .last_used_ms = nowMs(), .db = try self.gpa.dupe(u8, db) };
        const id = try std.fmt.allocPrint(self.gpa, "{d}-{d}", .{ nowMs(), self.next_tx_id });
        self.next_tx_id += 1;
        self.txs.put(self.gpa, id, slot) catch |e| {
            s.deinit();
            self.gpa.destroy(s);
            self.gpa.destroy(slot);
            self.gpa.free(id);
            return e;
        };
        return replyOk(arena, try std.fmt.allocPrint(arena, "\"{s}\"", .{id}));
    }

    fn commitTx(self: *Service, arena: std.mem.Allocator, body: []const u8, parsed: ?std.json.Parsed(std.json.Value)) !http_server.Reply {
        return self.finishTx(arena, body, parsed, true);
    }

    fn rollbackTx(self: *Service, arena: std.mem.Allocator, body: []const u8, parsed: ?std.json.Parsed(std.json.Value)) !http_server.Reply {
        return self.finishTx(arena, body, parsed, false);
    }

    fn finishTx(self: *Service, arena: std.mem.Allocator, body: []const u8, parsed: ?std.json.Parsed(std.json.Value), commit: bool) !http_server.Reply {
        _ = body;
        const tx = txId(parsed) orelse return replyErr(arena, .bad_request, 400, "缺少 tx");
        const slot = self.txs.get(tx) orelse return replyErr(arena, .not_found, 404, "事务不存在或已过期");
        if (commit) {
            _ = slot.session.commit() catch |e| {
                return replyErr(arena, .internal_server_error, 500, try std.fmt.allocPrint(arena, "提交失败：{s}；{s}", .{ @errorName(e), slot.session.lastError() }));
            };
        } else {
            _ = slot.session.rollback(true) catch {};
        }
        self.dropTx(tx);
        return replyOk(arena, "null");
    }

    fn dropTx(self: *Service, tx: []const u8) void {
        if (self.txs.fetchRemove(tx)) |kv| {
            kv.value.session.deinit();
            self.gpa.destroy(kv.value.session);
            self.gpa.destroy(kv.value);
            self.gpa.free(kv.key);
        }
    }

    /// 惰性清扫：最多每秒一次；空闲超时的事务回滚回收（客户端崩溃也不留悬挂事务）。
    fn sweepTxs(self: *Service) void {
        if (self.txs.count() == 0) return;
        const now = nowMs();
        if (now - self.last_sweep_ms < 1000) return;
        self.last_sweep_ms = now;
        const timeout_ms: i64 = @intCast(self.opts.tx_timeout_secs * 1000);

        var dead: std.ArrayListUnmanaged([]const u8) = .empty;
        defer dead.deinit(self.gpa);
        var it = self.txs.iterator();
        while (it.next()) |e| {
            if (now - e.value_ptr.*.last_used_ms > timeout_ms) {
                dead.append(self.gpa, e.key_ptr.*) catch {};
            }
        }
        for (dead.items) |k| {
            std.debug.print("[zcode.dbservice] 事务空闲超时，自动回滚：{s}\n", .{k});
            self.dropTx(k);
        }
    }

    // ── 公共小工具 ─────────────────────────────────────────────────────────

    const Acq = struct {
        s: *Session,
        /// true 表示会话由本次请求新开，用完必须 `tmp.deinit()`
        owned: bool,
    };

    /// 语句该落到哪条会话：带 `tx` 就复用事务会话（不拥有，找不到返回 null）；
    /// 不带就新开一条（放进调用方的 `tmp`，`owned=true`）。
    fn acquire(self: *Service, arena: std.mem.Allocator, parsed: ?std.json.Parsed(std.json.Value), tmp: *Session) !?Acq {
        if (txId(parsed)) |id| {
            const slot = self.txs.get(id) orelse return null;
            slot.last_used_ms = nowMs();
            return .{ .s = slot.session, .owned = false };
        }
        tmp.* = try self.openSession(arena, parsed);
        return .{ .s = tmp, .owned = true };
    }

    fn openSession(self: *Service, arena: std.mem.Allocator, parsed: ?std.json.Parsed(std.json.Value)) !Session {
        _ = arena;
        const db = dbName(parsed) orelse "";
        if (!self.dbAllowed(db)) return error.DatabaseNotAllowed;
        return self.dal.openSession();
    }

    fn dbAllowed(self: *Service, db: []const u8) bool {
        if (self.opts.databases.len == 0) return true;
        for (self.opts.databases) |d| {
            if (std.mem.eql(u8, d, db)) return true;
        }
        return false;
    }
};

// ── JSON 小工具（信封 + 取值 + 序列化）────────────────────────────────────

fn replyOk(arena: std.mem.Allocator, data_json: []const u8) !http_server.Reply {
    return .{ .body = try std.fmt.allocPrint(arena, "{{\"code\":0,\"data\":{s},\"msg\":\"\"}}", .{data_json}) };
}

fn replyErr(arena: std.mem.Allocator, status: std.http.Status, code: i32, msg: []const u8) !http_server.Reply {
    return .{
        .status = status,
        .body = try std.fmt.allocPrint(arena, "{{\"code\":{d},\"data\":null,\"msg\":\"{s}\"}}", .{ code, msg }),
    };
}

fn requireSql(arena: std.mem.Allocator, body: []const u8, parsed: ?std.json.Parsed(std.json.Value)) !?[]const u8 {
    _ = arena;
    _ = body;
    const p = parsed orelse return null;
    if (p.value != .object) return null;
    const v = p.value.object.get("sql") orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

fn dbName(parsed: ?std.json.Parsed(std.json.Value)) ?[]const u8 {
    const p = parsed orelse return null;
    if (p.value != .object) return null;
    const v = p.value.object.get("db") orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn txId(parsed: ?std.json.Parsed(std.json.Value)) ?[]const u8 {
    const p = parsed orelse return null;
    if (p.value != .object) return null;
    const v = p.value.object.get("tx") orelse return null;
    if (v != .string) return null;
    return v.string;
}

/// 参数：`{"parameters":{"p0":1,"p1":"a"}}`。按键名字母序绑定（与 Rust 的兼容口径一致）。
const Params = struct { list: []const Value };

fn parseParams(arena: std.mem.Allocator, parsed: ?std.json.Parsed(std.json.Value)) !Params {
    const p = parsed orelse return .{ .list = &.{} };
    if (p.value != .object) return .{ .list = &.{} };
    const obj = p.value.object.get("parameters") orelse return .{ .list = &.{} };
    if (obj != .object or obj.object.count() == 0) return .{ .list = &.{} };

    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keys.deinit(arena);
    var it = obj.object.iterator();
    while (it.next()) |e| try keys.append(arena, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const list = try arena.alloc(Value, keys.items.len);
    for (keys.items, 0..) |k, i| {
        list[i] = jsonToValue(obj.object.get(k).?);
    }
    return .{ .list = list };
}

fn jsonToValue(v: std.json.Value) Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .text = s },
        else => .null,
    };
}

fn writeJsonValue(w: *std.Io.Writer, v: Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .text => |t| {
            try w.writeAll("\"");
            for (t) |c| switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(c),
            };
            try w.writeAll("\"");
        },
        else => try w.writeAll("null"),
    }
}

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return null;
}

fn trimLeadingSlash(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 0 and (s[0] == '/' or s[0] == '\\')) s = s[1..];
    return s;
}

fn nowMs() i64 {
    return @intCast(@divTrunc(@import("zzig").compat.nanoTimestamp(), std.time.ns_per_ms));
}
