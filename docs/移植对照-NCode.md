# 移植对照：DH.NCode（C#） / Pek.RCode（Rust） → Pek.ZCode（Zig）

> 目标口径：**功能语义与逻辑一模一样**。凡是行为差异，必须在这里写清「为什么」和「当前是否已实现」，
> 不允许静默降级。行号引用以 2026-11-11 的仓库快照为准。

## 1. 总览

| 能力 | C# `DH.NCode` | Rust `Pek.RCode` | Zig `Pek.ZCode` | 状态 |
|---|---|---|---|---|
| `Model.xml` 解析 | `Entity/EntityBuilder` | `src/model.rs` | `src/model.zig` | ✅ 对齐（含未识别属性保留） |
| 类型系统 | `DataType`（CLR 名） | `src/types.rs` | `src/types.zig` | ✅ 12 种类型 + 同义别名 |
| 字段值 | `Object` + `DbType` | `src/value.rs` | `zzig`：`db/value.zig` | ✅ 子集（无 `Decimal` 运算，仅解析/格式化/比较） |
| 方言语义 | `DH.NCode.*` 各驱动 | `src/dialect.rs` | `src/dialect.zig` | ⚠️ **5 族已实现**：SQLite / MySQL / SQL Server / PostgreSQL 系 / Oracle；其余显式 `error.Unsupported` |
| 条件表达式 | `WhereExpression` | `src/query.rs` | `src/query.zig` | ✅ 14 种运算符 |
| SQL 组装 | `InsertBuilder` / `SelectBuilder` | `src/sqlbuild.rs` | `src/sqlbuild.zig` | ✅ INSERT/UPDATE/DELETE/SELECT/COUNT（批量写未做） |
| 会话 | `IDbSession` | `src/session.rs` | `src/session.zig` | ✅ 同步单连接（无连接池/异步） |
| SQLite 驱动 | `DH.NCode.SQLite` | `src/sqlite.rs`（rusqlite） | `zzig`：`db/sqlite.zig`（动态加载 DLL） | ✅ |
| 表级 CRUD | `EntitySession` | `src/dbtable.rs` | `src/dbtable.zig` | ✅ insert/update/delete/find_by_pk/query/count |
| 连接与迁移 | `DAL` / `Migration` | `src/dal.rs` | `src/dal.zig` | ✅ 增量建表/补列/建索引，幂等 |
| 对象实体 + 脏更新 | `Entity` | `src/entity.rs` / `dirty.rs` | — | ⛔ 未做 |
| 整表/单对象缓存 | `Meta.Cache` | `src/cache.rs` | — | ⛔ 未做 |
| 批量写 / 队列 | `EntityExtension` | `src/batch.rs` / `entity_queue.rs` | — | ⛔ 未做 |
| 分表 / 分库 | `EntitySplit` / `Shards` | `src/shards.rs` | — | ⛔ 未做 |
| 反向工程 / 代码生成 | `XCodeTool` | `reverse.rs` / `codegen.rs` | — | ⛔ 未做 |
| 备份 / 远程服务 | `DAL_Backup` / `DbServer` | `backup.rs` / `db_service.rs` | — | ⛔ 未做 |

## 2. 逐项语义对齐（已实现部分）

### 2.1 `Model.xml`

对齐 Rust `src/model.rs`：

- 按 **XML 局部名**匹配，忽略命名空间版本（`Model202509` 等各期 XSD 均可）。
- `Nullable` 缺省 `false`（NOT NULL）；`TableName` 缺省等于 `Name`；`ColumnName` 缺省等于列的 `Name`。
- 视图：`IsView="True"` 或表名以 `#` 开头。
- 表达式索引必须显式 `Name`（库里读不回表达式，只能按名字幂等比对），否则解析报错。
- 含 `DataScale` 为 `time` / `time:` / `timeShard:` 的列 → 该表 `MaxCacheCount` 强制 0（对齐 C# `EntityBuilder.Prepare`）。
- **未识别属性原样保留**（`extra`），写出时可回写（C# 模型里拼错的属性名不会丢）。

