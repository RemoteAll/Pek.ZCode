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

/// 是否存在指定名字的**字符串**列（对应 C# `OnInit` 里的 `fi.Type == typeof(String)`）。
///
/// `CreateIP` / `UpdateIP` 是字符串列才处理；同名的整数列（误建）不应被写入 IP 文本。
fn hasStringColumn(table: *const TableMeta, name: []const u8) bool {
    for (table.columns) |*c| {
        if (std.ascii.eqlIgnoreCase(table.effectiveColumnName(c), name) and c.data_type == .string) return true;
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

/// IP 拦截器：插入填 `CreateIP` / `UpdateIP`，更新刷新 `UpdateIP`（对应 C# `IPModule` / `IPInterceptor`）。
///
/// 口径逐条照 C#：
/// - 只对**存在** `CreateIP` / `UpdateIP` 列的表生效（对应 `OnInit`）；
/// - 插入时用「默认值才覆盖」的 `SetItem` 语义，更新时用「调用方没传才补」的 `SetNoDirtyItem` 语义；
/// - **只在插入时**回退到本机 IP（C# 注释：更新时回退会把原来的更新 IP 覆盖成本机 IP）；
/// - IP 带协议前缀（`http://host:port`）时**剥掉前缀**再落库；
/// - `allow_empty = false` 且确实没 IP 时**什么都不做**（C# 的 `else if (AllowEmpty)`）；
/// - `delete` 一律不处理。
///
/// 与 C# 的差异：C# 直接调 `NetHelper.MyIP()` 探测本机网卡，Zig 侧改为**由调用方注入 `fallback_fn`**——
/// 库不主动做网络/网卡探测（亿级场景下隐式 IO 是大忌），要这个行为由接入方传进来。
pub const IpInterceptor = struct {
    /// 当前请求 IP（空 = 无 IP 信息）
    ip: []const u8 = "",
    /// 无 IP 时是否允许把 `UpdateIP` 写成空（对应 C# `AllowEmpty`）
    allow_empty: bool = true,
    /// 插入且无 IP 时的兜底取值（对应 C# 的 `NetHelper.MyIP()`，默认不探测）
    fallback_fn: ?*const fn (gpa: std.mem.Allocator) ?[]const u8 = null,

    pub fn interceptor(self: *IpInterceptor) Interceptor {
        return .{ .ctx = @ptrCast(self), .apply = applyImpl, .name = "IpInterceptor" };
    }

    fn applyImpl(ctx: *anyopaque, method: Method, table: *const TableMeta, fields: Fields) anyerror!bool {
        const self: *IpInterceptor = @ptrCast(@alignCast(ctx));
        if (method == .delete) return false;

        const has_create = hasStringColumn(table, "CreateIP");
        const has_update = hasStringColumn(table, "UpdateIP");
        if (!has_create and !has_update) return false;

        var ip = self.ip;
        if (ip.len == 0 and method == .insert) {
            if (self.fallback_fn) |f| {
                if (f(fields.gpa)) |v| ip = v;
            }
        }

        if (ip.len > 0) {
            ip = stripScheme(ip);
            var touched = false;
            switch (method) {
                .insert => {
                    if (has_create) {
                        if (try fields.setIfDefault("CreateIP", .{ .text = ip })) touched = true;
                    }
                    if (has_update) {
                        if (try fields.setIfDefault("UpdateIP", .{ .text = ip })) touched = true;
                    }
                },
                .update => {
                    if (has_update) {
                        if (try fields.setIfAbsent("UpdateIP", .{ .text = ip })) touched = true;
                    }
                },
                .delete => {},
            }
            return touched;
        }

        // 没有 IP：只有明确允许清空时才动 UpdateIP（C# `else if (AllowEmpty) SetNoDirtyItem(...)`）
        if (self.allow_empty and has_update) {
            return try fields.setIfAbsent("UpdateIP", .{ .text = "" });
        }
        return false;
    }
};

/// 剥掉 `scheme://` 前缀（C# `IPModule`：`ip.IndexOf("://")` 之后的部分）
fn stripScheme(ip: []const u8) []const u8 {
    const p = std.mem.indexOf(u8, ip, "://") orelse return ip;
    return ip[p + 3 ..];
}

/// GUID 拦截器：插入时给**指定列**填新 GUID（对应 C# `EntityOperate.AutoSetGuidField`）。
///
/// C# 的语义很窄，照抄：
/// - 只针对实体上**指定的那一个字段**（`Mask.AutoSetGuidField = _.Guid`），不是"所有 Guid 列"；
/// - **只在插入**时补；调用方已经给了值就**不动**（C# 判断 `!entity.IsDirty(fi.Name)`）；
/// - 没有指定列名时不生效。
///
/// 与 C# 的一处差异：C# 是"没脏就写"，Zig 拿到的是字段列表，判定改成
/// 「没传 / 传了空串 / 传了非法 GUID 文本」→ 补新值；传了合法 GUID 视为调用方有意为之。
pub const GuidInterceptor = struct {
    /// 要自动填值的列名（空 = 不生效）
    column: []const u8 = "",
    /// 生成器（默认 `zzig.Guid.guidAlloc`；测试可注入固定值）
    gen_fn: *const fn (gpa: std.mem.Allocator) anyerror![]const u8 = defaultGuid,

    fn defaultGuid(gpa: std.mem.Allocator) anyerror![]const u8 {
        return @import("zzig").Guid.guidAlloc(gpa);
    }

    pub fn interceptor(self: *GuidInterceptor) Interceptor {
        return .{ .ctx = @ptrCast(self), .apply = applyImpl, .name = "GuidInterceptor" };
    }

    fn applyImpl(ctx: *anyopaque, method: Method, table: *const TableMeta, fields: Fields) anyerror!bool {
        const self: *GuidInterceptor = @ptrCast(@alignCast(ctx));
        if (self.column.len == 0) return false;
        // 只在插入时补；更新时保留原值
        if (method != .insert) return false;

        const col = table.column(self.column) orelse return false;
        if (col.data_type != .guid) {
            std.debug.print(
                "[zcode] GUID 拦截器：表 {s} 的列 {s} 不是 Guid 类型（实际 {s}），跳过\n",
                .{ table.name, self.column, col.data_type.name() },
            );
            return false;
        }

        // 已经有合法 GUID 就尊重调用方的值
        if (fields.get(col.name)) |existing| {
            if (existing.asText()) |text| {
                if (@import("zzig").Guid.isValid(text)) return false;
            }
        }

        const generated = try self.gen_fn(fields.gpa);
        try fields.set(col.name, .{ .text = generated });
        return true;
    }
};

/// 标准审计链（对应 C# 代码生成器给每个实体加的那四行 `Meta.Interceptors.Add(...)`）。
/// C# 的 `{Name}.Biz.cs` 静态构造里固定注册 `UserInterceptor` / `TimeInterceptor` /
/// `IPInterceptor` / `TraceInterceptor` 四个，这里是同口径的一体化封装：
///
/// ```zig
/// var std = zcode.interceptor.Standard{ .user = .{ .user_id = 7, .user_name = "alice" } };
/// defer std.deinit();
/// try std.addTo(&chain);   // User → Time → IP → Trace（与 C# 注册顺序一致）
/// ```
///
/// 拦截器实例**存在 `Standard` 内部**（链只持有指针），所以 `Standard` 的生命周期必须长于链。
pub const Standard = struct {
    user: UserInterceptor = .{},
    time: TimeInterceptor = .{},
    ip: IpInterceptor = .{},
    trace: TraceInterceptor = .{},

    /// 按 C# 的顺序挂到链上。
    pub fn addTo(self: *Standard, chain: *Chain) !void {
        try chain.add(self.user.interceptor());
        try chain.add(self.time.interceptor());
        try chain.add(self.ip.interceptor());
        try chain.add(self.trace.interceptor());
    }

    /// 目前四个拦截器都不持有需要释放的资源；保留 `deinit` 是为了以后加字段时不破坏调用方。
    pub fn deinit(self: *Standard) void {
        _ = self;
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

test "IP 拦截器：插入补 CreateIP/UpdateIP，更新只刷 UpdateIP，协议前缀剥掉" {
    const a = std.testing.allocator;
    var m = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="Order" TableName="DH_Order">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="CreateIP" DataType="String" Length="50" />
        \\    <Column Name="UpdateIP" DataType="String" Length="50" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    );
    defer m.deinit();

    var ii = IpInterceptor{ .ip = "http://10.0.0.9:8080", .allow_empty = false };
    var chain = Chain.init(a);
    defer chain.deinit();
    try chain.add(ii.interceptor());

    // 插入：两列都补，且剥掉 `http://`
    var items: std.ArrayList(Field) = .empty;
    defer items.deinit(a);
    try chain.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items });
    try std.testing.expectEqualStrings("10.0.0.9:8080", fieldsValue(items.items, "CreateIP").?.asText().?);
    try std.testing.expectEqualStrings("10.0.0.9:8080", fieldsValue(items.items, "UpdateIP").?.asText().?);

    // 调用方显式传了 CreateIP → 插入不覆盖（SetItem 只覆盖默认值）
    var items2: std.ArrayList(Field) = .empty;
    defer items2.deinit(a);
    try items2.append(a, .{ .name = "CreateIP", .value = .{ .text = "1.2.3.4" } });
    try chain.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items2 });
    try std.testing.expectEqualStrings("1.2.3.4", fieldsValue(items2.items, "CreateIP").?.asText().?);

    // 更新：只补 UpdateIP，不动 CreateIP
    var sets: std.ArrayList(Field) = .empty;
    defer sets.deinit(a);
    try chain.applyTo(.update, &m.tables[0], .{ .gpa = a, .items = &sets });
    try std.testing.expectEqual(@as(usize, 1), sets.items.len);
    try std.testing.expectEqualStrings("UpdateIP", sets.items[0].name);
    try std.testing.expectEqualStrings("10.0.0.9:8080", sets.items[0].value.asText().?);

    // 更新时调用方已传 UpdateIP → 不覆盖
    var sets2: std.ArrayList(Field) = .empty;
    defer sets2.deinit(a);
    try sets2.append(a, .{ .name = "UpdateIP", .value = .{ .text = "5.6.7.8" } });
    try chain.applyTo(.update, &m.tables[0], .{ .gpa = a, .items = &sets2 });
    try std.testing.expectEqual(@as(usize, 1), sets2.items.len);
    try std.testing.expectEqualStrings("5.6.7.8", sets2.items[0].value.asText().?);

    // delete 一律不处理
    var dels: std.ArrayList(Field) = .empty;
    defer dels.deinit(a);
    try chain.applyTo(.delete, &m.tables[0], .{ .gpa = a, .items = &dels });
    try std.testing.expectEqual(@as(usize, 0), dels.items.len);
}

