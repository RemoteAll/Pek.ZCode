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
| SQL 组装 | `InsertBuilder` / `SelectBuilder` | `src/sqlbuild.rs` | `src/sqlbuild.zig` | ✅ INSERT/UPDATE/DELETE/SELECT/COUNT + 多行批量 INSERT |
| 会话 | `IDbSession` | `src/session.rs` | `src/session.zig` | ✅ 同步单连接 + **SQLite 预处理语句缓存** + 事务（含嵌套计数/Scoped） |
| SQLite 驱动 | `DH.NCode.SQLite` | `src/sqlite.rs`（rusqlite） | `zzig`：`db/sqlite.zig`（动态加载 DLL） | ✅ |
| MySQL 驱动 | `DH.NCode.MySql` | `src/mysql.rs`（`mysql` crate，纯协议） | `zzig`：`db/mysql.zig`（**纯协议**，不加载 libmysqlclient） | ✅ 握手/鉴权/COM_QUERY/预处理二进制协议/**`LOAD DATA LOCAL INFILE` 流式批量装载**/**TLS（`SslMode` 五档）**/**压缩协议（`CLIENT_COMPRESS`）**；可任意叠加（压缩在 TLS 内层） |
| 表级 CRUD | `EntitySession` | `src/dbtable.rs` | `src/dbtable.zig` | ✅ insert/update/delete/find_by_pk/query/count/batch |
| 连接与迁移 | `DAL` / `Migration` | `src/dal.rs` | `src/dal.zig` | ✅ 增量建表/补列/建索引；**`Full` 档删列删索引 + 改列类型/长度**（SQLite 走整表重建）；表级档位只能收紧；幂等 |
| 对象实体 + 脏更新 | `Entity` | `src/entity.rs` / `dirty.rs` | `src/entity.zig` | ✅ insert/update(脏列)/save/saveBatch/delete/find/query |
| 整表/单对象缓存 | `Meta.Cache` | `src/cache.rs` | `src/cache.zig` | ✅ 整表 `Cache(T)` + `SingleCache(T)`，写后自动失效 |
| 批量写 / 队列 | `EntityExtension` / `EntityDeferredQueue` | `src/batch.rs` / `entity_queue.rs` | `src/entity_queue.zig` | ✅ 多行 INSERT 分批 + 延迟写队列（按条数/时间触发，失败保留队列） |
| 分表 / 分库 | `EntitySplit` / `Shards` / `TimeShardPolicy` | `src/shards.rs` | `src/shards.zig` | ✅ 时间分表（`{0}_{1:yyyyMM}`）/ 连接模板 / 区间扫描 / 条件推导 / 雪花 Id；✅ **跨库分片**（`attachConnection` + `sessionForConn`）与**分片表自动建表**（`ensureShardTable`） |
| 读写分离 | `ReadWriteStrategy` / `DAL.Reads` | `src/readwrite.rs` | `src/readwrite.zig` + `Dal.readSessionFor` | ✅ 忽略表 / 全局切主库 / 轮询从库（从库会话强制只读） |
| 连接池 | ADO.NET 连接池 | `src/pool.rs` | `src/pool.zig` + `Dal.makePool` | ✅ 上限 / 空闲回收 / 预热 / 统计；`:memory:` 自动不建议池化 |
| 写入拦截器 | `EntityInterceptor` / `TimeModule` / `UserModule` / `TraceModule` | `src/interceptor.rs` | `src/interceptor.zig` | ✅ 审计列自动补全（插入补、更新刷），单条与批量都生效 |
| 导航属性 | `NavigationLoader` / `NavigationExtensions` | `src/navigation.rs` | `src/navigation.zig` | ✅ 单条 / 列表 / **批量填充（消除 N+1）**；多级级联由调用方组合 |
| 树形实体 | `Tree/EntityTree` | `src/tree.rs` | `src/tree.zig` | ✅ 子节点 / 后代（BFS）/ 向上路径 / 根节点；深度与节点数护栏 |
| 反向工程 | `DbMetaData.GetSchema` + XCodeTool | `reverse.rs` | `src/reverse.zig`（`zcodegen --reverse`） | ✅ SQLite/MySQL：表/列/主键/自增/索引/注释 → `Model.xml` |
| 代码生成 | `XCodeTool` | `codegen.rs` | `src/codegen.zig` + `tools/zcodegen.zig` | ✅ `Model.xml` → Zig 实体 |
| 备份 | `DAL_Backup` | `backup.rs` | `src/backup.zig` | ✅ SQLite 原生快照（`VACUUM INTO`）+ SQL 脚本（结构+数据，SQLite/MySQL） |
| 远程服务 | `DbServer` / `DbService` | `db_service.rs` | `src/dbservice.zig` + `src/dbclient.zig`（服务端在 `zzig/src/http/server.zig`） | ✅ HTTP/1.1 + JSON 信封；Login / Query / Execute / InsertAndGetIdentity / QueryCount / GetTables / Begin·Commit·Rollback（事务带令牌路由 + 空闲自动回滚）/ 令牌·库白名单；客户端 401→`Unauthorized`、404→`Unsupported` 降级。**`Db/Query` 两种载荷**：默认 JSON 行列；**`?format=packet` 返回 C# `DbTable` v3 二进制**（`src/dbtable_packet.zig`，字节级对齐真实 C# 运行时，C# 侧 `new DbTable().Read(pk)` 直接可读） |
| 累加字段（`Additional`） | `BindColumnAttribute.Additional` / `Meta.Factory.AdditionalFields` | `dirty.rs` + 累加更新 | `src/model.zig` + `src/sqlbuild.zig` + `src/dbtable.zig` | ✅ `Model.xml` 的 `Additional="True"` 解析/回写；`AccumulateField` 三模式（`add` / `max` / `min`）生成**单条 SQL 原子累加**（`col = col + ?`、`CASE WHEN`），不做「读-改-写」；`TableRef.accumulate` 写后带失效通知 |
| 统计 | `Statistics/{StatModel,StatHelper,StatField,StatLevels}` | `src/stat.rs` | `src/stat.zig` | ✅ 层级（全局/年/月/日/小时/分钟/季度，整数值与 C# 一致）与时间截断逐分支对齐；`Repository` = `find` / `getOrAdd`（没有就插，并发冲突再查）/ `accumulate`（sum·count·max·min）/ `addValues`；`avg` 明确报 `error.Unsupported`（不静默算错） |
| 数据抽取 | `Transform/{IdExtracter,TimeExtracter,PagingExtracter,ExtractSetting}` | `src/transform.rs` | `src/extract.zig` | ✅ 三个抽取器都是「一次一批」迭代 + `total` 计数 + `done` 终止：Id 主键步进 / 时间窗切片（空窗加大步进）/ 分页兜底；`Setting` 含起止时间、偏移秒、步进、批大小 |
| 窗口函数 | `DataAccessLayer/WindowFunction` | — | `src/window.zig` | ✅ `ROW_NUMBER` / `RANK` / `DENSE_RANK` / 聚合窗口 `FUNC(col) OVER(...)`；缺省别名与 C# 一致（`RowNum` / `Rank` / `DenseRank` / `{func}_{column}`） |
| 其它执行驱动 | `DH.NCode.{SqlServer,PostgreSQL,Oracle,…}` | `mssql/postgres/oracle/odbc/…` | `zzig`：`db/postgres.zig`、`db/tds.zig` | ✅ **PostgreSQL**：协议 3.0，Trust/Cleartext/MD5/SCRAM-SHA-256 鉴权、简单查询与扩展查询（参数 text 格式）、文本结果解码、影响行数；✅ **SQL Server（TDS 7.4）**：PRELOGIN/LOGIN7（SQL 认证）、SQL 批处理、RPC `sp_executesql` 带参、COLMETADATA/ROW/NBCROW/DONE/ERROR 令牌、常见类型解码、`SCOPE_IDENTITY()` 回写；**TLS(ENCRYPTION=ON/REQ) 明确报 `TlsRequired`**、集成认证/MARS/TEXT-TEXTIMAGE/sql_variant 未做；❌ Oracle（OCI/TNS）**未做**（无 oci.dll/libclntsh 也无实例，不能验证） |

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
  `Off` 不做任何 DDL；`ReadOnly` 只生成不执行；`On` 只创建；`Full` 额外**删列、删索引、改列类型/长度**。
- 动作：缺表 → 建表（含索引）；已存在 → 读现有列（SQLite `PRAGMA table_info`，MySQL/SQL Server/PostgreSQL
  `information_schema.columns`）对比补列；索引按名字幂等比对后补建。
- **改列（`Full` 档）**：
  - MySQL / SQL Server / Oracle / PostgreSQL 系 → `ALTER TABLE ... MODIFY/ALTER COLUMN`；
    **MySQL/Oracle/SQL Server 的 `MODIFY` 是整列定义替换**，所以语句里必须带上 `NOT NULL`/`NULL`
    （MySQL/Oracle 还要带 `DEFAULT`、`COMMENT`），否则约束会被悄悄弄丢（MySQL 8.0.29 真库实测过）。
  - SQLite 没有 `ALTER COLUMN` → **整表重建**：`RENAME TO {表}_zcode_old` → 按模型建表 → 复制共同列 →
    `DROP` 旧表 → 重建索引（索引名库内全局唯一，必须等旧表删掉才能建同名索引）。
    只复制**两边都有的列**（Full 档允许丢列）；自增主键值原样搬过去。
  - **类型比对口径**：基础名归并同义词（`integer`→`int`、`character varying`→`varchar`、`numeric`→`decimal`…），
    括号参数**只在两边都写了才比** —— MySQL 的 `bit(1)` / `tinyint(1)` 显示宽度不该触发反复 ALTER。
  - **可空性不自动改**：模型要 NOT NULL 而库里可空时只打日志（存量 NULL 会让约束失败）。
  - SQLite 重建的已知代价：库里的**视图/触发器**会被 `RENAME` 改指向临时表，重建后需人工复查
    （因此只在 `Full` 档触发）。
- **幂等**：二次同步 `tables_created / columns_added / columns_altered / indexes_created` 均为 0（集成测试固化）。

### 2.5 C# `DbTable` v3 二进制（`Db/Query?format=packet`）

字节规则来自 C# 源码（`DH.NCore/Data/DbTable.cs` + `Serialization/Binary/*.cs`），并用**真实 C# 运行时**
（`DH.NCore.dll` / net10.0）生成黄金字节逐字节比对（`src/dbtable_packet.zig` 末尾的常量）。

```text
"NewLifeDbTable"(14B) + 版本(1B)=3 + 保留位(varint 0) + 列数(varint)
每列: varint(字节数) + UTF-8 列名 + TypeCode(1B) [+ TypeCode=1 时 varint(长度)+类型全名]
行数: **4 字节小端**（不是 varint，C# 用 Total.GetBytes() 原样写）
每行按列序写值
```

| TypeCode | 值编码 |
|---|---|
| 3 Boolean / 6 Byte | 1 字节 |
| 7 / 9 / 11 Int16/32/64 | **7bit varint**（负数按补码无符号展开：Int32 的 -1 = 5 字节，Int64 = 10 字节） |
| 13 Single / 14 Double | 4 / 8 字节 **大端**（`Binary.IsLittleEndian` 默认 false） |
| 15 Decimal | 4 个 varint：`.NET Decimal.GetBits` 的 `lo/mid/hi/flags`（flags = scale<<16 \| 0x80000000） |
| 16 DateTime | varint(`DateTime.ToBinary()` = ticks，kind=0) |
| 18 String | varint(UTF-8 字节数) + UTF-8 |
| 1 Object(`System.Byte[]`) | varint(字节数) + 原始字节 |

**NULL 口径**：C# `BinaryGeneral` 对值类型列写 `null` 会抛 `InvalidCastException`（实测），它自己读库时
已把 `DBNull` 换成类型默认值 → 本实现与之一致：NULL 写成默认值（`0` / `""` / `0m` / ticks=0 / 空数组）。
需要区分 NULL 请用 JSON 载荷。

**空结果集**：`Session` 不暴露列元数据，0 行时拿不到列名 → 返回 0 列 0 行的合法包（不塞假列名）。

### 2.6 累加字段 / 统计 / 数据抽取（`src/{model,sqlbuild,dbtable,stat,extract}.zig`）

**累加字段（`Additional`）**

- `Model.xml` 的 `Column Additional="True"` ⇄ C# `BindColumnAttribute.Additional`；解析、`toXmlAlloc` 回写、
  `TableMeta.additionalFields()` 都对齐。
- 更新时不覆盖而是在列自身基础上算：`sqlbuild.AccumulateField` 三模式，都只用标准 SQL（五族方言通用）：

  | 模式 | 生成片段 | 用途 |
  |---|---|---|
  | `add` | `"c" = "c" + ?` | 求和 / 计数（`count` 固定 `+1`） |
  | `max` | `"c" = CASE WHEN "c" IS NULL OR "c" < ? THEN ? ELSE "c" END` | 峰值 |
  | `min` | `"c" = CASE WHEN "c" IS NULL OR "c" > ? THEN ? ELSE "c" END` | 谷值 |

  **必须走 SQL 原子累加**：`读到 5 → 内存里加 3 → 写回 8` 在并发下会丢增量（两个写入者都写 8 而不是 8/11）。
- `TableRef.accumulate()` 写完同样触发缓存失效（与 `update` 一致）。

**统计（`Statistics`）**

- `Levels` 整数值与 C# 完全一致（`All=0 / Year=1 / Month=2 / Day=3 / Hour=4 / Minute=5 / Quarter=11`），可直接读 C# 落库值。
- 时间截断逐分支对齐 `StatModel.GetDate`：年→`1-1`、月→`1` 日、日→`00:00`、小时→`:00`、分钟→秒归零、
  `All`→`0001-01-01`、`Quarter`→**不截断**（C# 也没写这个分支，保持一致）。
- `StatModel.init` 保留原时间；**`StatModel.at` 才按层级截断**——统计表主键是「层级 + 区间起点」，
  写库前不截断会让同一小时的两条数据落成两行。
- `Repository`：`find`（层级+时间）/ `getOrAdd`（没有就插；插入失败再查一次，并发下按已存在处理）/
  `accumulate`（顺带刷 `UpdateTime`）/ `addValues`（= getOrAdd + accumulate）。

**数据抽取（`Transform`）**

| 抽取器 | 每批查询 | 适用 |
|---|---|---|
| `IdExtractor` | `WHERE id > 上批末尾 ORDER BY id LIMIT n` | 自增 / 雪花 Id |
| `TimeExtractor` | 时间窗 `[start, end)` + 每批后重开窗口 | 有时间索引列 |
| `PagingExtractor` | `LIMIT n OFFSET m` | 无递增列时兜底（越翻越慢） |

- 三者都维护 `total`（累计行数）与 `done`（终止）；断点续跑用 `row`（Id/分页）或 `start`（时间）。
- `TimeExtractor` 的空窗处理：**起点推进到窗口末尾**并加倍步进（60s → 1 天封顶），保证单调前进。

## 3. 与 C#/Rust 的行为差异（有意为之）
| 差异 | 原因 |
|---|---|
| `Decimal` 只有解析/格式化/比较，没有四则运算 | ORM 层不需要算术；C# 的 `decimal` 运算属于业务层 |
| `DateTime` 固定 100ns 精度、不做时区换算 | 与 XCode 落库文本（7 位小数秒）一致 |
| 同步实现，无连接池/异步门面 | 第一轮只做「能正确跑通」的核心链路；池化与异步在后续轮次 |
| SQLite 通过 DLL 动态加载 | 不链 libc / UCRT（`-lc` 在 Win7 起不来）；也便于替换 SQLite 版本 |
| 值不拥有内存（借用 + 会话 arena） | 避免每行一次堆分配；调用方需保证生命周期 |
| `Db/Query` 默认回 JSON 行列（二进制需 `?format=packet`） | Rust 版也是 JSON；二进制模式是为 C# `DbTable.Read` 互通而加，两者并存不改变旧行为。C# 侧 `DbController.Query` 只有二进制一种形态（它的 `ToPacket` 自己标着“暂时有问题”），所以“跟 C# 一模一样”就只能二选一：默认 JSON 保持与 Rust 一致，需要 C# 互通时客户端显式要 packet |
| Oracle 执行驱动未做 | 无 `oci.dll` / `libclntsh`、也无实例：写了也无法验证，违反“实测优先” |
| `TimeExtractor` 空窗时把起点推进到窗口末尾 | C# 版空窗只加倍步进、`StartTime` 不动，步进封顶到 1 天后就对同一段空区间**反复查询（原地死循环）**；这里必须能终止 |
| `stat` 的 `avg` 直接报 `error.Unsupported` | C# 的均值由业务层「先读再算」；本库不提供假的原子实现，要求调用方自己维护 `Sum` + `Count` |
| `StatModel.init` 不截断、`StatModel.at` 截断 | 与 C# 一致（C# 是 `Fill`/`Split` 才截断）；分开两个构造器让“要不要截断”显式化，避免静默改变时间值 |
| 窗口函数别名按方言引用 | C# 原样拼别名；SQLite 会把未引用别名当标识符且大小写折叠，故 Zig 侧引起来（函数名与 OVER 子句仍逐字一致） |
| `MSPageSplit`（SQL Server 2000/2005 的 TOP + NOT IN / 双 TOP / ROW_NUMBER 分页）未移植 | 本库的 SQL Server 分页走 `OFFSET..FETCH`（SQL Server 2012+）；老版本分页属遗留算法，且需要整套 `SelectBuilder` 克隆/子查询设施，收益低于成本 |
| `Membership`（用户/角色/部门/菜单/租户/日志/参数/地区 + DataScope）、`Linq/EntityQueryProvider`、`XCodeTool` 的模板引擎未移植 | 前者是独立子系统（对应 Rust 生态里的 `Pek.RPermissions`，本库定位是 ORM 核心）；LINQ 表达式树在 Zig 无对应语法，条件用 `Where` 结构化拼装；模板引擎由 `codegen.zig`（Model.xml → Zig 实体）承担 |
| 20+ 种小众方言（Access/ClickHouse/TDengine/DuckDB/Hana/Firebird/DB2/达梦/IRIS/MongoDB/NovaDb…）未实现 | 枚举与连接串可识别，但类型映射/DDL 明确 `error.Unsupported`，不生成“看起来能跑”的错误 SQL |

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
| 结果集行 | `src/db/row.zig` | `zzig.db.Row` | 各驱动共用的行结构（按列名/序号取值） |
| SQLite 驱动 | `src/db/sqlite.zig` | `zzig.db.sqlite`（别名 `zzig.sqlite`） | 任何需要嵌入式 SQLite 的 Zig 项目 |
| MySQL 驱动（绿色） | `src/db/mysql.zig` | `zzig.db.mysql`（别名 `zzig.mysql`） | 纯协议访问 MySQL，不加载 libmysqlclient |
| PostgreSQL 驱动 | `src/db/postgres.zig` | `zzig.db.postgres`（别名 `zzig.postgres`） | 纯协议访问 PostgreSQL（含金仓/瀚高/海量） |
| SQL Server 驱动 | `src/db/tds.zig` | `zzig.db.tds`（别名 `zzig.tds`） | 纯协议 TDS 7.4，不加载 ODBC/sqlncli |
| 临时文件名 / 静默删除 | `src/file/file.zig` | `zzig.File.UniqueTempName` / `DeleteQuiet` | 测试临时库、导出中间文件 |

ZCode 侧的转出（方便消费方少一个依赖）：`zcode.Decimal` / `zcode.DateTime` / `zcode.Value` /
`zcode.buf` / `zcode.sqlite` / `zcode.mysql` / `zcode.File`。
**不下沉**（带 XCode 语义，属于本库）：`types`（CLR 类型名）、`model`、`dialect`、`query`、`sqlbuild`、
`session`、`dbtable`、`dal`。

**供应商化例外**：`zzig/src/db/tls_client.zig` 是 Zig 0.17.1 `std/crypto/tls/Client.zig` 的副本，
仅多处理 `CertificateRequest`（MySQL 8 默认 `ssl_ca` 必发，std 不支持会让 TLS 完全不可用）。
这是**唯一**的「重复实现」例外，理由与 diff 清单写在文件头部；std 支持后应整个删除。

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
8. **数组重复写法 `[_]u8{0} ** N` 在 0.17.1 直接报错**：`error: binary operator '*' has whitespace on one side,
   but not the other`（解析成两个 `*`）。用 `@memset(&buf, 0)` 或把初值逐个写出来（本轮 TDS 驱动与测试都踩到）。
9. **`std.posix.getenv` 已不存在**（0.17 的 std 里没有），测试要开关就走文件级变量，别读环境变量。
