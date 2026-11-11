//! Pek.ZCode —— DH.NCode（XCode ORM）的 Zig 实现。
//!
//! 目标：与 C# `DH.NCode` / Rust `Pek.RCode` **语义与逻辑一致**——共用同一份 `Model.xml`、
//! 共用同一个数据库，生成的 SQL 文本与结构迁移行为可对照。
//!
//! 当前阶段（v0.1.0 第一轮）已落地：
//! - `types`：`DataType`（CLR 类型名）与宽松解析
//! - `decimal` / `datetime`：值类型（XCode 文本口径）
//! - `value`：字段值模型 + SQL 字面量渲染
//! - `model`：`Model.xml` 解析 / 写出（往返一致，兼容 C# 模型）
//! - `dialect`：SQLite / MySQL / SQL Server / PostgreSQL / Oracle 的类型映射、DDL、索引、分页
//! - `query`：`Where` 条件与 `Query` 查询描述
//! - `sqlbuild`：INSERT / UPDATE / DELETE / SELECT / COUNT 组装
//! - `sqlite`：SQLite 驱动（动态加载 sqlite3.dll / winsqlite3.dll，不链 libc）
//! - `session` / `dbtable` / `dal`：会话、表级 CRUD、连接串与增量建表

const std = @import("std");

pub const version = "0.1.0";

pub const DataType = @import("types.zig").DataType;
pub const Decimal = @import("decimal.zig").Decimal;
pub const DateTime = @import("datetime.zig").DateTime;
pub const Value = @import("value.zig").Value;
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
pub const buf = @import("buf.zig");
pub const tempfile = @import("tempfile.zig");
pub const session = @import("session.zig");
pub const sqlite = @import("sqlite.zig");
pub const dbtable = @import("dbtable.zig");
pub const dal = @import("dal.zig");
pub const Dal = dal.Dal;

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
    _ = @import("buf.zig");
    _ = @import("types.zig");
    _ = @import("decimal.zig");
    _ = @import("datetime.zig");
    _ = @import("value.zig");
    _ = @import("model.zig");
    _ = @import("dialect.zig");
    _ = @import("query.zig");
    _ = @import("sqlbuild.zig");
    _ = @import("sqlite.zig");
    _ = @import("session.zig");
    _ = @import("dbtable.zig");
    _ = @import("dal.zig");
}