### 2.2 方言（`src/dialect.zig`）

黄金断言直接来自 Rust 版单测（`dialect.rs` 的 `quoting_and_placeholders` / `field_type_mapping` /
`create_table_sqlite_matches_xcode_conventions` / `index_sql_generation` / `paging_syntax`），已逐条移植到 Zig 单测：

- 标识符引用：SQLite/PG/Oracle `"x"`、MySQL 反引号、SQL Server `[x]`，内部引号双写。
- 占位符：SQLite/MySQL `?`、SQL Server `@pN`、PG `$N+1`、Oracle `:N+1`。
- SQLite 字段类型：`Int32` 自增 → `integer`（否则 `int`）、`String(50)` → `nvarchar(50)`、`String` 无长度 → `text`、
  `Boolean` → `bit`、`Double` → `real`、`Decimal` → `decimal`、`DateTime` → `datetime`、`Binary` → `binary`、`Json` → `text`。
- SQLite 建表：自增列内联 `PRIMARY KEY AUTOINCREMENT`（不再生成表级主键）；`String` 列追加 `COLLATE NOCASE`；
  `NOT NULL` 在 `DEFAULT` 之前（Oracle 相反）。
- 索引：缺省名 `ix_{表}_{列1}_{列2}`；MySQL 的 `TEXT/BLOB` 列自动加前缀长度 `(191)`；表达式索引 MySQL 包双层括号。
- 分页：`LIMIT n OFFSET m`（SQLite/PG/MySQL）；SQL Server `OFFSET..FETCH`（无排序补 `ORDER BY (SELECT NULL)`）；
  Oracle ROWNUM 双层包装。
- 默认值：数值原样；布尔 PG 系 `TRUE/FALSE`、其它 `1/0`；字符串单引号包裹并双写单引号；MySQL 的 TEXT/BLOB 列用表达式默认。
- 新增列：**无默认值时不追加 `NOT NULL`**（存量数据无法通过约束）。

**未实现方言**：`duckdb` / `clickhouse` / `tdengine` / `influxdb` / `hana` / `firebird` / `db2` / `dameng` /
`iris` / `access` / `mongodb` / `nova` 在枚举与连接串解析里占位，但类型映射/DDL **明确返回 `error.Unsupported`**
（`DatabaseKind.isImplemented()` 可查）——避免生成“看起来能跑”的错误 SQL。

### 2.3 查询与 SQL 组装

- `Where` 条件之间固定 `AND`；`IN` 空集合 → `1 = 0`，`NOT IN` 空集合 → `1 = 1`（避免非法 SQL）。
- `raw` 片段按 `?` 逐个替换为方言占位符；占位符多于值时不静默吞掉（原样输出 `?`，便于暴露调用方错误）。
- `SELECT`：分页/取前 N/跳行场景未显式排序时按**主键兜底**（结果稳定）。
- 未知列名传入 `insert`/`update` 直接报 `error.ColumnNotFound`（对齐 Rust `column_name()?`）。

### 2.4 结构同步（`Dal.syncSchema`）

- 迁移档位：连接串 `Migration=` 优先，其次模型 `<Option><Migration>`，缺省 `On`。
  `Off` 不做任何 DDL；`ReadOnly` 只生成不执行；`On`/`Full` 执行增量（本轮两者行为相同，`Full` 的删除/改列未实现）。
- 动作：缺表 → 建表（含索引）；已存在 → `PRAGMA table_info` 对比补列；索引按名字幂等比对后补建。
- **幂等**：二次同步 `tables_created / columns_added / indexes_created` 均为 0（集成测试固化）。

## 3. 与 C#/Rust 的行为差异（有意为之）

