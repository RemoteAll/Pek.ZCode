//! 多租户数据隔离（≂ C# `Membership/ITenantSource.cs`：`ITenantScope` / `TenantContext` /
//! `TenantSourceHelper.ApplyTenant` / `TenantInterceptor`）。
//!
//! ## 与 C# 的差异（有意，且是为了不出数据越权）
//!
//! 1. **没有隐式「当前租户」**：C# 用 `AsyncLocal<TenantContext>` 存当前租户，调用点完全看不见；
//!    本仓要求**显式传 `tenant_id`**。理由：本库是同步多线程模型，一个线程处理一个请求，
//!    隐式当前值一旦漏设/漏清，A 租户的请求就会读到 B 租户的数据——这类串味是**静默数据越权**，
//!    比「多点一次参数」贵得多。请求级上下文请由服务层（如 `dbservice`）自己持有 `Context` 往下传。
//! 2. **更新/删除的租户校验走 SQL 条件，不靠拦截器读行**：C# 的 `TenantInterceptor` 能在
//!    `OnUpdate/OnDelete` 里读整行再比对；本库拦截器只拿得到「要写的字段」，读不到行。
//!    所以这里约定：**查询、更新、删除统一用 `applyTenant` 把 `TenantId = ?` 加进 WHERE** ——
//!    这是 SQL 层保证，原子且不多一次查询，比「先读再比」更可靠。
//! 3. 插入时补租户由拦截器负责（`Interceptor`），与 C# `OnCreate` 同口径。

const std = @import("std");
const TableMeta = @import("../model.zig").TableMeta;
const Value = @import("zzig").db.Value;
const Where = @import("../query.zig").Where;
const interceptor = @import("../interceptor.zig");

/// 租户列名（C# `nameof(ITenantScope.TenantId)`）。
pub const field_name = "TenantId";

pub const Error = error{
    /// 要写入的行带了**别的**租户标识（不是当前租户）
    TenantMismatch,
};

/// 租户上下文（≂ C# `TenantContext`）。
///
/// `tenant_id = 0` 表示「管理后台，不进入任何租户」（C# 同样是 0），此时不做隔离。
pub const Context = struct {
    tenant_id: i32 = 0,

    pub fn isActive(self: Context) bool {
        return self.tenant_id > 0;
    }

    /// 从上下文取租户值（给 `applyTenant` 用）。
    pub fn value(self: Context) Value {
        return .{ .int = self.tenant_id };
    }
};

/// 给条件补租户约束（≂ C# `TenantSourceHelper.ApplyTenant`）。
///
/// - `tenant_id <= 0` → 不加（管理后台看全部）；
/// - 表里没有 `TenantId` 列 → 不加（C# `GetTenantField` 为 null 时同样返回原 where）；
/// - 返回 true 表示**真的加了**条件。
///
/// **查询、更新、删除都用它**：更新/删除时它就是租户边界（不需要先读行再比）。
pub fn applyTenant(w: *Where, table: *const TableMeta, tenant_id: i32) !bool {
    if (tenant_id <= 0) return false;
    const col = table.column(field_name) orelse return false;
    _ = try w.eq(table.effectiveColumnName(col), .{ .int = tenant_id });
    return true;
}

/// 租户拦截器（≂ C# `TenantInterceptor` 的 `OnCreate` 部分）。
///
/// 只做**插入补齐**：字段里没有 `TenantId`（或值是默认值）→ 填当前租户；
/// 已经带着**别人的**租户 → `error.TenantMismatch`（不让调用方“顺手”往别的租户写数据）。
/// 更新/删除不走这里，用 `applyTenant` 加 SQL 条件。
pub const Interceptor = struct {
    /// 当前租户（0 = 管理后台，不处理）
    tenant_id: i32 = 0,
    /// false = 只补，不校验（导入/跨租户运维等场景）
    strict: bool = true,

    pub fn interceptor(self: *Interceptor) interceptor_mod.Interceptor {
        return .{ .ctx = @ptrCast(self), .apply = applyImpl, .name = "TenantInterceptor" };
    }

    fn applyImpl(ctx: *anyopaque, method: interceptor_mod.Method, table: *const TableMeta, fields: interceptor_mod.Fields) anyerror!bool {
        const self: *Interceptor = @ptrCast(@alignCast(ctx));
        if (self.tenant_id <= 0) return false;
        // 更新/删除的租户边界由 `applyTenant` 的 WHERE 保证，这里只管插入
        if (method != .insert) return false;

        const col = table.column(field_name) orelse return false;

        if (fields.get(field_name)) |cur| {
            const got = cur.asI64() orelse 0;
            if (got == @as(i64, self.tenant_id)) return false; // 已经是当前租户，不动
            if (self.strict and got != 0) return Error.TenantMismatch;
        }
        _ = try fields.set(col.name, .{ .int = self.tenant_id });
        return true;
    }
};

const interceptor_mod = interceptor;

// ── 测试 ──────────────────────────────────────────────────────────────

const test_model = @import("../model.zig");