test "IP 拦截器：无 IP 时 allow_empty 决定是否清空 UpdateIP；插入可用注入的兜底探测" {
    const a = std.testing.allocator;
    var m = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="Order" TableName="DH_Order">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" PrimaryKey="True" />
        \\    <Column Name="UpdateIP" DataType="String" Length="50" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    );
    defer m.deinit();

    // allow_empty = false：没 IP 就不动
    var strict = IpInterceptor{ .allow_empty = false };
    var chain = Chain.init(a);
    defer chain.deinit();
    try chain.add(strict.interceptor());

    var items: std.ArrayList(Field) = .empty;
    defer items.deinit(a);
    try chain.applyTo(.update, &m.tables[0], .{ .gpa = a, .items = &items });
    try std.testing.expectEqual(@as(usize, 0), items.items.len);

    // allow_empty = true：把 UpdateIP 写成空（C# `SetNoDirtyItem(UpdateIP, ip)` 且 ip 为空）
    var loose = IpInterceptor{ .allow_empty = true };
    var chain2 = Chain.init(a);
    defer chain2.deinit();
    try chain2.add(loose.interceptor());

    var items2: std.ArrayList(Field) = .empty;
    defer items2.deinit(a);
    try chain2.applyTo(.update, &m.tables[0], .{ .gpa = a, .items = &items2 });
    try std.testing.expectEqualStrings("", fieldsValue(items2.items, "UpdateIP").?.asText().?);

    // 插入时的兜底探测（对应 C# `NetHelper.MyIP()`，这里由调用方注入）
    var with_fallback = IpInterceptor{ .fallback_fn = &fakeMyIp };
    var chain3 = Chain.init(a);
    defer chain3.deinit();
    try chain3.add(with_fallback.interceptor());

    var items3: std.ArrayList(Field) = .empty;
    defer items3.deinit(a);
    try chain3.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items3 });
    try std.testing.expectEqualStrings("192.168.1.10", fieldsValue(items3.items, "UpdateIP").?.asText().?);

    // 更新时**不**走兜底（否则会把原来的更新 IP 覆盖成本机 IP，C# 注释明确这一点）
    // 注意：这里必须 `allow_empty = false`，否则按 C# 的 `else if (AllowEmpty)` 会把 UpdateIP 写成空
    var with_fallback2 = IpInterceptor{ .fallback_fn = &fakeMyIp, .allow_empty = false };
    var chain4 = Chain.init(a);
    defer chain4.deinit();
    try chain4.add(with_fallback2.interceptor());

    var items4: std.ArrayList(Field) = .empty;
    defer items4.deinit(a);
    try chain4.applyTo(.update, &m.tables[0], .{ .gpa = a, .items = &items4 });
    try std.testing.expectEqual(@as(usize, 0), items4.items.len);
}

