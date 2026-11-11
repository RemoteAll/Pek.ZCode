//! 数据类型系统：与 DH.NCode / XCode 的 `DataType` 名称保持兼容。
//!
//! Model.xml 中 `Column@DataType` 使用 CLR 类型名（`Int32`/`String`/`DateTime` 等），
//! 本模块提供同名枚举与互转；各数据库的具体字段类型见 `dialect.zig`。

const std = @import("std");

pub const DataType = enum {
    boolean,
    byte,
    int16,
    int32,
    int64,
    single,
    double,
    decimal,
    string,
    datetime,
    binary,
    json,

    /// 全部类型（遍历/自检用）。
    pub const all = [_]DataType{
        .boolean, .byte,  .int16, .int32,
        .int64,   .single, .double, .decimal,
        .string,  .datetime, .binary, .json,
    };

    /// 标准名称（与 Model.xml 中的 `DataType` 属性一致）。
    pub fn name(self: DataType) []const u8 {
        return switch (self) {
            .boolean => "Boolean",
            .byte => "Byte",
            .int16 => "Int16",
            .int32 => "Int32",
            .int64 => "Int64",
            .single => "Single",
            .double => "Double",
            .decimal => "Decimal",
            .string => "String",
            .datetime => "DateTime",
            .binary => "Binary",
            .json => "Json",
        };
    }

    /// 从名称解析（宽松：忽略大小写，兼容常见别名）。
    pub fn fromName(text: []const u8) !DataType {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(t, "boolean") or std.ascii.eqlIgnoreCase(t, "bool")) return .boolean;
        if (std.ascii.eqlIgnoreCase(t, "byte")) return .byte;
        if (std.ascii.eqlIgnoreCase(t, "int16") or std.ascii.eqlIgnoreCase(t, "short")) return .int16;
        if (std.ascii.eqlIgnoreCase(t, "int32") or std.ascii.eqlIgnoreCase(t, "int")) return .int32;
        if (std.ascii.eqlIgnoreCase(t, "int64") or std.ascii.eqlIgnoreCase(t, "long") or std.ascii.eqlIgnoreCase(t, "integer")) return .int64;
        if (std.ascii.eqlIgnoreCase(t, "single") or std.ascii.eqlIgnoreCase(t, "float")) return .single;
        if (std.ascii.eqlIgnoreCase(t, "double")) return .double;
        if (std.ascii.eqlIgnoreCase(t, "decimal") or std.ascii.eqlIgnoreCase(t, "currency")) return .decimal;
        if (std.ascii.eqlIgnoreCase(t, "string") or std.ascii.eqlIgnoreCase(t, "text")) return .string;
        if (std.ascii.eqlIgnoreCase(t, "datetime") or std.ascii.eqlIgnoreCase(t, "date") or std.ascii.eqlIgnoreCase(t, "timestamp")) return .datetime;
        if (std.ascii.eqlIgnoreCase(t, "binary") or std.ascii.eqlIgnoreCase(t, "byte[]") or std.ascii.eqlIgnoreCase(t, "blob")) return .binary;
        if (std.ascii.eqlIgnoreCase(t, "json") or std.ascii.eqlIgnoreCase(t, "jsonb")) return .json;
        return error.UnknownDataType;
    }

    /// 是否整数族（含 Byte/Int16/Int32/Int64）。
    pub fn isInteger(self: DataType) bool {
        return switch (self) {
            .byte, .int16, .int32, .int64 => true,
            else => false,
        };
    }

    /// 是否数值族。
    pub fn isNumeric(self: DataType) bool {
        return self.isInteger() or switch (self) {
            .single, .double, .decimal => true,
            else => false,
        };
    }

    /// 对应的 Zig 基础类型名（代码生成与文档用）。
    pub fn zigType(self: DataType) []const u8 {
        return switch (self) {
            .boolean => "bool",
            .byte => "u8",
            .int16 => "i16",
            .int32 => "i32",
            .int64 => "i64",
            .single => "f32",
            .double => "f64",
            .decimal => "zcode.Decimal",
            .string, .json => "[]const u8",
            .datetime => "zcode.DateTime",
            .binary => "[]const u8",
        };
    }
};

test "类型名称往返" {
    for (DataType.all) |t| {
        try std.testing.expectEqual(t, try DataType.fromName(t.name()));
    }
}

test "宽松别名" {
    try std.testing.expectEqual(DataType.int64, try DataType.fromName("Long"));
    try std.testing.expectEqual(DataType.string, try DataType.fromName("text"));
    try std.testing.expectEqual(DataType.binary, try DataType.fromName("byte[]"));
    try std.testing.expectEqual(DataType.json, try DataType.fromName("JSONB"));
    try std.testing.expectError(error.UnknownDataType, DataType.fromName("money2"));
}

test "数值分类" {
    try std.testing.expect(DataType.int32.isInteger());
    try std.testing.expect(DataType.decimal.isNumeric());
    try std.testing.expect(!DataType.string.isNumeric());
    try std.testing.expect(!DataType.json.isNumeric());
}
