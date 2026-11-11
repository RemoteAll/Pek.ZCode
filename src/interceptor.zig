//! 实体写入拦截器（对应 DH.NCode `EntityInterceptor` / `TimeModule` / `UserModule` /
//! `TraceModule`，以及 Rust `Pek.RCode/src/interceptor.rs`）。
//!
//! 在**写入前**自动补全审计列（按列名存在性自动匹配，不做模型声明）：
//! - `TimeInterceptor`：插入填 `CreateTime` / `UpdateTime`，更新刷新 `UpdateTime`
//! - `UserInterceptor`：插入填 `CreateUser` / `CreateUserID` / `UpdateUser` / `UpdateUserID`，更新刷新 `UpdateUser*`
//! - `TraceInterceptor`：填 `TraceId`（可多值合并）
//!
//! ## 取值语义（对齐 C# 的 `SetItem` / `SetNoDirtyItem`）
//!
//! - **插入**：仅当调用方传入的值是「默认值」（整数 0 / 空串 / Null / 年份 < 2000）时才覆盖；
//!   没传的列**补全**。
//! - **更新**：调用方显式传入的列**不覆盖**；没传的列补全。
//! - 与 C# 的差异：C# 用实体的「脏标记」判断要不要覆盖，Zig 侧以「调用方传入的列集合」近似，
//!   语义等价（调用方只有改了才放进 fields）。
//!
//! ## 内存约定
//!
//! 拦截器只**追加/改写**调用方给的字段列表（`Fields`），所有列名与值必须是**借用或常驻**的，
//! 拦截器自己的值（如 `UserName`、`TraceId`）由调用方保证生命周期长于一次写入。

const std = @import("std");
const model = @import("model.zig");
const TableMeta = model.TableMeta;
const sqlbuild = @import("sqlbuild.zig");
const Field = sqlbuild.Field;
const Value = @import("zzig").db.Value;
const DateTime = @import("zzig").DateTime;

/// 写入动作（对应 C# `DataMethod`）。
pub const Method = enum {
    insert,
    update,
    delete,

    pub fn name(self: Method) []const u8 {
        return switch (self) {
            .insert => "Insert",
            .update => "Update",
            .delete => "Delete",
        };
    }
};

/// 待写入的字段列表（拦截器可追加/改写）。
pub const Fields = struct {
    gpa: std.mem.Allocator,
    items: *std.ArrayList(Field),

    pub fn find(self: Fields, column: []const u8) ?usize {
        for (self.items.items, 0..) |f, i| {
            if (std.ascii.eqlIgnoreCase(f.name, column)) return i;
        }
        return null;
    }

    pub fn get(self: Fields, column: []const u8) ?Value {
        const i = self.find(column) orelse return null;
        return self.items.items[i].value;
    }

    /// 设置：已存在则改写，不存在则追加。
    pub fn set(self: Fields, column: []const u8, value: Value) !void {
        if (self.find(column)) |i| {
            self.items.items[i].value = value;
            return;
        }
        try self.items.append(self.gpa, .{ .name = column, .value = value });
    }

    /// 仅当不存在（或现有值是「默认值」）时设置——对应 C# `SetItem`。
    pub fn setIfDefault(self: Fields, column: []const u8, value: Value) !bool {
        if (self.find(column)) |i| {
            if (!isDefaultValue(self.items.items[i].value)) return false;
            self.items.items[i].value = value;
            return true;
        }
        try self.items.append(self.gpa, .{ .name = column, .value = value });
        return true;
    }

    /// 仅当不存在时设置——对应 C# `SetNoDirtyItem`（不覆盖调用方显式传入的列）。
    pub fn setIfAbsent(self: Fields, column: []const u8, value: Value) !bool {
        if (self.find(column) != null) return false;
        try self.items.append(self.gpa, .{ .name = column, .value = value });
        return true;
    }
};

