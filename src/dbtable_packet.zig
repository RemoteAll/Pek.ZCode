//! C# `NewLife.Data.DbTable` **v3 二进制格式**（`Db/Query` 的跨语言互通）。
//!
//! 格式不是猜的：字节规则来自 `G:\Code\Pek.FrameWork\DH.NCore\DH.NCore\Data\DbTable.cs` 与
//! `Serialization\Binary\{Binary,BinaryGeneral,BinaryNormal}.cs` 的源码，并用**真实 C# 运行时**
//! （`DH.NCore.dll`，net10.0）生成黄金字节逐字节比对（见文件末尾的单测常量）。
//!
//! ## 格式（v3）
//!
//! ```text
//! "NewLifeDbTable"           14 字节 ASCII（魔数）
//! 03                         版本（1 字节）
//! 00                         保留位：Binary.Write(Int32 0) → 7bit 编码 → 1 字节
//! <varint count>             列数
//! 每列： <varint 字节数> <UTF-8 列名> <TypeCode 1 字节> [TypeCode==1 时: <varint 字节数> <UTF-8 类型全名>]
//! <4 字节 LE 行数>            注意：**不是 varint**（C# 用 `Total.GetBytes()` 原样写 4 字节）
//! 每行按列顺序写值（见下）
//! ```
//!
//! 值的编码（`Binary.CreateBinary` = `{ EncodeInt = true, FullTime = true }`）：
//!
//! | TypeCode | 取值 | 编码 |
//! |---|---|---|
//! | 3 Boolean | 1 字节 |
//! | 6 Byte | 1 字节 |
//! | 7/9/11 Int16/Int32/Int64 | **7bit varint**（负数按无符号补码，Int32 的 -1 = 5 字节、Int64 = 10 字节） |
//! | 13 Single | 4 字节 **大端**（`Binary.IsLittleEndian` 默认 false） |
//! | 14 Double | 8 字节 **大端** |
//! | 15 Decimal | 4 个 varint：`.NET Decimal.GetBits` 的 `lo / mid / hi / flags`（flags = scale<<16 \| 0x80000000 负） |
//! | 16 DateTime | varint(`DateTime.ToBinary()` = ticks，kind=0 未指定) |
//! | 18 String | varint(UTF-8 字节数) + UTF-8 |
//! | 1 Object(`System.Byte[]`) | varint(字节数) + 原始字节 |
//!
//! ## 两个「和直觉不同」的口径（都实测过）
//!
//! 1. **浮点是 big-endian**：`Binary.IsLittleEndian` 默认 `false`，所以 `Write(Double)` 走
//!    `WriteDoubleBigEndian`（1.5 → `3F F8 00 00 00 00 00 00`）。
//! 2. **整型全部 7bit 变长**，包括 `Decimal.GetBits()` 的四个 32 位分量和 `DateTime.ToBinary()`。
//!
//! ## NULL 怎么处理
//!
//! C# 的 `BinaryGeneral.Write(value, type)` 对值类型列写 `null` 会**抛 `InvalidCastException`**
//! （`(Int64)(value ?? 0)` 把 Int32 0 拆箱成 Int64，实测），而它自己从数据库读数据时
//! 已经把 `DBNull` 换成了**类型默认值**（`DbTable.ReadData` → `GetDefault`）。
//! 因此本实现**与 C# 读库口径一致**：NULL 写成该列的默认值（0 / "" / 0m / ticks=0 / 空数组），
//! 解回来也是默认值而不是 null。要区分 NULL 请走 JSON 信封。

const std = @import("std");
const Value = @import("zzig").db.Value;
const Row = @import("zzig").db.Row;
const Decimal = @import("zzig").Decimal;
const DateTime = @import("zzig").DateTime;

