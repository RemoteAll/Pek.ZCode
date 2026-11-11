//! 单调时钟：全库统一的时间源（`std.time.nanoTimestamp` 在 Zig 0.17 已移除）。
//!
//! 为什么单独一个模块：连接池的空闲超时、实体队列的到期刷新、拦截器的耗时统计
//! 都需要同一口径的时钟。**分散各写一份**会出现「同一台机器两套时间基准」的隐患
//! （尤其是以后换成注入式时钟做单测时）。
//!
//! 约定：只提供**单调**读数（间隔计算用）与**纳秒**粒度；不做时区换算。
//! 全局 `std.Io` 只初始化一次（本库为同步单连接模型，无并发初始化竞争）。

const std = @import("std");

var io_global: std.Io = undefined;
var io_ready: bool = false;

fn io() std.Io {
    if (!io_ready) {
        io_global = std.Io.Threaded.global_single_threaded.io();
        io_ready = true;
    }
    return io_global;
}

/// 单调纳秒（仅用于计算时间间隔，绝对值无意义）。
pub fn nowNs() i128 {
    return std.Io.Clock.Timestamp.now(io(), .awake).raw.nanoseconds;
}

/// 毫秒时间戳（用于「最后一次使用」这类粗粒度比较）。
pub fn nowMs() i64 {
    return @intCast(@divTrunc(nowNs(), 1_000_000));
}

/// 把一段纳秒间隔换算成毫秒（四舍五入到最近毫秒，避免 0.9ms 显示成 0）。
pub fn nsToMs(ns: i128) u64 {
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns + 500_000, 1_000_000));
}

test "时钟单调递增且毫秒换算正确" {
    const a = nowNs();
    const b = nowNs();
    try std.testing.expect(b >= a);
    try std.testing.expectEqual(@as(u64, 0), nsToMs(-5));
    try std.testing.expectEqual(@as(u64, 1), nsToMs(600_000));
    try std.testing.expectEqual(@as(u64, 2), nsToMs(1_500_000));
}