| 差异 | 原因 |
|---|---|
| `Decimal` 只有解析/格式化/比较，没有四则运算 | ORM 层不需要算术；C# 的 `decimal` 运算属于业务层 |
| `DateTime` 固定 100ns 精度、不做时区换算 | 与 XCode 落库文本（7 位小数秒）一致 |
| 同步实现，无连接池/异步门面 | 第一轮只做「能正确跑通」的核心链路；池化与异步在后续轮次 |
| SQLite 通过 DLL 动态加载 | 不链 libc / UCRT（`-lc` 在 Win7 起不来）；也便于替换 SQLite 版本 |
| 值不拥有内存（借用 + 会话 arena） | 避免每行一次堆分配；调用方需保证生命周期 |

## 4. 下沉到 `zzig` 的公共件（2026-11-11）

与 ORM 无关、值得复用的能力已提到 `G:\Code\Zig\zzig` 公共库，ZCode 只保留 XCode 语义层。
**同一个能力只允许一份实现**：ZCode 里不再保留副本，`src/buf.zig` / `decimal.zig` / `datetime.zig` /
`value.zig` / `sqlite.zig` / `tempfile.zig` 已删除。

| 能力 | zzig 位置 | 对外名字 | 复用场景 |
|---|---|---|---|
| 字符串缓冲 | `src/text/buf.zig` | `zzig.Buf` | 任何零碎字符串拼接（SQL/日志/报文） |
| 十进制 | `src/number/decimal.zig` | `zzig.Decimal` | 财务文本、配置精度值、ORM 值模型 |
| 日期时间 | `src/time/datetime.zig` | `zzig.DateTime` | 数据库时间文本、定时任务、日志时间 |
| 字段值模型 | `src/db/value.zig` | `zzig.db.Value` | 任何“读库 → 统一值”的数据库访问层 |
| SQLite 驱动 | `src/db/sqlite.zig` | `zzig.db.sqlite`（别名 `zzig.sqlite`） | 任何需要嵌入式 SQLite 的 Zig 项目 |
| 临时文件名 / 静默删除 | `src/file/file.zig` | `zzig.File.UniqueTempName` / `DeleteQuiet` | 测试临时库、导出中间文件 |

ZCode 侧的转出（方便消费方少一个依赖）：`zcode.Decimal` / `zcode.DateTime` / `zcode.Value` /
`zcode.buf` / `zcode.sqlite` / `zcode.File`。

**不下沉**（带 XCode 语义，属于本库）：`types`（CLR 类型名）、`model`、`dialect`、`query`、`sqlbuild`、
`session`、`dbtable`、`dal`。

## 5. Zig 0.17 实测坑（已在代码里规避）

1. **`std.DynLib` 不支持 Windows**（0.17 只有 linux/mac/BSD 分支）→ 手写 `LoadLibraryA` / `GetProcAddress`。
2. **`std.time.timestamp` / `nanoTimestamp` / `crypto.random` 均已移除** → 用 `GetSystemTimeAsFileTime` / `GetTickCount64`。
3. **`std.fs.selfExeDirPathAlloc` / `std.fs.cwd()` 移除**（文件 API 迁到 `std.Io`）→ exe 目录用 `GetModuleFileNameA`。
4. **`Allocator.dupeZ` 移除** → SQL 文本手工补 `\0` 后传 `prepare_v2`。
5. **`ArenaAllocator` 不能中途复制**：先把所有分配做完，最后整体移入返回值；中途复制会让后续分配只更新副本的
   `buffer_list`，`deinit` 漏掉后分配的块（实测内存泄漏）。
6. **`sqlite3_bind_text` 必须用 `SQLITE_TRANSIENT`**：小数/时间在栈缓冲里格式化，用 `SQLITE_STATIC` 会在 `step()`
   时读到已失效的栈内容（实测 `"12.3400"` 变成 `"400"`）。
7. **连接串解析出的路径必须复制**：`Data Source` 直接借用入参切片，`Dal` 生命周期长于调用方的临时字符串
   （实测释放后变成 `UUUU...` 垃圾文件名）。