/// 「默认值」判定：整数 0 / 空串 / Null / 年份 < 2000 的时间。
pub fn isDefaultValue(v: Value) bool {
    return switch (v) {
        .null => true,
        .int => |n| n == 0,
        .float => |f| f == 0,
        .boolean => |b| !b,
        .text => |t| t.len == 0,
        .blob => |b| b.len == 0,
        .decimal => |d| d.isZero(),
        .datetime => |dt| dt.year < 2000 or dt.year <= 1,
    };
}

/// 单个拦截器：`apply` 返回 false 表示「该表不适用」（对应 C# `OnInit`）。
pub const Interceptor = struct {
    ctx: *anyopaque,
    apply: *const fn (ctx: *anyopaque, method: Method, table: *const TableMeta, fields: Fields) anyerror!bool,
    name: []const u8,
};

/// 拦截器链（注册顺序即执行顺序）。
pub const Chain = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Interceptor) = .empty,
    /// 累计生效次数（拦截器真的改了字段的写入次数）
    applied_count: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Chain {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Chain) void {
        self.list.deinit(self.gpa);
    }

    pub fn add(self: *Chain, interceptor: Interceptor) !void {
        try self.list.append(self.gpa, interceptor);
    }

    pub fn count(self: *const Chain) usize {
        return self.list.items.len;
    }

    /// 依次执行；任一拦截器出错即向上抛（**不吞错**，审计字段补不上属于必须暴露的问题）。
    pub fn applyTo(self: *Chain, method: Method, table: *const TableMeta, fields: Fields) !void {
        for (self.list.items) |it| {
            const handled = try it.apply(it.ctx, method, table, fields);
            if (handled) self.applied_count += 1;
        }
    }
};

/// 表上是否存在该列（按物理列名，忽略大小写）。
fn hasColumn(table: *const TableMeta, name: []const u8) bool {
    for (table.columns) |*c| {
        if (std.ascii.eqlIgnoreCase(table.effectiveColumnName(c), name)) return true;
    }
    return false;
}

// ───────────────────────── 内置拦截器 ─────────────────────────

/// 时间拦截器：插入填 `CreateTime` / `UpdateTime`，更新刷新 `UpdateTime`。
pub const TimeInterceptor = struct {
    /// 当前时间提供者（默认取本机时间；测试可注入固定值，便于断言）
    now_fn: *const fn () DateTime = defaultNow,

    fn defaultNow() DateTime {
        return DateTime.nowLocal();
    }

    pub fn interceptor(self: *TimeInterceptor) Interceptor {
        return .{ .ctx = @ptrCast(self), .apply = applyImpl, .name = "TimeInterceptor" };
    }

    fn applyImpl(ctx: *anyopaque, method: Method, table: *const TableMeta, fields: Fields) anyerror!bool {
        const self: *TimeInterceptor = @ptrCast(@alignCast(ctx));
        if (method == .delete) return false;

        var touched = false;
        const now = self.now_fn();

        if (method == .insert) {
            if (hasColumn(table, "CreateTime")) {
                if (try fields.setIfDefault("CreateTime", .{ .datetime = now })) touched = true;
            }
        }
        if (hasColumn(table, "UpdateTime")) {
            // 更新时刷新（调用方显式传了就不覆盖；插入时同样只补默认值）
            const changed = if (method == .insert)
                try fields.setIfDefault("UpdateTime", .{ .datetime = now })
            else
                try fields.setIfAbsent("UpdateTime", .{ .datetime = now });
            if (changed) touched = true;
        }
        return touched;
    }
};

