//! 数据库远程服务的客户端（`DbClient`）：调用远端 `/Db/*` 接口。
//!
//! 协议见 `dbservice.zig`：统一信封 `{code, data, msg}`，`code=0` 成功。
//! 传输为 **HTTP/1.1**（Zig std 只实现 1.0/1.1；C#/Rust 侧同为 1.1），
//! 服务端每请求一连接（`Connection: close`）。
//!
//! 与 C#/Rust 的行为对齐：
//! - 路由不存在（404）→ `error.Unsupported`（Rust 版同样降级，便于连旧版服务端）；
//! - `code != 0` → `error.Server`，并把服务端 `msg` 放 `lastError()`；
//! - 事务：`Begin` 返回令牌，之后带令牌的 `Query`/`Execute` 落在**同一条会话**上。

const std = @import("std");
const zzig = @import("zzig");
const dbtable_packet = @import("dbtable_packet.zig");
const Value = zzig.db.Value;

pub const Error = error{
    Unsupported,
    Server,
    Unauthorized,
    MalformedResponse,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    /// 形如 `http://127.0.0.1:8080`（不带结尾 `/`）
    server: []const u8,
    /// 库名（对应连接串里的库/文件），服务端按白名单校验
    db: []const u8 = "",
    token: []const u8 = "",
    http: std.http.Client,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, server: []const u8, db: []const u8, token: []const u8) Client {
        return .{
            .gpa = gpa,
            .server = server,
            .db = db,
            .token = token,
            .http = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    pub fn lastError(self: *const Client) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn setError(self: *Client, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch self.err_buf[0..@min(self.err_buf.len, 200)];
        self.err_len = text.len;
    }

    // ── 对外接口 ───────────────────────────────────────────────────────────

    pub const LoginInfo = struct {
        db_type: []const u8 = "",
        version: []const u8 = "",
    };

    pub fn login(self: *Client, arena: std.mem.Allocator) !LoginInfo {
        // 登录也必须带上 `{db,token}`：服务端从中取令牌（之前发字面量 "null" 会必然 401）
        const req_body = try self.buildRequest(arena, "", &.{}, null);
        const body = try self.postJson(arena, "Db/Login", req_body);
        const data = try self.takeData(arena, body);
        if (data != .object) return error.MalformedResponse;
        return .{
            .db_type = strField(data.object.get("dbType")),
            .version = strField(data.object.get("version")),
        };
    }

    pub const Rows = struct {
        columns: []const []const u8 = &.{},
        rows: []const []const Value = &.{},
        arena: std.mem.Allocator,

        pub fn deinit(self: Rows) void {
            _ = self.arena;
        }
    };

    /// 查询：返回 JSON 行列（值按 `Value` 还原）。`parameters` 为空表示无参。
    pub fn query(self: *Client, arena: std.mem.Allocator, sql: []const u8, parameters: []const Param) !Rows {
        return self.queryWith(arena, sql, parameters, null);
    }

    /// 在事务里查询（`tx` 来自 `beginTx`）。
    pub fn queryTx(self: *Client, arena: std.mem.Allocator, tx: []const u8, sql: []const u8, parameters: []const Param) !Rows {
        return self.queryWith(arena, sql, parameters, tx);
    }

    /// 查询：要求服务端返回 C# `DbTable` **v3 二进制**（`?format=packet`）并解码。
    ///
    /// 适合与 C# 客户端互通（C# 侧直接 `new DbTable().Read(pk)`）；
    /// 需要 NULL 语义时继续用 `query`（JSON），v3 里 NULL 按类型默认值落字节。
    pub fn queryPacket(self: *Client, arena: std.mem.Allocator, sql: []const u8, parameters: []const Param) !dbtable_packet.Decoded {
        const body = try self.buildRequest(arena, sql, parameters, null);
        const url = try std.fmt.allocPrint(arena, "{s}/Db/Query?format=packet", .{std.mem.trimEnd(u8, self.server, "/")});
        const resp = zzig.Http.fetchBytes(arena, &self.http, .{
            .url = url,
            .method = .POST,
            .payload = body,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
        }) catch |e| {
            self.setError("请求 Db/Query（packet）失败：{s}", .{@errorName(e)});
            return e;
        };

        if (resp.status == .not_found) {
            self.setError("服务端没有 Db/Query 路由（404），降级为 Unsupported", .{});
            return error.Unsupported;
        }
        if (resp.status != .ok) {
            // 错误路径服务端仍然回 JSON 信封，这里把 msg 取出来供调用方定位
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch null;
            var msg: []const u8 = "";
            if (parsed) |p| {
                if (p == .object) {
                    if (p.object.get("msg")) |m| {
                        if (m == .string) msg = m.string;
                    }
                    if (p.object.get("code")) |c| {
                        if (c == .integer and c.integer == 401) {
                            self.setError("服务端返回 401：{s}", .{msg});
                            return error.Unauthorized;
                        }
                    }
                }
            }
            self.setError("服务端返回 HTTP {d}：{s}", .{ @backingInt(resp.status), truncate(msg) });
            return error.Server;
        }
        return dbtable_packet.decodeAlloc(arena, resp.body) catch |e| {
            self.setError("解码 DbTable v3 失败：{s}（响应 {d} 字节，开头：{s}）", .{ @errorName(e), resp.body.len, truncate(resp.body) });
            return e;
        };
    }

    fn queryWith(self: *Client, arena: std.mem.Allocator, sql: []const u8, parameters: []const Param, tx: ?[]const u8) !Rows {
        const body = try self.buildRequest(arena, sql, parameters, tx);
        const resp = try self.postJson(arena, "Db/Query", body);
        const data = try self.takeData(arena, resp);
        if (data != .object) return error.MalformedResponse;

        var cols: std.ArrayListUnmanaged([]const u8) = .empty;
        if (data.object.get("columns")) |c| {
            if (c == .array) {
                for (c.array.items) |item| {
                    if (item == .string) try cols.append(arena, item.string);
                }
            }
        }
        var rows: std.ArrayListUnmanaged([]const Value) = .empty;
        if (data.object.get("rows")) |r| {
            if (r == .array) {
                for (r.array.items) |row| {
                    if (row != .array) continue;
                    const one = try arena.alloc(Value, row.array.items.len);
                    for (row.array.items, 0..) |v, i| one[i] = jsonToValue(v);
                    try rows.append(arena, one);
                }
            }
        }
        return .{ .columns = cols.items, .rows = rows.items, .arena = arena };
    }

    pub fn execute(self: *Client, arena: std.mem.Allocator, sql: []const u8, parameters: []const Param) !i64 {
        return self.executeWith(arena, sql, parameters, null);
    }

    /// 在事务里执行（`tx` 来自 `beginTx`）。
    pub fn executeTx(self: *Client, arena: std.mem.Allocator, tx: []const u8, sql: []const u8, parameters: []const Param) !i64 {
        return self.executeWith(arena, sql, parameters, tx);
    }

    fn executeWith(self: *Client, arena: std.mem.Allocator, sql: []const u8, parameters: []const Param, tx: ?[]const u8) !i64 {
        const body = try self.buildRequest(arena, sql, parameters, tx);
        const resp = try self.postJson(arena, "Db/Execute", body);
        const data = try self.takeData(arena, resp);
        return switch (data) {
            .integer => |i| i,
            else => error.MalformedResponse,
        };
    }

    pub fn insertAndGetIdentity(self: *Client, arena: std.mem.Allocator, sql: []const u8, parameters: []const Param) !i64 {
        const body = try self.buildRequest(arena, sql, parameters, null);
        const resp = try self.postJson(arena, "Db/InsertAndGetIdentity", body);
        const data = try self.takeData(arena, resp);
        return switch (data) {
            .integer => |i| i,
            else => error.MalformedResponse,
        };
    }

    /// 事务：返回令牌；失败（服务端没有这三条路由）会返回 `error.Unsupported`。
    pub fn beginTx(self: *Client, arena: std.mem.Allocator) ![]const u8 {
        const body = try self.buildRequest(arena, "", &.{}, null);
        const resp = try self.postJson(arena, "Db/Begin", body);
        const data = try self.takeData(arena, resp);
        if (data != .string) return error.MalformedResponse;
        return data.string;
    }

    pub fn commitTx(self: *Client, arena: std.mem.Allocator, tx: []const u8) !void {
        const body = try self.buildRequest(arena, "", &.{}, tx);
        _ = try self.postJson(arena, "Db/Commit", body);
    }

    pub fn rollbackTx(self: *Client, arena: std.mem.Allocator, tx: []const u8) !void {
        const body = try self.buildRequest(arena, "", &.{}, tx);
        _ = try self.postJson(arena, "Db/Rollback", body);
    }

    // ── 内部 ───────────────────────────────────────────────────────────────

    pub const Param = struct {
        name: []const u8,
        value: Value,
    };

    /// 构造请求体：`{db, token, sql, parameters:{...}}`（`parameters` 用**键名字典**，与服务端按名绑定一致）。
    fn buildRequest(
        self: *Client,
        arena: std.mem.Allocator,
        sql: []const u8,
        parameters: []const Param,
        tx: ?[]const u8,
    ) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("{{\"db\":\"{s}\",\"token\":\"{s}\"", .{ self.db, self.token });
        if (tx) |t| try out.writer.print(",\"tx\":\"{s}\"", .{t});
        try out.writer.print(",\"sql\":\"{s}\"", .{sql});
        try out.writer.writeAll(",\"parameters\":{");
        for (parameters, 0..) |p, i| {
            if (i > 0) try out.writer.writeAll(",");
            try out.writer.print("\"{s}\":", .{p.name});
            try writeJsonValue(&out.writer, p.value);
        }
        try out.writer.writeAll("}}");
        return out.writer.buffered();
    }

    fn postJson(self: *Client, arena: std.mem.Allocator, route: []const u8, body: []const u8) !std.json.Value {
        const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, self.server, "/"), route });
        const resp = zzig.Http.fetchBytes(arena, &self.http, .{
            .url = url,
            .method = .POST,
            .payload = body,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
        }) catch |e| {
            self.setError("请求 {s} 失败：{s}", .{ route, @errorName(e) });
            return e;
        };

        if (resp.status == .not_found) {
            self.setError("服务端没有 {s} 路由（404），降级为 Unsupported", .{route});
            return error.Unsupported;
        }

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch |e| {
            self.setError("解析 {s} 响应失败：{s}；响应体：{s}", .{ route, @errorName(e), truncate(resp.body) });
            return error.MalformedResponse;
        };

        // 信封：{code, data, msg}；没有 code 时按原样返回（兼容旧版/C# ApiHelper 口径）
        if (parsed == .object) {
            if (parsed.object.get("code")) |code_v| {
                if (code_v == .integer and code_v.integer != 0) {
                    const msg = strField(parsed.object.get("msg"));
                    self.setError("服务端返回错误 {d}：{s}", .{ code_v.integer, msg });
                    return switch (code_v.integer) {
                        401 => error.Unauthorized,
                        else => error.Server,
                    };
                }
            }
        }
        return parsed;
    }

    fn takeData(self: *Client, arena: std.mem.Allocator, resp: std.json.Value) !std.json.Value {
        _ = self;
        _ = arena;
        if (resp != .object) return error.MalformedResponse;
        return resp.object.get("data") orelse std.json.Value{ .null = {} };
    }
};

fn truncate(s: []const u8) []const u8 {
    return if (s.len <= 200) s else s[0..200];
}

fn strField(v: ?std.json.Value) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
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
