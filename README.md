# Pek.ZCode — DH.NCode（XCode ORM）的 Zig 实现

> 语义与逻辑对齐 C# `DH.NCode`（`G:\Code\Pek.FrameWork\DH.NCode`）与 Rust `Pek.RCode`（`G:\Code\Rust\Pek.RCode`）：
> **共用同一份 `Model.xml`、共用同一个数据库**，生成的 SQL 文本与结构迁移行为可逐一对照。
> 详细对照见 [`docs/移植对照-NCode.md`](docs/移植对照-NCode.md)。
>
> 与 ORM 无关的通用件（Decimal / DateTime / 值模型 / SQLite 驱动 / 字符串缓冲 / 临时文件）
> 已下沉到公共库 **`zzig`**（`G:\Code\Zig\zzig`），本包只保留 XCode 语义层。

## 当前范围（v0.1.0）

| 模块 | 对应 DH.NCode / Pek.RCode | 状态 |
|---|---|---|
| `types` | `DataType`（CLR 类型名） | ✅ 12 种类型 + 宽松别名解析 |
| `zzig.Decimal` | C# `Decimal` | ✅ 尾数×10^-scale 表示、解析/格式化（保留尾随零）/数值比较 |
| `zzig.DateTime` | XCode 时间口径 | ✅ 7 位小数秒解析与格式化、Unix 秒换算 |
| `zzig.db.Value` | 字段值 / `DbType` 转换 | ✅ 跨类型取值、SQL 字面量渲染 |
| `model` | `Model.xml` / `EntityModel` | ✅ 解析 + 写出（往返一致）、未识别属性原样保留 |
| `dialect` | 各 `DbBase` 子类 | ✅ SQLite / MySQL / SQL Server / PostgreSQL（含金仓/瀚高/海量）/ Oracle：类型映射、DDL、索引、分页 |
| `query` | `WhereExpression` / `PageParameter` | ✅ 14 种条件运算符、`IN` 空集恒假/恒真、多列 `OR` |
| `sqlbuild` | `InsertBuilder` / `SelectBuilder` | ✅ INSERT / UPDATE / DELETE / SELECT / COUNT |
| `session` | `IDbSession` | ✅ 同步会话：execute / query / 标量 / 自增回写 |
| `zzig.sqlite` | `SQLite.cs` | ✅ **动态加载** `sqlite3.dll` / `winsqlite3.dll`，不链 libc |
| `zzig.mysql` | `MySql.cs` / `DH.MySql` | ✅ **绿色版纯协议驱动**：握手 v10 + `mysql_native_password` / `caching_sha2`（fast auth **与完整鉴权 RSAES-PKCS1-v1_5**）、`COM_QUERY`、预处理二进制协议（参数绑定）、结果集解码；不加载 libmysqlclient |
| `zzig.postgres` | `PostgreSQL.cs` | ✅ **纯协议驱动（协议 3.0）**：Trust / Cleartext / **MD5** / **SCRAM-SHA-256** 鉴权、简单查询与扩展查询（参数 text 格式）、文本结果解码、影响行数；不依赖 libpq |
| `dbtable` | `EntitySession` / `TableRef` | ✅ insert / update / delete / find_by_pk / query / count / `insertBatch` / **`loadDataBatch`（MySQL LOCAL INFILE，实测比多行 INSERT 快 ≈4×）** |
| `entity` | `Entity`（对象实体） | ✅ 脏字段更新（只写变化列、无变化不发 SQL）、insert/save/update/delete/find/query/count、`insert_only`/视图保护 |
| `batch` | `EntityExtension`（批量写） | ✅ `insertBatch`（多行 VALUES，按方言参数上限分批）/ `deleteByPkBatch` / `saveBatch`（新增合并批插、已有按脏列逐条更新） |
| `cache` | `Meta.Cache`（整表实体缓存） | ✅ TTL 过期同步重载（Blocking 一致性）、主键 O(1) 命中、**写后自动失效**、`ttl=0` 不过期；另有 `SingleCache`（单对象缓存，按主键缓存单行） |
| `codegen` + `zcodegen` | `XCodeTool` / `rcodegen` | ✅ `Model.xml` → Zig 实体（meta/脏位图/访问器/取值与装载） |
| `reverse` + `zcodegen --reverse` | `DbMetaData.GetSchema` + XCodeTool 反查 | ✅ 现有库 → `Model.xml`（SQLite：`sqlite_master`+`PRAGMA`；MySQL：`information_schema`；含列型/主键/自增/索引/注释） |
| `dal` | `DAL` | ✅ 连接串解析、模型持有、`sync_schema` 增量建表/补列/建索引（幂等）；`Full` 档删列删索引；表级档位只能收紧 |
| `readwrite` + `Dal.readSessionFor` | `ReadWriteStrategy` / `DAL.Reads` | ✅ 忽略表（大小写不敏感）、全局切主库、轮询从库；**从库会话强制只读**，无从库自动回落主库 |
| `pool` + `Dal.makePool` | ADO.NET 连接池 / Rust `pool.rs` | ✅ 上限（超限直接 `PoolExhausted`，不排队）、空闲超时回收、预热、统计；`:memory:` 不建议池化 |
| `shards` + `Dal.tableShard` | `TimeShardPolicy` / `EntitySplit` | ✅ 时间分表（`{0}_{1:yyyyMM}` 等）、连接模板、区间扫描（支持倒序）、条件推导、雪花 Id；✅ **跨库分片**（`attachConnection` + `sessionForConn`）与**分片表自动建表**（`ensureShardTable`，幂等） |
| `interceptor` | `TimeModule` / `UserModule` / `TraceModule` | ✅ 插入补审计列、更新刷新；单条与批量都生效；`allow_empty=false` 时无用户直接报错 |
| `entity_queue` | `EntityDeferredQueue` | ✅ 按条数/时间触发 `saveBatch`；**flush 失败保留队列**便于重试；deinit 不自动 flush |
| `navigation` | `NavigationLoader` | ✅ 单条 / 列表 / **`fillMany` 批量填充（消除 N+1）** |
| `tree` | `Tree/EntityTree` | ✅ 子节点 / 后代（BFS，一层一次 `IN`）/ 向上路径 / 根节点；深度与节点数护栏（成环明确报错） |
| `backup` | `DAL_Backup` | ✅ SQLite 原生快照（`VACUUM INTO`，校验非 0 字节）+ SQL 脚本（结构同源 DDL + 字面量安全，SQLite/MySQL） |