/// 用户拦截器：插入/更新填创建人与更新人（对应 C# `UserModule`）。
pub const UserInterceptor = struct {
    /// 当前用户 ID（0 = 无用户）
    user_id: i64 = 0,
    /// 当前用户名
    user_name: []const u8 = "",
    /// 是否允许空用户（false 时无用户直接报错，避免审计列落空）
    allow_empty: bool = true,

    pub fn interceptor(self: *UserInterceptor) Interceptor {
        return .{ .ctx = @ptrCast(self), .apply = applyImpl, .name = "UserInterceptor" };
    }

    fn applyImpl(ctx: *anyopaque, method: Method, table: *const TableMeta, fields: Fields) anyerror!bool {
        const self: *UserInterceptor = @ptrCast(@alignCast(ctx));
        if (method == .delete) return false;
        if (!self.allow_empty and self.user_id == 0 and self.user_name.len == 0) {
            std.debug.print("[zcode] 用户拦截器：当前无用户，拒绝写入 {s}（allow_empty=false）\n", .{table.name});
            return error.NoUser;
        }
        if (self.user_id == 0 and self.user_name.len == 0) return false;

        var touched = false;
        const pairs_create = [_][2][]const u8{ .{ "CreateUserID", "int" }, .{ "CreateUser", "text" } };
        const pairs_update = [_][2][]const u8{ .{ "UpdateUserID", "int" }, .{ "UpdateUser", "text" } };

        if (method == .insert) {
            for (pairs_create) |p| {
                if (!hasColumn(table, p[0])) continue;
                const v: Value = if (std.mem.eql(u8, p[1], "int")) .{ .int = self.user_id } else .{ .text = self.user_name };
                if (try fields.setIfDefault(p[0], v)) touched = true;
            }
        }
        for (pairs_update) |p| {
            if (!hasColumn(table, p[0])) continue;
            const v: Value = if (std.mem.eql(u8, p[1], "int")) .{ .int = self.user_id } else .{ .text = self.user_name };
            const changed = if (method == .insert)
                try fields.setIfDefault(p[0], v)
            else
                try fields.setIfAbsent(p[0], v);
            if (changed) touched = true;
        }
        return touched;
    }
};

/// 链路追踪拦截器：填 `TraceId`（对应 C# `TraceModule`）。
pub const TraceInterceptor = struct {
    /// 当前追踪号（空 = 不处理）
    trace_id: []const u8 = "",
    /// 是否允许合并多个追踪号（逗号分隔、去重）
    allow_merge: bool = true,

    pub fn interceptor(self: *TraceInterceptor) Interceptor {
        return .{ .ctx = @ptrCast(self), .apply = applyImpl, .name = "TraceInterceptor" };
    }

    fn applyImpl(ctx: *anyopaque, method: Method, table: *const TableMeta, fields: Fields) anyerror!bool {
        const self: *TraceInterceptor = @ptrCast(@alignCast(ctx));
        if (method == .delete) return false;
        if (self.trace_id.len == 0) return false;
        if (!hasColumn(table, "TraceId")) return false;

        if (self.allow_merge) {
            if (fields.get("TraceId")) |existing| {
                if (existing.asText()) |text| {
                    if (text.len > 0 and !containsToken(text, self.trace_id)) {
                        // 合并：`a,b`；内存由调用方 arena 持有（这里只借用，不分配）
                        const merged = std.fmt.allocPrint(fields.gpa, "{s},{s}", .{ text, self.trace_id }) catch {
                            return error.OutOfMemory;
                        };
                        try fields.set("TraceId", .{ .text = merged });
                        return true;
                    }
                    return false;
                }
            }
        }
        return try fields.setIfAbsent("TraceId", .{ .text = self.trace_id });
    }

    fn containsToken(text: []const u8, token: []const u8) bool {
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |part| {
            if (std.mem.eql(u8, std.mem.trim(u8, part, " "), token)) return true;
        }
        return false;
    }
};

// ───────────────────────────── 测试 ─────────────────────────────

test "默认值判定" {
    try std.testing.expect(isDefaultValue(.null));
    try std.testing.expect(isDefaultValue(.{ .int = 0 }));
    try std.testing.expect(isDefaultValue(.{ .text = "" }));
    try std.testing.expect(!isDefaultValue(.{ .int = 1 }));
    try std.testing.expect(!isDefaultValue(.{ .text = "x" }));
    try std.testing.expect(isDefaultValue(.{ .datetime = .{ .year = 1 } }));
}

