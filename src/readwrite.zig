//! 读写分离策略（对应 DH.NCode `ReadWriteStrategy` / Rust `Pek.RCode/src/readwrite.rs`）。
//!
//! ## 与 C# 的对应关系
//!
//! | C# / DH.NCode | 本模块 / `Dal` |
//! |---|---|
//! | `ReadWriteStrategy.TryGet`（轮询选只读连接） | `Dal.readSessionFor(table)` + `Dal` 内部轮询计数 |
//! | `ReadWriteStrategy.IgnoreTables` | `Strategy.setIgnoreTables` / `addIgnoreTable` |
//! | `ReadWriteStrategy.IgnoreTimes` | **不实现**（见下） |
//! | `DbBase.Readonly` / `DAL.SuspendReadOnly` / `ResumeReadOnly` | `Dal.setPrimaryOnly`（全量切主库） |
//!
//! ## 为什么没有「忽略时间段」
//!
//! C# 的 `IgnoreTimes` 用来在「主从延迟高峰时段」强制读主库。它的判定依赖本地时区，
//! 而且主从延迟是**持续**问题、不是时段问题。用 `setPrimaryOnly(true)`（全量切主库）
//! 能覆盖「立即止血」的场景，语义更明确、无时区依赖。
//!
//! ## 只读连接的价值（澄清常见误解）
//!
//! DH.NCode 里没有「表只读」，只有三类只读：**连接只读**（写操作直接报错，防误写）、
//! **字段只读**（只影响代码生成）、**迁移档位只读**（只生成 DDL 不执行）。
//! 真正的性能收益来自**读写分离**：把 SELECT 分流到从库，主库只承担写入。

const std = @import("std");

/// 读写分离策略。
///
/// 线程模型：本库是同步单连接模型，`primary_only` 用普通 `bool`（不是原子）；
/// 若将来引入多线程共享 `Dal`，需要改成原子读写。
pub const Strategy = struct {
    gpa: std.mem.Allocator,
    /// 强制读主库的表（**小写**持有一份，比较时忽略大小写）
    ignore_tables: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 全局开关：true 时所有读都走主库（「临时关闭读写分离」）
    primary_only: bool = false,

    pub fn init(gpa: std.mem.Allocator) Strategy {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Strategy) void {
        for (self.ignore_tables.items) |t| self.gpa.free(t);
        self.ignore_tables.deinit(self.gpa);
        self.primary_only = false;
    }

    /// 覆盖设置忽略表（传空切片即清空）。
    pub fn setIgnoreTables(self: *Strategy, tables: []const []const u8) !void {
        for (self.ignore_tables.items) |t| self.gpa.free(t);
        self.ignore_tables.clearRetainingCapacity();
        for (tables) |t| try self.addIgnoreTable(t);
    }

    /// 运行期追加忽略表（已存在则忽略，保持幂等）。
    pub fn addIgnoreTable(self: *Strategy, table: []const u8) !void {
        if (self.hasIgnoreTable(table)) return;
        try self.ignore_tables.append(self.gpa, try self.gpa.dupe(u8, table));
    }

    /// 移除忽略表，返回是否真的移除了。
    pub fn removeIgnoreTable(self: *Strategy, table: []const u8) bool {
        for (self.ignore_tables.items, 0..) |t, i| {
            if (std.ascii.eqlIgnoreCase(t, table)) {
                self.gpa.free(t);
                _ = self.ignore_tables.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn hasIgnoreTable(self: *const Strategy, table: []const u8) bool {
        for (self.ignore_tables.items) |t| {
            if (std.ascii.eqlIgnoreCase(t, table)) return true;
        }
        return false;
    }

    pub fn ignoredCount(self: *const Strategy) usize {
        return self.ignore_tables.items.len;
    }

    /// 是否强制读主库。
    pub fn isPrimaryOnly(self: *const Strategy) bool {
        return self.primary_only;
    }

    /// 设置是否强制读主库（对应「暂停/恢复读写分离」）。
    pub fn setPrimaryOnly(self: *Strategy, value: bool) void {
        self.primary_only = value;
    }

    /// 该表的读操作是否允许走从库。
    ///
    /// 快路径：没有忽略表且未全局切主库时直接 `true`，不做字符串比较。
    pub fn allowsReplica(self: *const Strategy, table: []const u8) bool {
        if (self.primary_only) return false;
        if (self.ignore_tables.items.len == 0) return true;
        return !self.hasIgnoreTable(table);
    }

    /// 读路径是否真的需要做策略判定（有忽略表或全局切主库）。
    /// 为 `false` 时可跳过所有判定，直接走「轮询从库」。
    pub fn needsCheck(self: *const Strategy) bool {
        return self.primary_only or self.ignore_tables.items.len > 0;
    }
};

test "忽略表判定忽略大小写，且运行期可增删" {
    const a = std.testing.allocator;
    var s = Strategy.init(a);
    defer s.deinit();

    // 无忽略表：快路径放行
    try std.testing.expect(s.allowsReplica("DH_Order"));
    try std.testing.expect(!s.needsCheck());

    try s.setIgnoreTables(&.{ "DH_Order", "DH_Stock" });
    try std.testing.expect(s.needsCheck());
    try std.testing.expect(!s.allowsReplica("dh_order"));
    try std.testing.expect(!s.allowsReplica("DH_Stock"));
    try std.testing.expect(s.allowsReplica("DH_User"));

    try s.addIgnoreTable("DH_Account");
    try std.testing.expect(!s.allowsReplica("dh_account"));
    try std.testing.expectEqual(@as(usize, 3), s.ignoredCount());

    // 幂等：重复添加不增加
    try s.addIgnoreTable("dh_account");
    try std.testing.expectEqual(@as(usize, 3), s.ignoredCount());

    try std.testing.expect(s.removeIgnoreTable("DH_Account"));
    try std.testing.expect(!s.removeIgnoreTable("DH_Account"));
    try std.testing.expectEqual(@as(usize, 2), s.ignoredCount());
}

test "全局切主库后一律不允许读从库" {
    const a = std.testing.allocator;
    var s = Strategy.init(a);
    defer s.deinit();

    try std.testing.expect(s.allowsReplica("DH_User"));
    s.setPrimaryOnly(true);
    try std.testing.expect(s.isPrimaryOnly());
    try std.testing.expect(!s.allowsReplica("DH_User"));
    s.setPrimaryOnly(false);
    try std.testing.expect(s.allowsReplica("DH_User"));
}