fn fakeMyIp(gpa: std.mem.Allocator) ?[]const u8 {
    _ = gpa;
    return "192.168.1.10";
}

test "GUID 拦截器：插入补指定列，已有合法值/更新都不动，非 Guid 列跳过" {
    // 生成值是「由调用方 allocator 持有」的（真实用法里是请求 arena），这里用 arena 统一回收
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="Order" TableName="DH_Order">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="Guid" DataType="Guid" />
        \\    <Column Name="Code" DataType="String" Length="50" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    );
    defer m.deinit();

    var gi = GuidInterceptor{ .column = "Guid", .gen_fn = &fixedGuid };
    var chain = Chain.init(a);
    defer chain.deinit();
    try chain.add(gi.interceptor());

    // 插入：没传 → 补一个新 GUID
    var items: std.ArrayList(Field) = .empty;
    defer items.deinit(a);
    try items.append(a, .{ .name = "Code", .value = .{ .text = "k1" } });
    try chain.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items });
    const filled = fieldsValue(items.items, "Guid").?.asText().?;
    try std.testing.expectEqualStrings("11111111-2222-4333-8444-555555555555", filled);
    try std.testing.expect(std.mem.indexOfScalar(u8, filled, '-') != null);

    // 插入：调用方给了合法 GUID → 尊重原值
    var items2: std.ArrayList(Field) = .empty;
    defer items2.deinit(a);
    try items2.append(a, .{ .name = "Guid", .value = .{ .text = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" } });
    try chain.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items2 });
    try std.testing.expectEqualStrings("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", fieldsValue(items2.items, "Guid").?.asText().?);

    // 插入：给了空串（= 默认值）→ 覆盖成新 GUID
    var items3: std.ArrayList(Field) = .empty;
    defer items3.deinit(a);
    try items3.append(a, .{ .name = "Guid", .value = .{ .text = "" } });
    try chain.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items3 });
    try std.testing.expectEqualStrings("11111111-2222-4333-8444-555555555555", fieldsValue(items3.items, "Guid").?.asText().?);

    // 更新：一律不动
    var sets: std.ArrayList(Field) = .empty;
    defer sets.deinit(a);
    try chain.applyTo(.update, &m.tables[0], .{ .gpa = a, .items = &sets });
    try std.testing.expectEqual(@as(usize, 0), sets.items.len);

    // 列不是 Guid 类型 → 跳过（配置写错时明确打印，不静默写坏数据）
    var bad = GuidInterceptor{ .column = "Code", .gen_fn = &fixedGuid };
    var chain2 = Chain.init(a);
    defer chain2.deinit();
    try chain2.add(bad.interceptor());
    var items4: std.ArrayList(Field) = .empty;
    defer items4.deinit(a);
    try chain2.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items4 });
    try std.testing.expectEqual(@as(usize, 0), items4.items.len);
}