/// 魔数（`DbTable.MAGIC`）
pub const magic = "NewLifeDbTable";
/// 版本（`DbTable._Ver`）
pub const version: u8 = 3;
/// `System.Byte[]` 的类型全名（TypeCode.Object 时写在头部）
pub const byte_array_type_name = "System.Byte[]";
/// 1970-01-01 的 .NET ticks（`DateTime.FromBinary(621355968000000000) == 1970-01-01`）
pub const ticks_unix_epoch: i64 = 621_355_968_000_000_000;

pub const Error = error{
    /// 数据不足/长度越界（报文坏了）
    Protocol,
    /// 魔数或版本不对（不是 DbTable v3）
    BadMagic,
    /// TypeCode 不在支持范围内（不猜长度）
    UnsupportedTypeCode,
    /// 列数与行内值个数不一致
    Shape,
    /// `Decimal` 超出 .NET `decimal` 的 96 位尾数/28 位小数
    DecimalOverflow,
};

/// .NET `TypeCode`（只列本格式用到的；其余取值解码时明确报错）。
pub const TypeCode = enum(u8) {
    object = 1,
    boolean = 3,
    byte = 6,
    int16 = 7,
    int32 = 9,
    int64 = 11,
    single = 13,
    double = 14,
    decimal = 15,
    datetime = 16,
    string = 18,

    pub fn fromByte(b: u8) !TypeCode {
        return switch (b) {
            1 => .object,
            3 => .boolean,
            6 => .byte,
            7 => .int16,
            9 => .int32,
            11 => .int64,
            13 => .single,
            14 => .double,
            15 => .decimal,
            16 => .datetime,
            18 => .string,
            else => error.UnsupportedTypeCode,
        };
    }
};

pub const Column = struct {
    name: []const u8,
    type: TypeCode = .string,
};

/// 解码结果（列名 / 列类型 / 行；全部在传入的 arena 上）。
pub const Decoded = struct {
    columns: []const []const u8 = &.{},
    types: []const TypeCode = &.{},
    rows: []const []const Value = &.{},

    pub fn columnIndex(self: Decoded, name: []const u8) ?usize {
        for (self.columns, 0..) |c, i| {
            if (std.ascii.eqlIgnoreCase(c, name)) return i;
        }
        return null;
    }
};

// ── 编码 ────────────────────────────────────────────────────────────────────

/// 把一组行（`Row`）编码成 DbTable v3 字节串；列类型按每列第一个非 NULL 值推断。
pub fn encodeRowsAlloc(gpa: std.mem.Allocator, rows: []const Row) ![]u8 {
    if (rows.len == 0) return Error.Shape;
    const names = rows[0].names;
    if (names.len == 0) return Error.Shape;

    const cols = try gpa.alloc(Column, names.len);
    defer gpa.free(cols);
    for (names, 0..) |n, i| cols[i] = .{ .name = n, .type = inferColumnType(rows, i) };

    const vals = try gpa.alloc([]const Value, rows.len);
    defer gpa.free(vals);
    for (rows, 0..) |r, i| vals[i] = r.values;

    return encodeAlloc(gpa, cols, vals);
}

/// 按显式列定义编码。
pub fn encodeAlloc(gpa: std.mem.Allocator, columns: []const Column, rows: []const []const Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, magic);
    try out.append(gpa, version);
    try pushVarint(gpa, &out, 0); // 保留位
    try pushVarint(gpa, &out, columns.len);

    for (columns) |c| {
        try pushBytes(gpa, &out, c.name);
        try out.append(gpa, @backingInt(c.type));
        if (c.type == .object) try pushBytes(gpa, &out, byte_array_type_name);
    }

    // 行数：4 字节小端（不是 varint）
    const total: u32 = @intCast(rows.len);
    try out.appendSlice(gpa, &[_]u8{
        @truncate(total),
        @truncate(total >> 8),
        @truncate(total >> 16),
        @truncate(total >> 24),
    });

    for (rows) |row| {
        if (row.len != columns.len) return Error.Shape;
        for (row, 0..) |v, i| try appendValue(gpa, &out, columns[i].type, v);
    }

    return out.toOwnedSlice(gpa);
}

