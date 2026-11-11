//! Pek.ZCode —— DH.NCode（XCode ORM）的 Zig 实现。
//!
//! 目标：与 C# `DH.NCode` / Rust `Pek.RCode` **语义与逻辑一致**——共用同一份 `Model.xml`、
//! 共用同一个数据库，生成的 SQL 文本与结构迁移行为可对照。
//!
//! 当前阶段（v0.1.0 第一轮）已落地：
//! - `types`：`DataType`（CLR 类型名）与宽松解析
//! - `model`：`Model.xml` 解析 / 写出（往返一致，兼容 C# 模型）
//! - `dialect`：SQLite / MySQL / SQL Server / PostgreSQL / Oracle 的类型映射、DDL、索引、分页
//! - `query`：`Where` 条件与 `Query` 查询描述
//! - `sqlbuild`：INSERT / UPDATE / DELETE / SELECT / COUNT 组装
//! - `session` / `dbtable` / `dal`：会话、表级 CRUD、连接串与增量建表
//!
//! 通用件（与 ORM 无关）已下沉到 `zzig` 公共库，本包直接转出以便消费方少一个依赖：
//! - `zzig.Decimal` / `zzig.DateTime` / `zzig.Buf` / `zzig.db.Value` / `zzig.sqlite` / `zzig.File`

const std = @import("std");
const zzig = @import("zzig");

pub const version = "0.1.0";

pub const DataType = @import("types.zig").DataType;

/// 十进制（`zzig.Decimal`）：尾数 + 缩放因子，解析/格式化/精确比较
pub const Decimal = zzig.Decimal;
/// 日期时间（`zzig.DateTime`）：无时区，`YYYY-MM-DD HH:MM:SS.fffffff` 文本口径
pub const DateTime = zzig.DateTime;
/// 字段值模型（`zzig.db.Value`）：Null/Bool/Int/Float/Decimal/Text/Blob/DateTime
pub const Value = zzig.db.Value;
pub const model = @import("model.zig");
pub const EntityModel = model.EntityModel;
pub const TableMeta = model.TableMeta;
pub const ColumnMeta = model.ColumnMeta;
pub const IndexMeta = model.IndexMeta;
pub const dialect = @import("dialect.zig");
pub const DatabaseKind = dialect.DatabaseKind;
pub const query = @import("query.zig");
pub const Where = query.Where;
pub const Query = query.Query;
pub const sqlbuild = @import("sqlbuild.zig");
/// 字符串缓冲（`zzig.Buf`）
pub const buf = zzig.Buf;
/// 文件工具（`zzig.File`：唯一临时名 / 静默删除）
pub const File = zzig.File;
pub const session = @import("session.zig");
/// SQLite 驱动（`zzig.sqlite`：动态加载 DLL，不链 libc）
pub const sqlite = zzig.sqlite;
pub const dbtable = @import("dbtable.zig");
pub const dal = @import("dal.zig");
pub const Dal = dal.Dal;
/// 对象实体（脏字段更新 / insert / save / update / delete / find / query）
pub const entity = @import("entity.zig");
/// 代码生成：Model.xml → Zig 实体
pub const codegen = @import("codegen.zig");

pub const Error = error{
    Model,
    Xml,
    Unsupported,
    NotFound,
    ReadOnly,
    NoPrimaryKey,
    NoConnection,
    ColumnNotFound,
    TableNotFound,
    Sqlite,
    SqliteNotAvailable,
};

test {
    _ = @import("types.zig");
    _ = @import("model.zig");
    _ = @import("dialect.zig");
    _ = @import("query.zig");
    _ = @import("sqlbuild.zig");
    _ = @import("session.zig");
    _ = @import("dbtable.zig");
    _ = @import("dal.zig");
    _ = @import("entity.zig");
    _ = @import("codegen.zig");
}