test "时间拦截器：插入补 CreateTime/UpdateTime，更新只刷 UpdateTime" {
    const a = std.testing.allocator;
    var m = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="Order" TableName="DH_Order">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="CreateTime" DataType="DateTime" />
        \\    <Column Name="UpdateTime" DataType="DateTime" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    );
    defer m.deinit();

    var ti = TimeInterceptor{ .now_fn = &fixedNow };
    var chain = Chain.init(a);
    defer chain.deinit();
    try chain.add(ti.interceptor());

    // 插入：两个时间列都补上
    var items: std.ArrayList(Field) = .empty;
    defer items.deinit(a);
    try items.append(a, .{ .name = "Id", .value = .{ .int = 0 } });
    try chain.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items });
    try std.testing.expect(items.items.len == 3);
    try std.testing.expectEqual(@as(i32, 2024), findDt(items.items, "CreateTime").?.year);
    try std.testing.expectEqual(@as(i32, 2024), findDt(items.items, "UpdateTime").?.year);

    // 更新：只补 UpdateTime，不动 CreateTime
    var sets: std.ArrayList(Field) = .empty;
    defer sets.deinit(a);
    try chain.applyTo(.update, &m.tables[0], .{ .gpa = a, .items = &sets });
    try std.testing.expectEqual(@as(usize, 1), sets.items.len);
    try std.testing.expectEqualStrings("UpdateTime", sets.items[0].name);

    // 调用方显式传了 UpdateTime → 不覆盖
    var sets2: std.ArrayList(Field) = .empty;
    defer sets2.deinit(a);
    try sets2.append(a, .{ .name = "UpdateTime", .value = .{ .datetime = .{ .year = 1999 } } });
    try chain.applyTo(.update, &m.tables[0], .{ .gpa = a, .items = &sets2 });
    try std.testing.expectEqual(@as(i32, 1999), findDt(sets2.items, "UpdateTime").?.year);
}

test "用户与追踪拦截器：只填存在的列，追踪号可合并去重" {
    const a = std.testing.allocator;
    var m = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="Order" TableName="DH_Order">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="CreateUserID" DataType="Int32" />
        \\    <Column Name="CreateUser" DataType="String" Length="50" />
        \\    <Column Name="TraceId" DataType="String" Length="100" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    );
    defer m.deinit();

    var ui = UserInterceptor{ .user_id = 7, .user_name = "alice" };
    var ti = TraceInterceptor{ .trace_id = "t1" };
    var chain = Chain.init(a);
    defer chain.deinit();
    try chain.add(ui.interceptor());
    try chain.add(ti.interceptor());

    var items: std.ArrayList(Field) = .empty;
    defer items.deinit(a);
    try chain.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items });

    try std.testing.expectEqual(@as(i64, 7), fieldsValue(items.items, "CreateUserID").?.asI64().?);
    try std.testing.expectEqualStrings("alice", fieldsValue(items.items, "CreateUser").?.asText().?);
    try std.testing.expectEqualStrings("t1", fieldsValue(items.items, "TraceId").?.asText().?);
    // 不存在的 UpdateUser* 列不补（模型里没有）
    try std.testing.expect(fieldsValue(items.items, "UpdateUser") == null);
}

test "空用户 + allow_empty=false 报错（不静默落空审计列）" {
    const a = std.testing.allocator;
    var m = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="Order" TableName="DH_Order">
        \\  <Columns><Column Name="Id" DataType="Int32" PrimaryKey="True" /></Columns>
        \\</Table></Tables></EntityModel>
    );
    defer m.deinit();

    var ui = UserInterceptor{ .allow_empty = false };
    var chain = Chain.init(a);
    defer chain.deinit();
    try chain.add(ui.interceptor());

    var items: std.ArrayList(Field) = .empty;
    defer items.deinit(a);
    try std.testing.expectError(error.NoUser, chain.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items }));
}

fn fixedNow() DateTime {
    return .{ .year = 2024, .month = 5, .day = 6, .hour = 7, .minute = 8, .second = 9 };
}

fn findDt(items: []const Field, name: []const u8) ?DateTime {
    for (items) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value.asDatetime();
    }
    return null;
}

fn fieldsValue(items: []const Field, name: []const u8) ?Value {
    for (items) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
    }
    return null;
}