**本轮未做**（已写进 `docs/移植对照-NCode.md`，不是遗忘）：远程服务（`DbServer`/`DbService`）、
SQL Server（TDS）与 Oracle（OCI/TNS）**执行驱动**、MySQL TLS / 压缩 / LOCAL INFILE。

MySQL 驱动的能力边界：口径以 **C# 绿色版 `G:\Code\Pek.FrameWork\DH.MySql`** 为准 ——
开启 `CLIENT_FOUND_ROWS`（`affected_rows` = **匹配行数**，XCode 语义）、`MULTI_STATEMENTS`/`MULTI_RESULTS`、
`caching_sha2` 完整鉴权（**RSAES-PKCS1-v1_5**，真库实测：OAEP 服务端回 1045）；BIT 按**大端**还原（真库实测）。
**不支持**：TLS（`CLIENT_SSL` 不发）、压缩协议、LOCAL INFILE。
真库验证：`zig build integration -Dmysql-conn="Server=...;Port=3306;Database=...;Uid=...;Pwd=..."`。

## 快速开始

```zig
const zcode = @import("zcode");

// 1) 复用 C# 项目里的 Model.xml
var dal = try zcode.Dal.open(gpa, "Data Source=..\\Data\\DG.db;Provider=SQLite", "Entity/Model.xml");
defer dal.deinit();

// 2) 增量同步结构（只建表/补列/建索引，不删不改）
var s = try dal.openSession();
defer s.deinit();
const report = try dal.syncSchema(&s);
std.debug.print("{s}\n", .{try report.describeAlloc(gpa)});

// 3) 表级 CRUD
const t = try dal.table("JiLiYu");
_ = try t.insert(&s, &[_]zcode.sqlbuild.Field{
    .{ .name = "Code", .value = .{ .text = "k-001" } },
    .{ .name = "CreateTime", .value = .{ .datetime = zcode.DateTime.nowLocal() } },
});

const row = (try t.findByPk(&s, &.{.{ .int = 1 }})).?;
const n = try t.count(&s, null);

var w = zcode.Where.init(gpa);
defer w.deinit();
_ = try w.like("Code", "k-%");
var q = zcode.Query.init(gpa);
defer q.deinit();
_ = q.filterWhere(&w).page(1, 20);
const rows = try t.queryRows(&s, &q);
```

## 构建与测试

```powershell
zig build            # 编译校验
zig build test       # 单元测试 + 集成测试（需要本机有 sqlite3.dll 或 winsqlite3.dll）
zig build unit       # 仅单元测试
zig build integration# 仅集成测试
zig build bench      # 性能基准（ReleaseFast，打印各组单次耗时）
powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1   # 一键回归
```

真库（MySQL）集成测试需要本机有实例，用连接串显式开启，不给则打印 `SKIP`：

```powershell
powershell -File tools/mysql-local.ps1 -Action setup   # 一次性：建 3307 端口便携实例
zig build integration -Dmysql-conn="Provider=MySQL;Server=127.0.0.1;Port=3307;Database=zcode_test;UserID=root;Password="
# MySQL 批量写基准：insertBatch vs LOAD DATA LOCAL INFILE（20000 行）
zig build bench-mysql -Dmysql-conn="Provider=MySQL;Server=127.0.0.1;Port=3307;Database=zcode_test;UserID=root;Password="
```

