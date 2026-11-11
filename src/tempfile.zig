//! 测试辅助：临时库路径与「尽力删除」。
//!
//! 说明：Zig 0.17 的文件 API 需要 `Io` 实例（`std.Io.Dir.deleteFile(io, path)`），
//! 单测里为删一个临时文件去搭 Io 线程池不划算；这里直接用 Win32 `DeleteFileA`，
//! 非 Windows 平台静默跳过（当前 SQLite 驱动本身也只在 Windows 上可加载）。

const std = @import("std");

var counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// 生成当前目录下的唯一临时库文件路径（调用方负责 free）。
///
/// 0.17 的 std 里没有 `time.timestamp` / `crypto.random` 这类全局源，这里用
/// `GetTickCount64` + 进程 ID + 进程内计数器，足够保证跨进程/跨轮次不撞名。
pub fn uniquePath(gpa: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    const id = counter.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(gpa, ".{c}{s}-{x}-{x}-{d}{s}", .{
        std.fs.path.sep,
        prefix,
        tickCount(),
        processId(),
        id,
        suffix,
    });
}

fn tickCount() u64 {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return 0;
    const k32 = struct {
        extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    };
    return k32.GetTickCount64();
}

fn processId() u32 {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return 0;
    const k32 = struct {
        extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    };
    return k32.GetCurrentProcessId();
}

/// 尽力删除（不存在/无权限/非 Windows 均静默忽略；只用于测试收尾）。
pub fn deleteQuiet(path: []const u8) void {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return;

    const k32 = struct {
        extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) i32;
    };
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    _ = k32.DeleteFileA(path_z);
}

test "唯一路径与删除" {
    const a = std.testing.allocator;
    const p1 = try uniquePath(a, "zcode-test", ".db");
    defer a.free(p1);
    const p2 = try uniquePath(a, "zcode-test", ".db");
    defer a.free(p2);
    try std.testing.expect(!std.mem.eql(u8, p1, p2));
    deleteQuiet(p1); // 不存在也不应崩
}