fn testTable(comptime with_tenant: bool) test_model.TableMeta {
    if (with_tenant) {
        return .{
            .name = "Order",
            .table_name = "DH_Order",
            .columns = &.{
                .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
                .{ .name = "TenantId", .data_type = .int32 },
                .{ .name = "Code", .data_type = .string },
            },
        };
    }
    return .{
        .name = "Log",
        .table_name = "DH_Log",
        .columns = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true },
            .{ .name = "Code", .data_type = .string },
        },
    };
}

test "租户条件：后台(0)不加 / 无 TenantId 列不加 / 租户>0 补等值" {
    const a = std.testing.allocator;
    const t = testTable(true);
    const no_tenant = testTable(false);

    // 后台：不加
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expect(!try applyTenant(&w, &t, 0));
        try std.testing.expect(w.isEmpty());
    }

    // 表里没有 TenantId：不加（而不是报错）
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expect(!try applyTenant(&w, &no_tenant, 5));
        try std.testing.expect(w.isEmpty());
    }

    // 正常：`TenantId = 5`
    {
        var w = Where.init(a);
        defer w.deinit();
        try std.testing.expect(try applyTenant(&w, &t, 5));

        var params: std.ArrayList(Value) = .empty;
        defer params.deinit(a);
        const sql = try w.renderAlloc(a, .sqlite, &params);
        defer a.free(sql);

        try std.testing.expect(std.mem.indexOf(u8, sql, "TenantId") != null);
        try std.testing.expectEqual(@as(usize, 1), params.items.len);
        try std.testing.expectEqual(@as(i64, 5), params.items[0].asI64().?);
    }
}

test "租户拦截器：插入补 TenantId；带别人的租户 → TenantMismatch；后台不动" {
    const a = std.testing.allocator;
    const t = testTable(true);
    const no_tenant = testTable(false);

    // ① 插入时补齐
    {
        var it = Interceptor{ .tenant_id = 7 };
        const hook = it.interceptor();

        var items: std.ArrayList(@import("../sqlbuild.zig").Field) = .empty;
        defer items.deinit(a);
        try items.append(a, .{ .name = "Code", .value = .{ .text = "A1" } });

        const changed = try hook.apply(hook.ctx, .insert, &t, .{ .gpa = a, .items = &items });
        try std.testing.expect(changed);
        // 找到补进去的列值
        var found: ?Value = null;
        for (items.items) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, field_name)) found = f.value;
        }
        try std.testing.expectEqual(@as(i64, 7), found.?.asI64().?);
    }

    // ② 已经带着别的租户 → 拒绝（strict）
    {
        var it = Interceptor{ .tenant_id = 7 };
        const hook = it.interceptor();

        var items: std.ArrayList(@import("../sqlbuild.zig").Field) = .empty;
        defer items.deinit(a);
        try items.append(a, .{ .name = field_name, .value = .{ .int = 9 } });

        try std.testing.expectError(Error.TenantMismatch, hook.apply(hook.ctx, .insert, &t, .{ .gpa = a, .items = &items }));
    }

    // ③ strict = false：允许（导入/运维场景），但仍改写成当前租户
    {
        var it = Interceptor{ .tenant_id = 7, .strict = false };
        const hook = it.interceptor();

        var items: std.ArrayList(@import("../sqlbuild.zig").Field) = .empty;
        defer items.deinit(a);
        try items.append(a, .{ .name = field_name, .value = .{ .int = 9 } });

        try std.testing.expect(try hook.apply(hook.ctx, .insert, &t, .{ .gpa = a, .items = &items }));
        var found: ?Value = null;
        for (items.items) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, field_name)) found = f.value;
        }
        try std.testing.expectEqual(@as(i64, 7), found.?.asI64().?);
    }

    // ④ 后台（tenant_id = 0）→ 完全不碰
    {
        var it = Interceptor{ .tenant_id = 0 };
        const hook = it.interceptor();

        var items: std.ArrayList(@import("../sqlbuild.zig").Field) = .empty;
        defer items.deinit(a);
        try items.append(a, .{ .name = "Code", .value = .{ .text = "A1" } });

        try std.testing.expect(!try hook.apply(hook.ctx, .insert, &t, .{ .gpa = a, .items = &items }));
        try std.testing.expectEqual(@as(usize, 1), items.items.len);
    }

    // ⑤ 表里没有 TenantId → 不碰
    {
        var it = Interceptor{ .tenant_id = 7 };
        const hook = it.interceptor();

        var items: std.ArrayList(@import("../sqlbuild.zig").Field) = .empty;
        defer items.deinit(a);
        try items.append(a, .{ .name = "Code", .value = .{ .text = "A1" } });

        try std.testing.expect(!try hook.apply(hook.ctx, .insert, &no_tenant, .{ .gpa = a, .items = &items }));
    }

    // ⑥ 更新/删除不在拦截器里处理（租户边界由 applyTenant 的 WHERE 保证）
    {
        var it = Interceptor{ .tenant_id = 7 };
        const hook = it.interceptor();

        var items: std.ArrayList(@import("../sqlbuild.zig").Field) = .empty;
        defer items.deinit(a);
        try std.testing.expect(!try hook.apply(hook.ctx, .update, &t, .{ .gpa = a, .items = &items }));
    }
}