PostgreSQL 同理：`zig build integration -Dpg-conn="Provider=PostgreSQL;Server=127.0.0.1;Port=5432;Database=demo;UserID=pg;Password=…"`
（**没给 `-Dpg-conn` 时，PG 只跑回环假服务端用例**——协议层在 `zzig` 里已完整覆盖，不依赖真库。）

SQLite 加载顺序：**exe 同目录 `sqlite3.dll` → 当前目录 `sqlite3.dll` → 系统 `sqlite3.dll` → `winsqlite3.dll`**。
要在 Win7 上运行，把一份自带运行时的 `sqlite3.dll` 放到 exe 同目录即可（无需重新编译）。

## 绿色版（便携自检）

```powershell
zig build                    # 产出 zig-out/bin/zcode-green.exe
zig build green-test         # 直接跑自检（临时库，失败则退出码非 0）
.\zig-out\bin\zcode-green.exe --db D:\tmp\a.db --reset
```

绿色版不安装、不配置：用内置 `examples/demo-model.xml` 建表，依次验证
插入（自增回写）/ 按主键取 / **脏字段更新（不整行覆盖）** / 无脏列不发 SQL /
条件分页 / 计数 / save / 删除。实体来自 `zcodegen` 生成（`examples/entities/`），
所以它同时是生成产物的编译 + 运行校验。

```powershell
# 从生产 Model.xml 生成实体
zig build codegen -Dmodel=Entity/Model.xml -Dout=src/entities
```

## 性能基准（`zig build bench`）

`tools/bench.zig`，SQLite 内存库 + `ReleaseFast` + 单事务批量提交，本机实测（Windows / zig 0.17.1）：

| 用例 | 次数 | 总耗时 | 单次 |
|---|---|---|---|
| 实体 insert（含自增回写） | 500 | 2.60 ms | **5.21 µs** |
| 批量 saveBatch（新增 2000 条） | 2000 | 4.91 ms | **2.46 µs/条** |
| findByPk（直连库，命中） | 2000 | 3.59 ms | **1.80 µs** |
| 整表缓存 get（命中） | 20000 | 0.24 ms | **0.01 µs** |
| 条件分页查询（10 行） | 300 | 3.45 ms | **11.49 µs** |
| 分表路由（单点 → 表名） | 20000 | 2.27 ms | **0.11 µs** |
| insert + 时间拦截器 | 500 | 3.00 ms | **6.00 µs** |
| 导航批量填充（5 主键） | 200 | 34.09 ms | **170 µs** |

> 会话内置 **SQLite 预处理语句缓存**（同一 SQL 复用，省 prepare/finalize）；
> 换掉它以后主键查 **4.52 → 1.80 µs（−60%）**、insert **7.53 → 5.21 µs**、分页 **14.96 → 11.49 µs**。
> 绝对数字随机器负载浮动，**跨轮次不能相减**，只用于同机同轮对比。

回归口径：基准**不进门禁**（机器抖动会误报），只作信息项；改 SQL 生成 / 缓存路径后手动跑一次对比。

### MySQL 批量写（`zig build bench-mysql`）

真库实测（MySQL 8.0.29 / 本机 3307，20000 行 × 5 列，两次取样）：

| 方式 | 总耗时 | 每行 | 吞吐 |
|---|---|---|---|
| `insertBatch`（多行 INSERT） | 733~897 ms | 36.6~44.9 µs | 2.2~2.7 万行/秒 |
| **`loadDataBatch`（LOCAL INFILE）** | **194~224 ms** | **9.7~11.2 µs** | **8.9~10.3 万行/秒** |

**约 3.8~4.0 倍**：多行 INSERT 要逐行做 SQL 语法分析，LOCAL INFILE 走行式解析器。
万行以上的日志/采集/导入优先用 `loadDataBatch`（它**不回写每行自增 ID**，需要 ID 就用 `insertBatch`/`saveBatch`）。

## 语义要点（与 C#/Rust 一致的部分，易被误判）

- `Nullable` 缺省为 **false**（即 NOT NULL）——`Model.xml` 不写 `Nullable="True"` 的列必须有值。
- SQLite 的 `decimal` 列是 **NUMERIC 亲和度**：`"12.3400"` 入库后会变成 `12.34`，尾随零在存储层就丢了（C# 侧同样如此）。
  需要逐字保留请用 `DataType="String"`/`"Text"`。
- SQLite 的 `String` 列建表带 `COLLATE NOCASE`（XCode 约定）。
- 结构同步 **只增不减**：缺表建表、缺列补列、缺索引建索引；不删列、不改列类型、不删索引。
