# 移植对照：DH.NCode（C#） / Pek.RCode（Rust） → Pek.ZCode（Zig）

> 目标口径：**功能语义与逻辑一模一样**。凡是行为差异，必须在这里写清「为什么」和「当前是否已实现」，
> 不允许静默降级。行号引用以 2026-11-11 的仓库快照为准。

## 1. 总览

| 能力 | C# `DH.NCode` | Rust `Pek.RCode` | Zig `Pek.ZCode` | 状态 |
|---|---|---|---|---|
| `Model.xml` 解析 | `Entity/EntityBuilder` | `src/model.rs` | `src/model.zig` | ✅ 对齐（含未识别属性保留） |
| 类型系统 | `DataType`（CLR 名） | `src/types.rs` | `src/types.zig` | ✅ 12 种类型 + 同义别名 |
| 字段值 | `Object` + `DbType` | `src/value.rs` | `zzig`：`db/value.zig` | ✅ 子集（无 `Decimal` 运算，仅解析/格式化/比较） |
| 方言语义 | `DH.NCode.*` 各驱动 | `src/dialect.rs` | `src/dialect.zig` | ✅ **19 个可实现方言全覆盖**（`zig build audit-dialects` 19/19 无缺口）；仅 `mongodb` / `influxdb` 非 SQL 库显式 `error.Unsupported` |
| 条件表达式 | `WhereExpression` | `src/query.rs` | `src/query.zig` | ✅ 14 种运算符 |
| SQL 组装 | `InsertBuilder` / `SelectBuilder` | `src/sqlbuild.rs` | `src/sqlbuild.zig` | ✅ INSERT/UPDATE/DELETE/SELECT/COUNT + 多行批量 INSERT |
| 会话 | `IDbSession` | `src/session.rs` | `src/session.zig` | ✅ 同步单连接 + **SQLite 预处理语句缓存** + 事务（含嵌套计数/Scoped） |
| SQLite 驱动 | `DH.NCode.SQLite` | `src/sqlite.rs`（rusqlite） | `zzig`：`db/sqlite.zig`（动态加载 DLL） | ✅ |
| MySQL 驱动 | `DH.NCode.MySql` | `src/mysql.rs`（`mysql` crate，纯协议） | `zzig`：`db/mysql.zig`（**纯协议**，不加载 libmysqlclient） | ✅ 握手/鉴权/COM_QUERY/预处理二进制协议/**`LOAD DATA LOCAL INFILE` 流式批量装载**/**TLS（`SslMode` 五档）**/**压缩协议（`CLIENT_COMPRESS`）**；可任意叠加（压缩在 TLS 内层） |
| 表级 CRUD | `EntitySession` | `src/dbtable.rs` | `src/dbtable.zig` | ✅ insert/update/delete/find_by_pk/query/count/batch + **upsertBatch（SaveModes 四模式）** + **updateAccumulate（累加字段）**；**Dal 直执行 SQL**（`exec` / `queryAlloc` / `execOnTable` / `queryOnTableAlloc`，`?` 占位符按方言自动改写） |
| 连接与迁移 | `DAL` / `Migration` | `src/dal.rs` | `src/dal.zig` | ✅ 增量建表/补列/建索引；**`Full` 档删列删索引 + 改列类型/长度**（SQLite 走整表重建）；表级档位只能收紧；幂等 |
| 对象实体 + 脏更新 | `Entity` | `src/entity.rs` / `dirty.rs` | `src/entity.zig` | ✅ insert/update(脏列)/save/saveBatch/delete/find/query |
| 整表/单对象缓存 | `Meta.Cache` | `src/cache.rs` | `src/cache.zig` | ✅ 整表 `Cache(T)` + `SingleCache(T)`，写后自动失效 |
| 批量写 / 队列 | `EntityExtension` / `EntityDeferredQueue` | `src/batch.rs` / `entity_queue.rs` | `src/entity_queue.zig` | ✅ `SaveModes` 四种模式（insert/upsert/insert_ignore/replace，多行 INSERT + 方言 `ON CONFLICT`/`ON DUPLICATE KEY`/`OR REPLACE`，不支持 SQL 级 upsert 的方言退化为同事务逐行先改后插）；延迟桶（`addDelayed`）+ 定时器后台凑批（`start/stop`）；**`Entity.saveAsync(msDelay)` 语义**：入全局凑批队列（非一线程一调用），新增合并多行 INSERT、已存在逐条脏列更新；**分表分库凑批**：按「连接 + 分片物理表」归组，同分片才合并、不同分片各自一批 |
| 分表 / 分库 | `EntitySplit` / `Shards` / `TimeShardPolicy` | `src/shards.rs` | `src/shards.zig` | ✅ 时间分表（`{0}_{1:yyyyMM}`）/ 连接模板 / 区间扫描 / 条件推导 / 雪花 Id；✅ **跨库分片**（`attachConnection` + `sessionForConn`）与**分片表自动建表**（`ensureShardTable`） |
| 读写分离 | `ReadWriteStrategy` / `DAL.Reads` | `src/readwrite.rs` | `src/readwrite.zig` + `Dal.readSessionFor` | ✅ 忽略表 / 全局切主库 / 轮询从库（从库会话强制只读） |
| 连接池 | ADO.NET 连接池 | `src/pool.rs` | `src/pool.zig` + `Dal.makePool` | ✅ 上限 / 空闲回收 / 预热 / 统计；`:memory:` 自动不建议池化 |
| 写入拦截器 | `EntityInterceptor` / `TimeModule` / `UserModule` / `TraceModule` | `src/interceptor.rs` | `src/interceptor.zig` | ✅ 审计列自动补全（插入补、更新刷），单条与批量都生效 |
| 导航属性 | `NavigationLoader` / `NavigationExtensions` | `src/navigation.rs` | `src/navigation.zig` | ✅ 单条 / 列表 / **批量填充（消除 N+1）**；多级级联由调用方组合 |
| 树形实体 | `Tree/EntityTree` | `src/tree.rs` | `src/tree.zig` | ✅ 子节点 / 后代（BFS）/ 向上路径 / 根节点；深度与节点数护栏 |
| 反向工程 | `DbMetaData.GetSchema` + XCodeTool | `reverse.rs` | `src/reverse.zig`（`zcodegen --reverse`） | ✅ **SQLite / MySQL / PostgreSQL / SQL Server** 四家：表/列/主键/自增/索引/注释 → `Model.xml`（PG 与 SQL Server 的查询语句尚未在真库实测，见 §2.8） |
| 代码生成 | `XCodeTool` | `codegen.rs` | `src/codegen.zig` + `tools/zcodegen.zig` | ✅ `Model.xml` → Zig 实体 |
| 备份 | `DAL_Backup` | `backup.rs` | `src/backup.zig` | ✅ SQLite 原生快照（`VACUUM INTO`）+ SQL 脚本（结构+数据，SQLite/MySQL） |
| 远程服务 | `DbServer` / `DbService` | `db_service.rs` | `src/dbservice.zig` + `src/dbclient.zig`（服务端在 `zzig/src/http/server.zig`） | ✅ HTTP/1.1 + JSON 信封；Login / Query / Execute / InsertAndGetIdentity / QueryCount / GetTables / Begin·Commit·Rollback（事务带令牌路由 + 空闲自动回滚）/ 令牌·库白名单；客户端 401→`Unauthorized`、404→`Unsupported` 降级。**`Db/Query` 两种载荷**：默认 JSON 行列；**`?format=packet` 返回 C# `DbTable` v3 二进制**（`src/dbtable_packet.zig`，字节级对齐真实 C# 运行时，C# 侧 `new DbTable().Read(pk)` 直接可读） |
| 累加字段（`Additional`） | `BindColumnAttribute.Additional` / `Meta.Factory.AdditionalFields` | `dirty.rs` + 累加更新 | `src/model.zig` + `src/sqlbuild.zig` + `src/dbtable.zig` | ✅ `Model.xml` 的 `Additional="True"` 解析/回写；`AccumulateField` 三模式（`add` / `max` / `min`）生成**单条 SQL 原子累加**（`col = col + ?`、`CASE WHEN`），不做「读-改-写」；`TableRef.accumulate` 写后带失效通知 |
| 统计 | `Statistics/{StatModel,StatHelper,StatField,StatLevels}` | `src/stat.rs` | `src/stat.zig` | ✅ 层级（全局/年/月/日/小时/分钟/季度，整数值与 C# 一致）与时间截断逐分支对齐；`Repository` = `find` / `getOrAdd`（没有就插，并发冲突再查）/ `accumulate`（sum·count·max·min）/ `addValues`；`avg` 明确报 `error.Unsupported`（不静默算错） |
| 数据抽取 | `Transform/{IdExtracter,TimeExtracter,PagingExtracter,ExtractSetting}` | `src/transform.rs` | `src/extract.zig` | ✅ 三个抽取器都是「一次一批」迭代 + `total` 计数 + `done` 终止：Id 主键步进 / 时间窗切片（空窗加大步进）/ 分页兜底；`Setting` 含起止时间、偏移秒、步进、批大小 |
| 窗口函数 | `DataAccessLayer/WindowFunction` | — | `src/window.zig` | ✅ `ROW_NUMBER` / `RANK` / `DENSE_RANK` / 聚合窗口 `FUNC(col) OVER(...)`；缺省别名与 C# 一致（`RowNum` / `Rank` / `DenseRank` / `{func}_{column}`） |
| 传统 MsSql 分页 | `DataAccessLayer/MSPageSplit` | — | `src/pagesplit.zig` | ✅ `topNotIn` / `doubleTop` / `maxMin` / `rowNumber` 四种算法 + 与 C# 相同的选择顺序 + 首页直取 `TOP`；黄金 SQL 断言，`rowNumber` 分支在真 SQLite 上翻页验证 |
| 表达式树 | `Model/{Expression,FieldExpression,FormatExpression,ConcatExpression}` | — | `src/expression.zig` | ✅ 文本（`Or` 自动加括号）/ 字段（按方言引用）/ 格式化（`{0}` 列名、`{1}` 右值，参数化与字面量两种口径）/ 逗号拼接（可嵌套） |
| 批量查找器 | `Model/{BatchFinder,BatchOption}` | — | `src/batch.zig` | ✅ 登记主键去重（跳过 0 / 空串）→ 按 `batch_size` 分批 `IN` 预取、游标只前进、可替换 loader；`BatchOption` 作为批操作参数载体 |
| 全局设置 | `Setting.cs` / `XCodeSetting` | — | `src/setting.zig` | ✅ 字段与默认值逐项对齐（Debug/ShowSQL/TraceSQLTime/UseParameter/BatchSize/Migration/缓存过期…），支持 `Key=Value` 文本读写与未识别键上报 |
| SQL 模版 / 显示选项 | `Configuration/{SqlTemplate,ShowInOption}`、`Attributes/ModelSortMode` | — | `src/sqltemplate.zig` | ✅ `-- [方言]` 分段解析 + 回落默认；`ShowInOption` 三种写法（具名列表+宏 / 管道 5 段 / 5 字符掩码）；`ModelSortMode` 枚举 |
| 缓存协调与表缓存 | `Cache/{CacheInvalidator,DataCache,DbCache,LazyConsumer}` | — | `src/dbcache.zig` | ✅ 分布式版本号（可插 Provider + 内存实现）联动本地失效；运行数据缓存（表行数 + 字段键值，可落文本）；**表当缓存**（Name/Value/CreateTime/ExpiredTime + 过期清理）；惰性串行消费者（空闲不占线程） |
| 数据包 | `DataAccessLayer/DbPackage` | — | `src/dbpackage.zig` | ✅ 表级导出/导入/跨库同步（按页抽取，内存只留一页）；四种保存模式；**未做**：`.gz` / `zip` 多表归档（本仓与 zzig 都没有 zip 实现）、Actor 双线程并行 |
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

**方言覆盖**（`isImplemented()`）：SQLite / MySQL / SQL Server / Oracle / PostgreSQL 系（KingBase、HighGo、VastBase）/
DuckDB / ClickHouse / TDengine / HANA / Firebird / DB2 / 达孟（DaMeng）/ IRIS / Access / SqlCe / NovaDb ——
类型映射按 C# 各驱动的 `_DataTypes` 表逐项拷录（`DaMeng.cs` / `DB2.cs` / `Firebird.cs` / `Hana.cs` / `IRIS.cs` /
`Access.cs` / `SqlCe.cs` / `NovaDb.cs` / `Tdengine.cs`）；自增子句与分页也按各自 `GetFieldConstraints` / `PageSplit` 实现
（Db2 与达孟 rownum 双层、Firebird `ROWS a TO b`、Access/SqlCe 只支持首页 `TOP`、HANA/IRIS/Nova `AUTO_INCREMENT`…）。

**仍未实现**：`mongodb`（文档库，无 SQL）与 `influxdb`（Line Protocol）—— 它们**不是 SQL 库**，`isImplemented()` 永远为 false，
建表/分页一律 `error.Unsupported`。DuckDB / ClickHouse 在 C# 侧没有静态类型表（走驱动自带 schema），
这里的类型名按两者**原生类型名**给出（DuckDB 兼容 PG 类型名、ClickHouse 用 `Int*/String/Decimal(p, s)`）。

**覆盖审计（机器可验，2026-11-12）**：`zig build audit-dialects` —— 把 19 个可实现方言逐个跑一遍
类型映射（12 种 `DataType`）/ 引用 / 占位符 / 分页 / 建表 / 建索引 / 改列 / 删列 / 自增语句，
凡失败即打 `[GAP]` 并以退出码 1 结束。**当前结果：19/19 无缺口**。

这轮审计顺手抓到两处「不报错但生成错」的静默问题，已修：

| 问题 | 证据 | 处理 |
|---|---|---|
| `.nova` 标识符引号走了 `else` → 双引号 | C# `NovaDb.cs:89-91` 的 `FormatName` 用**反引号** | 归入反引号分支 |
| `lastIdentitySql` 只覆盖 5 族，其余 12 家返回空串 | `Access.cs:154` / `SqlCe.cs:161` `Select @@Identity`；`Hana.cs:238` / `IRIS.cs:288` `Select LAST_INSERT_ID()`；`DB2.cs:320` / `DaMeng.cs:203` 序列 `.currval`；`Firebird.cs:206` `GEN_ID` → `Select SEQ.currval`；`DuckDB.cs:201` `RETURNING *` | 逐家补齐；ClickHouse / TDengine 无自增 → 空串（不编造） |

**Access / SqlCe 的分页**：`applyPagingAlloc` 只在 `offset == 0` 出 `TOP`，带 offset 明确 `error.Unsupported`
并打印指路文案；等价能力用 `pagesplit.pageSplitAlloc`（C# 同样走 `SqlServer.PageSplitByTopNotIn`，
`Access.cs:102-119` / `SqlCe.cs:110-127`），新增 `DatabaseKind.usesTopPaging()` 供调用方选路。

> 口径说明（2026-11-12）：以上方言只做了 **SQL 生成层**（类型/DDL/分页/占位符/引用）并全部有黄金断言；
> 除 SQLite/MySQL/PostgreSQL/SQL Server 外的驱动**未接执行层**，也没有真实库可实测——
> 属于用户明确同意的「先迁移代码，有环境再验证」范围。

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

### 2.7 `Model.xml` 完全共用 + 实体代码生成器（`zcodegen`）

**共用口径**：同一份 `Model.xml` 同时被 C# `XCodeTool`、Rust `Pek.RCode` 与 Zig `zcodegen` 读取；
Zig 侧不引入任何私有字段，C# 里认不出的属性（如 `Attribute="XmlIgnore, …"`、`IgnoreNameCase`）
按 `Column@extra` / `Table@extra` **原样保留并回写**，因此 C#/Rust 再读回来不丢信息。

验证入口：`zcodegen --model <xml> --verify`（解析 → 回写 → 再解析，比表/列/索引/未识别属性计数）。

| 真实模型 | 表 | 列 | 索引 | 回写后一致 |
|---|---|---|---|---|
| `tests/fixtures/dh-ncode-model.xml`（C# `DH.NCode/Model.xml`，即成员权限模型） | 9 | 200 | 31 | ✅ |
| `tests/fixtures/dh-ncode-test-model.xml`（C# `XUnitTest.XCode/TestEntity/Model.xml`） | 18 | 101 | 10 | ✅ |
| `tests/fixtures/wms-model-sample.xml`（Rust `Pek.RCode/tests/fixtures`） | 27 | 123 | 27 | ✅ |

**代码生成器**（`src/codegen.zig` + `tools/zcodegen.zig`，对应 C# `XCodeTool` / Rust `codegen.rs`）：

- 生成物：每表一个 `<Name>.zig` + `mod.zig`（含 `pub const all = .{ … }` 便于 `inline for` 遍历）；
- 每个实体带：`dirty` 脏位图、列文档注释、`meta.fields`（类型/主键/自增/**可空/累加/长度/精度/物理列名/注释**）、
  `main_keys` / `identity_index` / `additional_indexes`、`indexes` 常量、`table(dal)` 表句柄、
  `getXxx` / `setXxx`（setter 自动置脏）、`columnValue` / `setColumnValue`（装载不置脏）；
- 文件名与访问器后缀会做安全化（非 ASCII/非标识符字符换 `_`，数字开头补 `_`）；
- **自检**：`zig build gen-check -Dgen-check=<dir> -Dmodel=<xml>` 把生成的实体编译出来，
  在临时 SQLite 上 `syncSchema` + 逐实体插入/按主键取回/删除。

自检实测（本机）：

```text
C# DH.NCode 模型：建表 9 / 补列 0 / 建索引 31；实体 9 个，真实增删改查通过 8 个，跳过 1 个（Log 为 InsertOnly）
C# 测试模型：     实体 18 个，通过 18 个
Rust Pek.RCode 模型：实体 27 个，通过 27 个
```

`tools/regression.ps1` 已把这三条「生成 → 编译 → 真库」链路纳入一键回归（任一夹具缺失显式 `SKIP` 并说明原因）。

### 2.8 缓存协调 / 表达式 / 批查找 / 设置 / 模版 / 数据包 / PG·SQL Server 反向工程（2026-11-12 第二十二轮）

这一轮把台账里剩下的「中小件」一次补完，共 7 个新模块：

| 模块 | 对齐的 C# 源 | 关键语义 |
|---|---|---|
| `src/setting.zig` | `Setting.cs` / `XCodeSetting` | 字段与默认值逐项照抄（`Debug=true`、`ShowSQL=true`、`TraceSQLTime=1000`、`BatchSize=5000`、`Migration=On`、`EntityCacheExpire=10`、`FieldCacheExpire=3600` …）；`Key=Value` 文本读写，**不认识的键与非法值都进 `unknown` 上报**，不静默吞掉 |
| `src/sqltemplate.zig` | `Configuration/SqlTemplate`、`ShowInOption`、`Attributes/ModelSortMode` | `-- [MySql]` 分段；同名方言后者覆盖；取不到方言回落默认。`ShowInOption` 三种写法与优先级（含 `|` → 管道；`[10A?-]{5}` → 掩码；否则具名列表 + 宏顺序覆盖） |
| `src/expression.zig` | `Model/{Expression,FieldExpression,FormatExpression,ConcatExpression}` | `Or` 按**独立单词**判定（等价 `\bOr\b`，`OrderId` 不触发）；`FieldExpression` 按方言引用；`FormatExpression` 参数化走占位符、非参数化内联字面量（`Value.toSqlLiteralAlloc`）；`ConcatExpression` 逗号拼接可嵌套 |
| `src/batch.zig` | `Model/{BatchFinder,BatchOption}` | 跳过 `0` / 空串、按键去重、游标只前进、每批 `IN` 预取、未登记者报 `error.NotInKeys`；`loader` 可替换 |
| `src/dbcache.zig` | `Cache/{CacheInvalidator,DataCache,DbCache,LazyConsumer}` | 版本号键名沿用 C# 的 `XCode:Cache:Ver:{table}`；`poll()` 比对远端版本后失效本地缓存；`DbCache` 过期项读取时顺手删除、`removeExpired()` 定时清理 |
| `src/dbpackage.zig` | `DataAccessLayer/DbPackage` | 表级导出/导入/跨库同步；文本包格式（`\N` / `\t` 转义 / 二进制 `0x<hex>`）；四种保存模式 |
| `src/reverse.zig`（扩展） | `DbMetaData.GetSchema` | 新增 **PostgreSQL**（`pg_class` + `information_schema` + `pg_index`）与 **SQL Server**（`INFORMATION_SCHEMA` + `sys.indexes`） |

**验证口径（如实说明）**：

- `setting` / `sqltemplate` / `expression` / `batch` / `dbcache` / `dbpackage` 全部有单元测试（真 SQLite 内存库），
  `zig build test` 退出码 0；
- `reverse` 的 **SQL Server**：只做了「类型映射」与「SQL 字面量转义」的单元测试，
  **取结构的 SQL 尚未在真库跑过**（本机无 SQL Server 实例）。按用户口径「先迁移代码，有环境再实测」记录在此，
  下次有实例时必须补真库用例（`zcodegen --reverse`）。
- `reverse` 的 **PostgreSQL**：**已在真库验证**（2026-11-12 晚，PG 16.2 本地实例）——
  `tests/integration_pg_real.zig` 建表后反读回列类型/主键/索引，并验证生成的 `Model.xml` 可再次解析。
  同一轮修掉了 `syncSchema` 的 `existingColumns()` 缺 PG 分支（原 `else => error.Unsupported` 让第二次同步必失败）。

## 3. 与 C#/Rust 的行为差异（有意为之）| 差异 | 原因 |
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
| 20+ 种小众方言（Access/ClickHouse/TDengine/DuckDB/Hana/Firebird/DB2/达梦/IRIS/MongoDB/NovaDb…）未实现 | ~~枚举与连接串可识别，但类型映射/DDL 明确 `error.Unsupported`~~ **已推翻（2026-11-12）**：19 家 SQL 方言全量实现并由 `zig build audit-dialects` 守住；只有 MongoDB（文档库）/ InfluxDB（Line Protocol）保持 `error.Unsupported` |

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
10. **`std.Thread.Mutex` / `std.Thread.Condition` / `std.Thread.sleep` 已移除**：同步原语楼到需要 `Io` 实例的
    `std.Io.Mutex`。本仓做法：用公共库 `zzig.compat.Mutex`（自旋 + `Thread.yield`）做临界区、`zzig.compat.sleep` 睡，
    并**不用条件变量**（worker 发现队列空就退出，下次 submit 重新拉起）。
11. **`zzig.Buf` 不暴露分配器**：需要临时分配时自己收 `gpa` 传进去，不能从 `Buf` 里拿。
12. **注释里不能出现制表符**：`error: comment contains invalid byte: '\t'`。文档注释里的表格用 `<TAB>` 占位。
13. **函数名不能是 `and`**（关键字）：`ConcatExpression.and` 改名 `append`。
14. **互相递归的函数不能用推导错误集**（`dependency loop with length 2`）：显式写 `RenderError!void`。

## 6. 覆盖台账（按 C# 源目录逐项对账）

> 口径：**已迁移** = Zig 有对应实现且有测试；**等价** = 语言机制不同但能力覆盖；
> **未做** = 还没有实现；**不适用** = 目标平台无对应机制。
> 这张表存在的意义：让「全部迁移完了吗」可以逐行核对，而不是凭印象。

| C# 目录 / 文件 | Zig 对应 | 状态 |
|---|---|---|
| `Attributes/`（BindColumn/BindIndex/BindTable/Map/ModelCheckMode/ModelSortMode） | `model.zig`（解析 `Model.xml` 属性）；Zig 无特性（Attribute）机制 | 等价 |
| `Cache/EntityCache`、`CacheBase` | `cache.Cache(T)`（整表 + 写后失效 + TTL） | 已迁移 |
| `Cache/` 的单对象缓存（`Meta.SingleCache` 语义） | `cache.SingleCache(T)` | 已迁移 |
| `Cache/FieldCache`（键列→值列整表字典） | `fieldcache.FieldCache`（物理列名工作、写后自动失效、TTL） | 已迁移 |
| `Cache/CacheInvalidator`（分布式版本号协调） | `dbcache.CacheInvalidator`（可插 Provider + `MemoryProvider`，`poll()` 发现变化即过期本地缓存） | 已迁移 |
| `Cache/DataCache`（运行数据缓存：表行数 + 字段键值） | `dbcache.DataCache`（文本档读写，可往返） | 已迁移 |
| `Cache/DbCache`（用表当缓存 + 过期清理） | `dbcache.DbCache`（Name/Value/CreateTime/ExpiredTime，列名可配） | 已迁移 |
| `Cache/LazyConsumer`（惰性串行消费者） | `dbcache.LazyConsumer`（空闲不占线程，严格按序） | 已迁移 |
| `Configuration/FieldExtension`、`FieldOption` | `model.ColumnMeta`（长度/精度/默认值/DataScale/Map/ShowIn 等） | 等价 |
| `Configuration/TableItem`（反射实体→模型） | 反向方向不需要：Zig 以 `Model.xml` 为唯一源；**正向**由 `codegen.zig`（`XCodeTool` 等价）完成 | 等价 |
| `Configuration/SqlTemplate`、`ShowInOption`、`ModelSortMode` | `sqltemplate.zig`（`-- [方言]` 分段、五区三态三写法、基类/派生类优先） | 已迁移 |
| `DataAccessLayer/DAL*.cs`、`IDbSession`、`DbSession` | `dal.zig`、`session.zig` | 已迁移 |
| `DataAccessLayer/Common/ConnectionPool` | `pool.zig` | 已迁移 |
| `DataAccessLayer/InsertBuilder`、`SelectBuilder` | `sqlbuild.zig`、`query.zig`（结构化条件）+ `pagesplit.zig` 的 `Builder` | 已迁移（SelectBuilder 只做了分页需要的子集） |
| `DataAccessLayer/MSPageSplit` | `pagesplit.zig`（`topNotIn` / `doubleTop` / `maxMin` / `rowNumber` + 选择顺序） | 已迁移 |
| `DataAccessLayer/WindowFunction` | `window.zig` | 已迁移 |
| `DataAccessLayer/ReadWriteStrategy` | `readwrite.zig` | 已迁移 |
| `DataAccessLayer/MetaData/*`（`DbMetaData.GetSchema`） | `reverse.zig`（SQLite / MySQL / PostgreSQL / SQL Server） | 已迁移（PG / SQL Server 的查结构 SQL 尚未在真库实测） |
| `DataAccessLayer/Database/*`（25 个驱动） | `dialect.zig`（**SQL 生成层全方言**：类型/DDL/分页/占位符/引用）+ `zzig.db.{sqlite,mysql,postgres,tds}` 执行层 | 部分：SQL 生成层齐了；执行层只有 4 家驱动（其余无客户端库/无实例） |
| `DataAccessLayer/DbPackage`（数据包导入导出） | `dbpackage.zig`（表级导出/导入/跨库同步，四种保存模式） | 部分：`.gz` / `zip` 多表归档与 Actor 并行未做 |
| `DataAccessLayer/XDbConnectionStringBuilder` | `dal.parseConnectionString` | 已迁移 |
| `Entity/Entity*`、`EntitySession`、`IEntityPersistence` | `entity.zig`、`dbtable.zig`、`interceptor.zig` | 已迁移（按表/对象/脏更新三层） |
| `Entity/EntityQueue`、`EntitySplit`、`EntityTransaction` | `entity_queue.zig`、`shards.zig`、`session.zig`（嵌套事务 + Scoped） | 已迁移 |
| `Entity/EntityExtension`（71KB 扩展方法集） | 部分：`entity.zig` 的 insert/save/update/find/query。`Clone`/`CopyFrom`/`Valid`/`ToDictionary` 等**未做** | 部分 |
| `Entity/IEntityModule`（实体模块钩子：Time/User/Trace） | `interceptor.zig`（审计列补全，等价于 ThreeModule） | 等价 |
| `Extension/数据缓存` | `cache.zig` | 已迁移 |
| `Linq/EntityQueryProvider`（表达式树 → SQL） | `query.zig`（结构化 `Where`，无表达式树） | 不适用（Zig 无 LINQ） |
| `Membership/*`（用户/角色/部门/菜单/租户/日志/参数/地区 + `DataScope`/`LogProvider`/`IManageProvider`） | `membership.zig`：`enums` / `password` / `datascope` / `log` / `rules` / `provider` + `entities/*`（9 张表由 `membership/Member.xml` 生成） | **大部分**：枚举与权限文本、口令散列 `md5+sha1` 字节互通、数据权限（上下文/翻译/掩码）、日志提供者（脏字段差量/口令屏蔽/LinkID）、各实体纯规则（角色 id 归一/年龄/抢管理员/类型推断/子菜单排序/租户角色/参数阈值）、`LoginCore` 八步 + 注册 + 改密、九张表实体。**待做**：`UserStore` 的真实 ORM 实现、`PinYin.GetFirst`（部门/租户 `Code` 依赖它，需迁移 GB2312 首字母表）、`Area` 地区算法（`FixName`/`MergeLevel3`/`Parse`） |
| `Model/WhereExpression`、`OrderExpression`、`FieldExpression`、`InExpression`、`LikeExpression` | `query.zig`（14 种运算符 + 排序/分页） | 已迁移 |
| `Model/ConcatExpression`、`FormatExpression` | `expression.zig`（`ConcatExpression` / `FormatExpression` / `FieldExpression` / `Expression`） | 已迁移 |
| `Model/BatchFinder`、`BatchOption` | `batch.zig`（批量 `IN` 预取 + 去重 + 可替换 loader；`BatchOption` 参数载体） | 已迁移 |
| `Model/Navigation*` | `navigation.zig` | 已迁移 |
| `Model/IPModule`、`TimeModule`、`TraceModule`、`UserModule` | `interceptor.zig` | 已迁移 |
| `Services/DbServer`、`DbService`、`DbClient`、`DbController` | `dbservice.zig`、`dbclient.zig`（服务端在 `zzig` HTTP） | 已迁移 |
| `Shards/*` | `shards.zig` | 已迁移 |
| `Statistics/*` | `stat.zig` | 已迁移 |
| `Transform/*` | `extract.zig` | 已迁移 |
| `Tree/EntityTree` | `tree.zig` | 已迁移 |
| `Exceptions/*` | `root.zig` 的 `Error` 错误集 + 具体错误名 | 等价 |
| `InfluxDB/`、`TDengine/`（时序库专用协议驱动） | — | **未做** |
| `XCodeTool/`（代码生成模板引擎） | `codegen.zig` + `tools/zcodegen.zig`（`Model.xml` → Zig 实体，带元数据/索引/辅助函数）+ `tools/gencheck.zig` 生成后自检 | 已迁移（Razor 模板引擎不适用：Zig 侧只需生成代码，不需要模板语言） |
| `Setting.cs`（全局配置：`DataAccessLayer`/`Debug`/`ShowSQL` 等） | `setting.zig`（字段与默认值逐项对齐 + `Key=Value` 读写） | 已迁移（无面板元数据） |

**一句话结论**：ORM 主链路（模型/方言/查询/会话/表/实体/缓存/分页/事务/迁移/远程服务/统计/抽取）已覆盖；
**`Membership` 已过六成**（枚举/口令/数据权限/日志/实体规则/登录核 + 九张表实体），
剩 `PinYin` 拼音首字母、`Area` 地区算法与 `UserStore` 的 ORM 适配；其次是 `EntityExtension` 的扩展方法集、
`InfluxDB` / `TDengine` 两个时序库驱动、`DbPackage` 的 zip 多表归档。