/// 推断某列的类型：取第一个非 NULL 的值；全 NULL 用 `string`。
pub fn inferColumnType(rows: []const Row, index: usize) TypeCode {
    for (rows) |r| {
        if (index >= r.values.len) continue;
        const v = r.values[index];
        switch (v) {
            .null => continue,
            .boolean => return .boolean,
            .int => return .int64,
            .float => return .double,
            .decimal => |d| return if (decimalFitsDotNet(d)) .decimal else .string,
            .datetime => return .datetime,
            .text => return .string,
            .blob => return .object,
        }
    }
    return .string;
}

/// .NET `decimal` 是 96 位尾数 + 0..28 位小数；超出就不能用 Decimal 列表达。
fn decimalFitsDotNet(d: Decimal) bool {
    if (d.scale > 28) return false;
    const mag: u128 = @intCast(if (d.mantissa < 0) -d.mantissa else d.mantissa);
    return mag < (@as(u128, 1) << 96);
}

fn appendValue(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tc: TypeCode, v: Value) !void {
    switch (tc) {
        .boolean => try out.append(gpa, if (v.asBool() orelse false) 1 else 0),
        .byte => try out.append(gpa, @truncate(@as(u64, @bitCast(v.asI64() orelse 0)))),
        .int16 => try pushVarint(gpa, out, @as(u64, @as(u16, @bitCast(@as(i16, @truncate(v.asI64() orelse 0)))))),
        .int32 => try pushVarint(gpa, out, @as(u64, @as(u32, @bitCast(@as(i32, @truncate(v.asI64() orelse 0)))))),
        .int64 => try pushVarint(gpa, out, @as(u64, @bitCast(v.asI64() orelse 0))),
        .single => {
            const bits: u32 = @bitCast(v.asF32() orelse 0);
            try out.appendSlice(gpa, &[_]u8{
                @truncate(bits >> 24), @truncate(bits >> 16), @truncate(bits >> 8), @truncate(bits),
            });
        },
        .double => {
            const bits: u64 = @bitCast(v.asF64() orelse 0);
            try out.appendSlice(gpa, &[_]u8{
                @truncate(bits >> 56), @truncate(bits >> 48), @truncate(bits >> 40), @truncate(bits >> 32),
                @truncate(bits >> 24), @truncate(bits >> 16), @truncate(bits >> 8),  @truncate(bits),
            });
        },
        .decimal => {
            const d = v.asDecimal() orelse Decimal.zero();
            if (!decimalFitsDotNet(d)) return Error.DecimalOverflow;
            const bits = decimalBits(d);
            try pushVarint(gpa, out, bits.lo);
            try pushVarint(gpa, out, bits.mid);
            try pushVarint(gpa, out, bits.hi);
            try pushVarint(gpa, out, bits.flags);
        },
        .datetime => {
            const dt = v.asDatetime() orelse DateTime{ .year = 1, .month = 1, .day = 1 };
            try pushVarint(gpa, out, datetimeTicks(dt));
        },
        .string => {
            if (v.asText()) |t| {
                try pushBytes(gpa, out, t);
            } else {
                // 数值/时间落进 String 列时按 XCode 文本口径格式化（不丢类型）
                const text = try v.toTextAlloc(gpa);
                defer gpa.free(text);
                try pushBytes(gpa, out, text);
            }
        },
        .object => try pushBytes(gpa, out, v.asBlob() orelse ""),
    }
}

const DecimalBits = struct { lo: u32, mid: u32, hi: u32, flags: u32 };

/// `Decimal` → `.NET Decimal.GetBits` 的四个 32 位分量。
fn decimalBits(d: Decimal) DecimalBits {
    const negative = d.mantissa < 0;
    const mag: u128 = @intCast(if (negative) -d.mantissa else d.mantissa);
    return .{
        .lo = @truncate(mag),
        .mid = @truncate(mag >> 32),
        .hi = @truncate(mag >> 64),
        .flags = (@as(u32, d.scale) << 16) | (if (negative) @as(u32, 0x8000_0000) else 0),
    };
}