fn fixedGuid(gpa: std.mem.Allocator) anyerror![]const u8 {
    return gpa.dupe(u8, "11111111-2222-4333-8444-555555555555");
}

test "标准审计链：一次挂上 User/Time/IP/Trace，四个审计列都补齐" {
    const a = std.testing.allocator;
    var m = try model.EntityModel.parse(a,
        \\<EntityModel><Tables><Table Name="Order" TableName="DH_Order">
        \\  <Columns>
        \\    <Column Name="Id" DataType="Int32" Identity="True" PrimaryKey="True" />
        \\    <Column Name="CreateTime" DataType="DateTime" />
        \\    <Column Name="UpdateTime" DataType="DateTime" />
        \\    <Column Name="CreateUserID" DataType="Int32" />
        \\    <Column Name="CreateUser" DataType="String" Length="50" />
        \\    <Column Name="UpdateUserID" DataType="Int32" />
        \\    <Column Name="UpdateUser" DataType="String" Length="50" />
        \\    <Column Name="CreateIP" DataType="String" Length="50" />
        \\    <Column Name="UpdateIP" DataType="String" Length="50" />
        \\    <Column Name="TraceId" DataType="String" Length="100" />
        \\  </Columns>
        \\</Table></Tables></EntityModel>
    );
    defer m.deinit();

    var std_chain = Standard{
        .user = .{ .user_id = 7, .user_name = "alice", .allow_empty = false },
        .time = .{ .now_fn = &fixedNow },
        .ip = .{ .ip = "10.0.0.9", .allow_empty = false },
        .trace = .{ .trace_id = "t1" },
    };
    defer std_chain.deinit();

    var chain = Chain.init(a);
    defer chain.deinit();
    try std_chain.addTo(&chain);
    try std.testing.expectEqual(@as(usize, 4), chain.list.items.len);

    var items: std.ArrayList(Field) = .empty;
    defer items.deinit(a);
    try chain.applyTo(.insert, &m.tables[0], .{ .gpa = a, .items = &items });

    try std.testing.expectEqual(@as(i32, 2024), findDt(items.items, "CreateTime").?.year);
    try std.testing.expectEqual(@as(i32, 2024), findDt(items.items, "UpdateTime").?.year);
    try std.testing.expectEqual(@as(i64, 7), fieldsValue(items.items, "CreateUserID").?.asI64().?);
    try std.testing.expectEqualStrings("alice", fieldsValue(items.items, "CreateUser").?.asText().?);
    try std.testing.expectEqualStrings("10.0.0.9", fieldsValue(items.items, "CreateIP").?.asText().?);
    try std.testing.expectEqualStrings("10.0.0.9", fieldsValue(items.items, "UpdateIP").?.asText().?);
    try std.testing.expectEqualStrings("t1", fieldsValue(items.items, "TraceId").?.asText().?);
}
