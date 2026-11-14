//! 条件表达式构建器（对应 C# `Model/WhereBuilder.cs` + `Model/*Expression`）。
//!
//! ## 解决什么问题
//!
//! 数据权限 / 自定义筛选这类条件**存在配置里**（数据库、面板表单），运行时才知道：
//! `"CreateUserID={$userId} or LinkID in{#siteIds}"`。这里把它解析成结构化条件树，
//! 既能**转成 SQL**（`Where`/渲染），也能**在内存里求值**（`eval`，用于已取到实体后的二次判断，
//! 省掉为每条记录再查一次库）。
//!
//! ## 语法（逐条对齐 C#，含它刻意不支持的部分）
//!
//! ```text
//! 条件   := 项 { ("or" | "and") 项 }        // 单词级匹配，忽略大小写；or 优先级最低
//! 项     := 列名 "="  值
//!        |  列名 "!=" 值
//!        |  列名 "in" 值                     // 值是数组
//! 值     := "{$name}"                       // 取 Data（外层，如登录上下文）
//!        |  "{#name}"                       // 取 Data2（内层，如本次请求参数）
//!        |  数字 | 单引号字符串               // 字面量
//! ```
//!
//! **不支持的运算符直接报错**（C# 同样抛 `XCodeException`）：`>` `<` `>=` `<=`。
//! `==` 不是「等号」——按 C# 的实际行为，它会被解析成 `=` 加一个字面值 `={$x}`，
//! 求值恒为 false（`WhereBuilderTests.EvalFail` 就是这么断言的），本仓保持一致。
//!
//! ## 与 C# 的差异（写清楚）
//! - **嵌套取值**：C# 用反射取 `{$User.ID}` 的属性；Zig 不做反射，改为**按 key 精确查**
//!   （调用方把嵌套值拍平成 `"user.id"` 绑定）。这是显式差异，不是漏实现；
//! - 变量名大小写不敏感（与 C# 的 `StringComparer.OrdinalIgnoreCase` 一致）；
//! - 值是 `zzig.db.Value`，不再有 `.NET Object` 装箱。

const std = @import("std");
const model = @import("model.zig");
const Value = @import("zzig").db.Value;

pub const Error = error{
    /// 用了 `{$x}` 但没给 Data
    NoData,
    /// 用了 `{#x}` 但没给 Data2
    NoData2,
    /// 条件里的列在模型里不存在
    NoField,
    /// 不支持的运算符（`>` `<` `>=` `<=`）
    UnsupportedOperator,
    /// 语法不合法（缺运算符 / 值不完整 / 括号不匹配等）
    Malformed,
};

/// 运算符（只支持 C# 支持的这三个族）
pub const Op = enum {
    eq,
    ne,
    in,

    pub fn text(self: Op) []const u8 {
        return switch (self) {
            .eq => "=",
            .ne => "!=",
            .in => "in",
        };
    }
};

/// 变量绑定：`{$key}` 取 `data`，`{#key}` 取 `data2`。
pub const Binding = struct {
    key: []const u8,
    value: Value,
};

/// 条件树节点（内存归解析时给的 allocator）。
pub const Node = union(enum) {
    compare: struct {
        column: []const u8,
        op: Op,
        value: Value,
    },
    in_list: struct {
        column: []const u8,
        values: []const Value,
    },
    logic: struct {
        is_or: bool,
        left: *const Node,
        right: *const Node,
    },
};

pub const ParseOptions = struct {
    /// `{$x}` 的来源
    data: []const Binding = &.{},
    /// `{#x}` 的来源
    data2: []const Binding = &.{},
};

/// 解析条件表达式（一次性，节点与值都在 `a` 上分配）。
pub fn parseAlloc(a: std.mem.Allocator, table: *const model.TableMeta, text: []const u8, opts: ParseOptions) !*Node {
    var p = Parser{ .a = a, .table = table, .src = text, .opts = opts };
    const node = try p.parseLogic(true);
    p.skipSpace();
    if (p.pos != p.src.len) return Error.Malformed;
    return node;
}