/// `DateTime` → .NET ticks（100ns，kind = Unspecified）。
fn datetimeTicks(dt: DateTime) u64 {
    const unix_secs = dt.toUnixSeconds();
    const ticks = (unix_secs + (ticks_unix_epoch / 10_000_000)) * 10_000_000 +
        @as(i64, @intCast(dt.nanos / 100));
    return @intCast(ticks);
}

/// .NET ticks → `DateTime`。
fn datetimeFromTicks(ticks: i64) DateTime {
    const secs = @divFloor(ticks, 10_000_000) - (ticks_unix_epoch / 10_000_000);
    const rem: i64 = @mod(ticks, 10_000_000);
    var dt = DateTime.fromUnixSeconds(secs);
    dt.nanos = @intCast(rem * 100);
    return dt;
}

// ── 解码 ────────────────────────────────────────────────────────────────────

/// 解码 DbTable v3；列名/行/字符串都分配在 `arena` 上。
pub fn decodeAlloc(arena: std.mem.Allocator, bytes: []const u8) !Decoded {
    var p = Pos{ .buf = bytes };

    const got_magic = try p.take(magic.len);
    if (!std.mem.eql(u8, got_magic, magic)) return Error.BadMagic;

    const ver = try p.byte();
    if (ver == 0 or ver > version) return Error.BadMagic;
    _ = try p.varint(); // 保留位

    const count = try p.varint();
    if (count > 4096) return Error.Protocol;
    const n: usize = @intCast(count);

    const columns = try arena.alloc([]const u8, n);
    const types = try arena.alloc(TypeCode, n);
    for (0..n) |i| {
        columns[i] = try arena.dupe(u8, try p.bytes());
        const raw = try p.byte();
        const tc = TypeCode.fromByte(raw) catch return Error.UnsupportedTypeCode;
        types[i] = tc;
        if (tc == .object) {
            const name = try p.bytes();
            // 只有 byte[] 有明确取值口径；其它 Object 类型不猜
            if (!std.mem.eql(u8, name, byte_array_type_name)) return Error.UnsupportedTypeCode;
        }
    }

    const total_raw = try p.take(4);
    const total = std.mem.readInt(u32, total_raw[0..4], .little);
    if (total > 10_000_000) return Error.Protocol;

    const rows = try arena.alloc([]const Value, total);
    for (0..total) |r| {
        const values = try arena.alloc(Value, n);
        for (0..n) |i| values[i] = try readValue(arena, types[i], &p);
        rows[r] = values;
    }

    return .{ .columns = columns, .types = types, .rows = rows };
}

