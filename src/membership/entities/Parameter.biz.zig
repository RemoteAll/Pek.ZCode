//! Parameter 的业务扩展（**手写文件，重新生成实体时不会被覆盖**）。
//!
//! 分工：
//! - `Parameter.zig`：生成器产出并覆盖（字段 / meta / CRUD / 缓存 / 必填校验）；
//! - `Parameter.biz.zig`（本文件）：派生属性、领域方法、跨表联动、业务校验。
//!
//! 依赖方向只有一条：本文件 import 基础文件，基础文件不 import 本文件（不会循环导入）。

const zcode = @import("../../root.zig");
const Parameter = @import("Parameter.zig").Parameter;

/// 必填校验（转发到生成侧；返回第一个为空的列名，`null` = 通过）。
pub fn valid(e: *const Parameter) ?[]const u8 {
    return e.valid();
}

// ── 下面按需展开（示例，取消注释后按业务改）──────────────────────
//
// /// 派生属性：不落库，仅展示/导出用。
// pub fn display(e: *const Parameter) []const u8 {
//     return e.Name; // 换成实际列
// }
//
// /// 保存前校验：配合 `try valid(e)` 在插入/更新前调用。
// pub fn checkBeforeSave(e: *const Parameter) !void {
//     if (e.valid()) |missing| return error.MissingField;
// }
//
// /// 领域方法：例如把状态机迁移写在这里（需要 dal/session 就作为参数传进来）。
// pub fn activate(e: *Parameter, dal: *zcode.Dal, s: *zcode.Session) !void {
//     _ = try e.update(dal, s);
// }