const Parser = struct {
    a: std.mem.Allocator,
    table: *const model.TableMeta,
    src: []const u8,
    pos: usize = 0,
    opts: ParseOptions,

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or
            self.src[self.pos] == '\r' or self.src[self.pos] == '\n')) self.pos += 1;
    }

    /// 解析 or 层（`and` 优先级更高，先递归下去）
    fn parseLogic(self: *Parser, allow_or: bool) anyerror!*Node {
        var left = try self.parseAnd();
        while (true) {
            self.skipSpace();
            if (!allow_or) break;
            if (!self.matchWord("or")) break;
            const right = try self.parseAnd();
            const node = try self.a.create(Node);
            node.* = .{ .logic = .{ .is_or = true, .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseAnd(self: *Parser) anyerror!*Node {
        var left = try self.parseTerm();
        while (true) {
            self.skipSpace();
            if (!self.matchWord("and")) break;
            const right = try self.parseTerm();
            const node = try self.a.create(Node);
            node.* = .{ .logic = .{ .is_or = false, .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    /// 匹配一个独立单词（`or` / `and`），大小写不敏感，且后面必须是分隔
    fn matchWord(self: *Parser, word: []const u8) bool {
        if (self.pos + word.len > self.src.len) return false;
        if (!std.ascii.eqlIgnoreCase(self.src[self.pos .. self.pos + word.len], word)) return false;
        // 前后不能紧贴标识符字符
        if (self.pos > 0) {
            const prev = self.src[self.pos - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_') return false;
        }
        const after = self.pos + word.len;
        if (after < self.src.len) {
            const c = self.src[after];
            if (std.ascii.isAlphanumeric(c) or c == '_') return false;
        }
        self.pos = after;
        return true;
    }

    fn parseTerm(self: *Parser) anyerror!*Node {
        self.skipSpace();
        const col_name = try self.readIdentifier();
        self.skipSpace();

        // 运算符：先认 `!=`，再认 `=`；`>` `<` `>=` `<=` 明确报不支持（C# 也不支持）
        if (self.pos >= self.src.len) return Error.Malformed;
        if (self.startsWith("!=")) {
            self.pos += 2;
            return try self.finishCompare(col_name, .ne);
        }
        if (self.startsWith(">=") or self.startsWith("<=") or self.startsWith(">") or self.startsWith("<")) {
            return Error.UnsupportedOperator;
        }
        if (self.startsWith("=")) {
            self.pos += 1;
            return try self.finishCompare(col_name, .eq);
        }
        // in（后面紧跟值，C# 写作 `linkid in{#SiteIds}`）
        if (self.matchWord("in")) {
            const vals = try self.readValues();
            const node = try self.a.create(Node);
            node.* = .{ .in_list = .{ .column = try self.canonical(col_name), .values = vals } };
            return node;
        }
        return Error.Malformed;
    }

    fn finishCompare(self: *Parser, col_name: []const u8, op: Op) anyerror!*Node {
        const v = try self.readValue();
        const node = try self.a.create(Node);
        node.* = .{ .compare = .{ .column = try self.canonical(col_name), .op = op, .value = v } };
        return node;
    }

    /// 列名按模型校验并规范成模型里的写法（外部输入，必须校验）
    fn canonical(self: *Parser, name: []const u8) ![]const u8 {
        const col = self.table.column(name) orelse {
            std.debug.print(
                "[zcode] 条件表达式非法：表 {s} 不包含字段 {s}（条件串来自外部输入，已拒绝）\n",
                .{ self.table.effectiveTableName(), name },
            );
            return Error.NoField;
        };
        return col.name;
    }

    fn readIdentifier(self: *Parser) ![]const u8 {
        self.skipSpace();
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') continue;
            break;
        }
        if (self.pos == start) return Error.Malformed;
        return self.src[start..self.pos];
    }

    fn startsWith(self: *Parser, text: []const u8) bool {
        if (self.pos + text.len > self.src.len) return false;
        return std.mem.eql(u8, self.src[self.pos .. self.pos + text.len], text);
    }

    /// 读一个值：`{$x}` / `{#x}` / 数字 / 单引号字符串
    fn readValue(self: *Parser) anyerror!Value {
        self.skipSpace();
        if (self.pos >= self.src.len) return Error.Malformed;
        if (self.src[self.pos] == '{') {
            const close = std.mem.indexOfScalarPos(u8, self.src, self.pos, '}') orelse return Error.Malformed;
            const inner = std.mem.trim(u8, self.src[self.pos + 1 .. close], " \t");
            self.pos = close + 1;
            if (inner.len < 2) return Error.Malformed;
            const sigil = inner[0];
            const key = inner[1..];
            return switch (sigil) {
                '$' => lookupBinding(self.opts.data, key) orelse Error.NoData,
                '#' => lookupBinding(self.opts.data2, key) orelse Error.NoData2,
                else => Error.Malformed,
            };
        }
        if (self.src[self.pos] == '\'') {
            const close = std.mem.indexOfScalarPos(u8, self.src, self.pos + 1, '\'') orelse return Error.Malformed;
            const s = self.src[self.pos + 1 .. close];
            self.pos = close + 1;
            return .{ .text = s };
        }
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != ' ' and self.src[self.pos] != '\t') self.pos += 1;
        return parseLiteral(self.src[start..self.pos]);
    }

    /// `in` 的值：`{...}` 里既可以是绑定 `{#list}` / `{$list}`，也可以是逗号分隔的字面量。
    fn readValues(self: *Parser) anyerror![]const Value {
        self.skipSpace();
        if (self.pos < self.src.len and self.src[self.pos] == '{') {
            const close = std.mem.indexOfScalarPos(u8, self.src, self.pos, '}') orelse return Error.Malformed;
            const inner = std.mem.trim(u8, self.src[self.pos + 1 .. close], " \t");
            self.pos = close + 1;
            if (inner.len >= 2 and (inner[0] == '$' or inner[0] == '#')) {
                const v = if (inner[0] == '$')
                    lookupBinding(self.opts.data, inner[1..]) orelse return Error.NoData
                else
                    lookupBinding(self.opts.data2, inner[1..]) orelse return Error.NoData2;
                return self.valuesFromValue(v);
            }
            return self.valuesFromText(inner);
        }
        // 不带花括号：单个值
        const v = try self.readValue();
        return self.valuesFromValue(v);
    }

    /// 绑定值是文本时按逗号切成多值（配置里常写 `"2,4,8,16"`），否则单值。
    fn valuesFromValue(self: *Parser, v: Value) anyerror![]const Value {
        if (v == .text) return self.valuesFromText(v.text);
        const one = try self.a.alloc(Value, 1);
        one[0] = v;
        return one;
    }

    /// 逗号分隔的字面量（外层引号先剥掉）
    fn valuesFromText(self: *Parser, text: []const u8) anyerror![]const Value {
        var body = std.mem.trim(u8, text, " \t");
        if (body.len >= 2 and body[0] == '\'' and body[body.len - 1] == '\'') {
            body = body[1 .. body.len - 1];
        }
        var list: std.ArrayList(Value) = .empty;
        var it = std.mem.splitScalar(u8, body, ',');
        while (it.next()) |piece| {
            var t = std.mem.trim(u8, piece, " \t");
            if (t.len >= 2 and t[0] == '\'' and t[t.len - 1] == '\'') t = t[1 .. t.len - 1];
            if (t.len == 0) continue;
            try list.append(self.a, parseLiteral(t));
        }
        return list.toOwnedSlice(self.a);
    }
};

fn lookupBinding(bindings: []const Binding, key: []const u8) ?Value {
    for (bindings) |b| {
        if (std.ascii.eqlIgnoreCase(b.key, key)) return b.value;
    }
    return null;
}

fn parseLiteral(text: []const u8) Value {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return .{ .text = "" };
    if (std.fmt.parseInt(i64, t, 10)) |v| return .{ .int = v } else |_| {}
    if (std.fmt.parseFloat(f64, t)) |v| return .{ .float = v } else |_| {}
    return .{ .text = t };
}

// ── 求值（对应 C# `WhereBuilder.Eval(entity)`）──────────────────────────────

/// 在内存里对一行值求值（`values` 是「列名 → 值」的绑定，列名忽略大小写）。
///
/// 用途：已经取了实体再判断，避免为每条记录再查一次库。
pub fn eval(node: *const Node, values: []const Binding) bool {
    return switch (node.*) {
        .compare => |c| {
            const actual = lookupBinding(values, c.column) orelse return false;
            return switch (c.op) {
                .eq => valueEql(actual, c.value),
                .ne => !valueEql(actual, c.value),
                .in => false, // compare 节点不会是 in
            };
        },
        .in_list => |l| {
            const actual = lookupBinding(values, l.column) orelse return false;
            for (l.values) |v| {
                if (valueEql(actual, v)) return true;
            }
            return false;
        },
        .logic => |l| {
            if (l.is_or) return eval(l.left, values) or eval(l.right, values);
            return eval(l.left, values) and eval(l.right, values);
        },
    };
}

fn valueEql(a: Value, b: Value) bool {
    if (a == .null or b == .null) return a == .null and b == .null;
    if (a == .text and b == .text) return std.mem.eql(u8, a.text, b.text);
    if (a.asI64()) |ai| {
        if (b.asI64()) |bi| return ai == bi;
    }
    if (a.asF64()) |af| {
        if (b.asF64()) |bf| return af == bf;
    }
    return false;
}

// ── 用例（移植自 C# `WhereBuilderTests.cs`）──────────────────────────────────

fn testTable() model.TableMeta {
    return .{
        .name = "Log",
        .table_name = "Log",
        .columns = &[_]model.ColumnMeta{
            .{ .name = "Id", .data_type = .int32, .identity = true, .primary_key = true },
            .{ .name = "CreateUserID", .data_type = .int32 },
            .{ .name = "LinkID", .data_type = .int32 },
        },
    };
}

test "C# 普通表达式解析：CreateUserID={$userId}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = testTable();
    const data = [_]Binding{.{ .key = "userid", .value = .{ .int = 1234 } }};
    const node = try parseAlloc(a, &t, "CreateUserID={$userId}", .{ .data = &data });

    try std.testing.expect(node.* == .compare);
    try std.testing.expectEqualStrings("CreateUserID", node.compare.column);
    try std.testing.expectEqual(Op.eq, node.compare.op);
    try std.testing.expectEqual(@as(i64, 1234), node.compare.value.int);
}

test "C# 无数据源：用了 {$x} 但没给 Data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = testTable();
    try std.testing.expectError(Error.NoData, parseAlloc(arena.allocator(), &t, "CreateUserID={$userId}", .{}));
}

test "C# 数据源变量大小写：{#userId} 从 Data2 取，key 忽略大小写" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = testTable();
    const d2 = [_]Binding{.{ .key = "USERID", .value = .{ .int = 1234 } }};
    const node = try parseAlloc(arena.allocator(), &t, "CreateUserID={#userId}", .{ .data2 = &d2 });
    try std.testing.expectEqual(@as(i64, 1234), node.compare.value.int);
}

test "C# 无字段：表达式里的列在模型里不存在 → NoField" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = testTable();
    const data = [_]Binding{.{ .key = "userid", .value = .{ .int = 1 } }};
    try std.testing.expectError(Error.NoField, parseAlloc(arena.allocator(), &t, "UserID={$userId}", .{ .data = &data }));
}

test "C# 多层变量：C# 用反射取 {$User.ID}，本仓改为绑定拍平的 key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = testTable();
    // 显式差异：Zig 不做反射，调用方把嵌套值拍平成 "user.id"
    const data = [_]Binding{.{ .key = "user.id", .value = .{ .int = 1234 } }};
    const node = try parseAlloc(arena.allocator(), &t, "CreateUserID={$User.ID}", .{ .data = &data });
    try std.testing.expectEqual(@as(i64, 1234), node.compare.value.int);
}

test "C# 高级或运算：linkid in{...} or CreateUserID={#userId}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = testTable();
    const d2 = [_]Binding{.{ .key = "userId", .value = .{ .int = 1234 } }};
    const node = try parseAlloc(arena.allocator(), &t, "linkid in{'2,4,8,16'} or CreateUserID={#userId}", .{ .data2 = &d2 });

    try std.testing.expect(node.* == .logic);
    try std.testing.expect(node.logic.is_or);
    try std.testing.expect(node.logic.left.* == .in_list);
    try std.testing.expectEqualStrings("LinkID", node.logic.left.in_list.column);
    try std.testing.expectEqual(@as(usize, 4), node.logic.left.in_list.values.len);
    try std.testing.expectEqual(@as(i64, 8), node.logic.left.in_list.values[2].int);
}