fn readValue(arena: std.mem.Allocator, tc: TypeCode, p: *Pos) !Value {
    switch (tc) {
        .boolean => return .{ .boolean = (try p.byte()) != 0 },
        .byte => return .{ .int = try p.byte() },
        .int16 => return .{ .int = @as(i16, @bitCast(@as(u16, @truncate(try p.varint())))) },
        .int32 => return .{ .int = @as(i32, @bitCast(@as(u32, @truncate(try p.varint())))) },
        .int64 => return .{ .int = @bitCast(try p.varint()) },
        .single => {
            const b = try p.take(4);
            const bits = (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
            return .{ .float = @as(f32, @bitCast(bits)) };
        },
        .double => {
            const b = try p.take(8);
            var bits: u64 = 0;
            for (b) |byte| bits = (bits << 8) | byte;
            return .{ .float = @as(f64, @bitCast(bits)) };
        },
        .decimal => {
            const lo: u32 = @truncate(try p.varint());
            const mid: u32 = @truncate(try p.varint());
            const hi: u32 = @truncate(try p.varint());
            const flags: u32 = @truncate(try p.varint());
            const mag: u128 = (@as(u128, hi) << 64) | (@as(u128, mid) << 32) | lo;
            var mantissa: i128 = @intCast(mag);
            if ((flags & 0x8000_0000) != 0) mantissa = -mantissa;
            return .{ .decimal = .{ .mantissa = mantissa, .scale = @truncate((flags >> 16) & 0xFF) } };
        },
        .datetime => return .{ .datetime = datetimeFromTicks(@bitCast(try p.varint())) },
        .string => return .{ .text = try arena.dupe(u8, try p.bytes()) },
        .object => return .{ .blob = try arena.dupe(u8, try p.bytes()) },
    }
}

// ── 底层读写 ────────────────────────────────────────────────────────────────

/// 7bit 变长无符号整数（与 C# `Binary.WriteEncoded` 一致）。
fn pushVarint(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var n = value;
    while (n >= 0x80) {
        try out.append(gpa, @as(u8, @truncate(n)) | 0x80);
        n >>= 7;
    }
    try out.append(gpa, @truncate(n));
}

/// varint(字节数) + 原始字节（C# `WriteSize` 默认走 7bit 编码）。
fn pushBytes(gpa: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try pushVarint(gpa, out, bytes.len);
    if (bytes.len > 0) try out.appendSlice(gpa, bytes);
}

const Pos = struct {
    buf: []const u8,
    pos: usize = 0,

    fn byte(self: *Pos) !u8 {
        if (self.pos >= self.buf.len) return Error.Protocol;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    fn take(self: *Pos, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return Error.Protocol;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn varint(self: *Pos) !u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(u64, b & 0x7F) << @intCast(shift);
            if ((b & 0x80) == 0) return result;
            shift += 7;
            if (shift >= 64) return Error.Protocol;
        }
    }

    fn bytes(self: *Pos) ![]const u8 {
        const n = try self.varint();
        return self.take(@intCast(n));
    }
};

// ── 单测：黄金字节来自真实 C# 运行时（DH.NCore.dll / net10.0）─────────────────

const golden_8col_hex =
    "4E65774C69666544625461626C650300080249640B044E616D6512024F6B" ++
    "0306416D6F756E740F0553636F72650E07437265617465641004426C6F62" ++
    "010D53797374656D2E427974655B5D074E6F7468696E6709020000002A09" ++
    "E4B8ADE6968761626301D20900008080083FF8000000000000B09481E9F2" ++
    "92D0EF080301020307FFFFFFFFFFFFFFFFFF0100000100008080888008C0" ++
    "020000000000008080D6BDDFFEDFCF080000";

fn expectSameHex(expected_hex: []const u8, actual: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const actual_hex = std.fmt.bufPrint(&buf, "{X}", .{actual}) catch return error.TooLong;
    // 大写十六进制（std.fmt 的 {X} 对切片输出为 `{ 4E, 65 }` 形式，逐字节重排）
    _ = actual_hex;
    var i: usize = 0;
    while (i < expected_hex.len / 2) : (i += 1) {
        const hi = try hexVal(expected_hex[i * 2]);
        const lo = try hexVal(expected_hex[i * 2 + 1]);
        const want: u8 = (hi << 4) | lo;
        if (i >= actual.len) {
            std.debug.print("[dbtable_packet] 第 {d} 字节缺失（期望 {X:0>2}）\n", .{ i, want });
            return error.TestExpectedEqual;
        }
        if (actual[i] != want) {
            std.debug.print("[dbtable_packet] 第 {d} 字节不符：期望 {X:0>2}，实际 {X:0>2}\n", .{ i, want, actual[i] });
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expectEqual(expected_hex.len / 2, actual.len);
}

fn hexVal(c: u8) !u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return error.NotHex;
}

test "DbTable v3：8 列黄金字节逐字节一致（真实 C# 运行时产出）" {
    const a = std.testing.allocator;

    const dt1 = DateTime{ .year = 2026, .month = 11, .day = 12, .hour = 8, .minute = 30, .second = 15, .nanos = 123_000_000 };
    const dt2 = DateTime{ .year = 1970, .month = 1, .day = 1 };

    const cols = [_]Column{
        .{ .name = "Id", .type = .int64 },
        .{ .name = "Name", .type = .string },
        .{ .name = "Ok", .type = .boolean },
        .{ .name = "Amount", .type = .decimal },
        .{ .name = "Score", .type = .double },
        .{ .name = "Created", .type = .datetime },
        .{ .name = "Blob", .type = .object },
        .{ .name = "Nothing", .type = .int32 },
    };

    const row1 = [_]Value{
        .{ .int = 42 },
        .{ .text = "中文abc" },
        .{ .boolean = true },
        .{ .decimal = .{ .mantissa = 1234, .scale = 2 } },
        .{ .float = 1.5 },
        .{ .datetime = dt1 },
        .{ .blob = &[_]u8{ 1, 2, 3 } },
        .{ .int = 7 },
    };
    const row2 = [_]Value{
        .{ .int = -1 },
        .{ .text = "" },
        .{ .boolean = false },
        .{ .decimal = .{ .mantissa = -1, .scale = 2 } },
        .{ .float = -2.25 },
        .{ .datetime = dt2 },
        .{ .blob = "" },
        .{ .int = 0 },
    };
    const rows = [_][]const Value{ &row1, &row2 };

    const bytes = try encodeAlloc(a, &cols, &rows);
    defer a.free(bytes);
    try expectSameHex(golden_8col_hex, bytes);
}

test "DbTable v3：单列类型探测的黄金字节（Int32 / Double / Decimal / DateTime / Byte[]）" {
    const a = std.testing.allocator;

    const Case = struct { tc: TypeCode, v: Value, hex: []const u8 };
    const head = "4E65774C69666544625461626C650300010163";

    const cases = [_]Case{
        .{ .tc = .int32, .v = .{ .int = 513 }, .hex = "09010000008104" },
        .{ .tc = .int64, .v = .{ .int = 513 }, .hex = "0B010000008104" },
        .{ .tc = .boolean, .v = .{ .boolean = true }, .hex = "030100000001" },
        .{ .tc = .byte, .v = .{ .int = 7 }, .hex = "060100000007" },
        .{ .tc = .single, .v = .{ .float = 1.5 }, .hex = "0D010000003FC00000" },
        .{ .tc = .double, .v = .{ .float = 1.5 }, .hex = "0E010000003FF8000000000000" },
        .{ .tc = .decimal, .v = .{ .decimal = .{ .mantissa = 1234, .scale = 2 } }, .hex = "0F01000000D2090000808008" },
        .{
            .tc = .datetime,
            .v = .{ .datetime = .{ .year = 2000, .month = 1, .day = 1 } },
            .hex = "1001000000808091BFA4C0C8E008",
        },
        .{ .tc = .string, .v = .{ .text = "x" }, .hex = "12010000000178" },
        .{ .tc = .object, .v = .{ .blob = &[_]u8{ 1, 2 } }, .hex = "010D53797374656D2E427974655B5D01000000020102" },
    };

    for (cases) |c| {
        const cols = [_]Column{.{ .name = "c", .type = c.tc }};
        const row = [_]Value{c.v};
        const rows = [_][]const Value{&row};
        const bytes = try encodeAlloc(a, &cols, &rows);
        defer a.free(bytes);

        // 头部（魔数+版本+保留位+列数+列名+TypeCode）与值一起逐字节比对
        const full_hex = try std.fmt.allocPrint(a, "{s}{s}", .{ head, c.hex });
        defer a.free(full_hex);
        try expectSameHex(full_hex, bytes);
    }
}

test "DbTable v3：黄金字节可解回原值" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // 把黄金十六进制转成字节（解码方向用真实 C# 产出的字节，而不是自己编码的）
    var bytes: [golden_8col_hex.len / 2]u8 = undefined;
    for (0..bytes.len) |i| {
        const hi = try hexVal(golden_8col_hex[i * 2]);
        const lo = try hexVal(golden_8col_hex[i * 2 + 1]);
        bytes[i] = (hi << 4) | lo;
    }

    const t = try decodeAlloc(arena.allocator(), &bytes);
    try std.testing.expectEqual(@as(usize, 8), t.columns.len);
    try std.testing.expectEqualStrings("Id", t.columns[0]);
    try std.testing.expectEqualStrings("Nothing", t.columns[7]);
    try std.testing.expectEqual(TypeCode.int64, t.types[0]);
    try std.testing.expectEqual(TypeCode.string, t.types[1]);
    try std.testing.expectEqual(TypeCode.object, t.types[6]);
    try std.testing.expectEqual(@as(usize, 2), t.rows.len);

    const r0 = t.rows[0];
    try std.testing.expectEqual(@as(i64, 42), r0[0].int);
    try std.testing.expectEqualStrings("中文abc", r0[1].text);
    try std.testing.expect(r0[2].boolean);
    try std.testing.expectEqual(@as(i128, 1234), r0[3].decimal.mantissa);
    try std.testing.expectEqual(@as(u8, 2), r0[3].decimal.scale);
    try std.testing.expectEqual(@as(f64, 1.5), r0[4].float);
    try std.testing.expectEqual(@as(i32, 2026), r0[5].datetime.year);
    try std.testing.expectEqual(@as(u8, 11), r0[5].datetime.month);
    try std.testing.expectEqual(@as(u8, 12), r0[5].datetime.day);
    try std.testing.expectEqual(@as(u8, 8), r0[5].datetime.hour);
    try std.testing.expectEqual(@as(u32, 123_000_000), r0[5].datetime.nanos);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, r0[6].blob);
    try std.testing.expectEqual(@as(i64, 7), r0[7].int);

    const r1 = t.rows[1];
    try std.testing.expectEqual(@as(i64, -1), r1[0].int);
    try std.testing.expectEqualStrings("", r1[1].text);
    try std.testing.expect(!r1[2].boolean);
    try std.testing.expectEqual(@as(i128, -1), r1[3].decimal.mantissa);
    try std.testing.expectEqual(@as(f64, -2.25), r1[4].float);
    try std.testing.expectEqual(@as(i32, 1970), r1[5].datetime.year);
    try std.testing.expectEqual(@as(usize, 0), r1[6].blob.len);
    try std.testing.expectEqual(@as(i64, 0), r1[7].int);
}

