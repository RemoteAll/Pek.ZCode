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
/// 会话（execute / query / 自增回写 / 事务）
pub const Session = session.Session;
/// 事务隔离级别（对应 `System.Data.IsolationLevel`）
pub const IsolationLevel = session.IsolationLevel;
/// 作用域事务：`deinit` 时未提交即自动回滚（对应 C# `EntityTransaction`）
pub const ScopedTransaction = session.Session.Scoped;
/// SQLite 驱动（`zzig.sqlite`：动态加载 DLL，不链 libc）
pub const sqlite = zzig.sqlite;
/// MySQL 驱动（`zzig.mysql`：纯 wire protocol，不依赖 libmysqlclient）
pub const mysql = zzig.mysql;
pub const dbtable = @import("dbtable.zig");
pub const dal = @import("dal.zig");
/// 数据访问层（连接 / 结构同步 / 缓存失效）
pub const Dal = dal.Dal;
/// 连接串解析（XCode 口径：`Data Source=...;Provider=...`，MySQL 用 `Server/Port/Uid/Pwd/Database`）
pub const parseConnectionString = dal.parseConnectionString;
pub const ConnectionOptions = dal.ConnectionOptions;
/// 迁移档位（`Off` / `ReadOnly` / `On` / `Full`）
pub const Migration = model.Migration;
/// 对象实体（脏字段更新 / insert / save / update / delete / find / query）
pub const entity = @import("entity.zig");
/// 整表实体缓存（Blocking 一致性 + 写后自动失效）
pub const cache = @import("cache.zig");
/// 代码生成：Model.xml → Zig 实体
pub const codegen = @import("codegen.zig");
/// 反向工程：现有数据库结构 → Model.xml
pub const reverse = @import("reverse.zig");
/// 单调时钟（连接池/队列/拦截器共用的时间源）
pub const clock = @import("clock.zig");
/// 读写分离策略（忽略表 / 全局切主库）
pub const readwrite = @import("readwrite.zig");
/// 会话连接池（复用连接 / 空闲回收 / 上限保护）
pub const pool = @import("pool.zig");
/// 写入拦截器（审计列自动补全：时间 / 用户 / 追踪号）
pub const interceptor = @import("interceptor.zig");
/// 实体延迟写队列
pub const entity_queue = @import("entity_queue.zig");
/// 分表 / 分库（时间分表策略、区间扫描、雪花 Id 解析）
pub const shards = @import("shards.zig");
/// 备份（SQLite 原生快照 / SQL 脚本文本）
pub const backup = @import("backup.zig");
/// 导航属性（单条/列表/批量填充，消除 N+1）
pub const navigation = @import("navigation.zig");
/// 树形实体（子节点 / 后代 / 向上路径 / 根节点）
pub const tree = @import("tree.zig");
/// 数据库远程服务（把 Dal 暴露成 `Db/*` HTTP 接口，含事务令牌）
pub const dbservice = @import("dbservice.zig");
/// 数据库远程服务的客户端
pub const dbclient = @import("dbclient.zig");
/// C# `DbTable` v3 二进制编解码（`Db/Query` 的跨语言互通）
pub const dbtable_packet = @import("dbtable_packet.zig");
/// 统计模型与累加（层级截断 / 原子累加 / 找不到就插）
pub const stat = @import("stat.zig");
/// 数据抽取器（自增 Id / 时间窗 / 分页，大表搬迁与同步）
pub const extract = @import("extract.zig");
/// 窗口函数 SQL 片段（ROW_NUMBER / RANK / DENSE_RANK / 聚合窗口）
pub const window = @import("window.zig");
/// MS SQL Server 传统分页算法（TOP + NOT IN / 双 TOP / MaxMin / ROW_NUMBER，对应 `MSPageSplit`）
pub const pagesplit = @import("pagesplit.zig");
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
    _ = @import("cache.zig");
    _ = @import("codegen.zig");
    _ = @import("reverse.zig");
    _ = @import("clock.zig");
    _ = @import("readwrite.zig");
    _ = @import("pool.zig");
    _ = @import("interceptor.zig");
    _ = @import("entity_queue.zig");
    _ = @import("shards.zig");
    _ = @import("backup.zig");
    _ = @import("navigation.zig");
    _ = @import("tree.zig");
    _ = @import("dbservice.zig");
    _ = @import("dbclient.zig");
    _ = @import("dbtable_packet.zig");
    _ = @import("stat.zig");
    _ = @import("extract.zig");
    _ = @import("window.zig");
    _ = @import("pagesplit.zig");
}