test "C# 未支持表达式：>= 明确报错（不是静默当成 = ）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = testTable();
    const data = [_]Binding{.{ .key = "user.id", .value = .{ .int = 1234 } }};
    try std.testing.expectError(
        Error.UnsupportedOperator,
        parseAlloc(arena.allocator(), &t, "CreateUserID>={$User.ID}", .{ .data = &data }),
    );
}

test "C# EvalSuccess：命中 → true；!={#userId} or in{...} → true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = testTable();
    const data = [_]Binding{.{ .key = "userid", .value = .{ .int = 1234 } }};
    // C# 用例里 `SetData(dic); SetData2(dic);` 两份都塞同一个字典，这里保持一致
    const d2 = [_]Binding{
        .{ .key = "userId", .value = .{ .int = 1234 } },
        .{ .key = "SiteIds", .value = .{ .text = "2,4,8,16" } },
    };

    // 行数据：LinkID=8, CreateUserID=1234
    const row = [_]Binding{
        .{ .key = "LinkID", .value = .{ .int = 8 } },
        .{ .key = "CreateUserID", .value = .{ .int = 1234 } },
    };

    const n1 = try parseAlloc(a, &t, "CreateUserID={$userId}", .{ .data = &data });
    try std.testing.expect(eval(n1, &row));

    const n2 = try parseAlloc(a, &t, "CreateUserID!={#userId} or linkid in{#SiteIds}", .{ .data = &data, .data2 = &d2 });
    try std.testing.expect(eval(n2, &row));
}

test "C# EvalFail：== 不是等号（C# 行为：解析成 = 加字面量，恒 false）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = testTable();
    const data = [_]Binding{.{ .key = "userid", .value = .{ .int = 1234 } }};
    const row = [_]Binding{.{ .key = "CreateUserID", .value = .{ .int = 1234 } }};

    const n = try parseAlloc(a, &t, "CreateUserID=={$userId}", .{ .data = &data });
    try std.testing.expect(!eval(n, &row));
}