test "DbTable v3：NULL 按 C# 口径写成类型默认值" {
    const a = std.testing.allocator;
    const row = Row{
        .names = &[_][]const u8{"A"},
        .values = &[_]Value{.null},
    };
    const rows = [_]Row{row};
    // 全 NULL 的列推断成 string → 空串
    const bytes = try encodeRowsAlloc(a, &rows);
    defer a.free(bytes);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = try decodeAlloc(arena.allocator(), bytes);
    try std.testing.expectEqual(TypeCode.string, t.types[0]);
    try std.testing.expectEqualStrings("", t.rows[0][0].text);
}

test "DbTable v3：坏魔数/未知 TypeCode 明确报错（不猜）" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    try std.testing.expectError(Error.BadMagic, decodeAlloc(arena.allocator(), "NewLifeDbTable\x04\x00\x00"));
    try std.testing.expectError(Error.BadMagic, decodeAlloc(arena.allocator(), "NotATable!!!!\x03\x00\x00"));

    // 魔数正确但列类型是 2（Char，本格式不处理）→ 明确报 UnsupportedTypeCode
    const head = "NewLifeDbTable\x03\x00\x01\x01c";
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..head.len], head);
    buf[head.len] = 2; // 未知 TypeCode
    try std.testing.expectError(Error.UnsupportedTypeCode, decodeAlloc(arena.allocator(), buf[0 .. head.len + 1]));
}
