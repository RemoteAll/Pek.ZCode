# Pek.ZCode — DH.NCode（XCode ORM）的 Zig 实现

> 语义与逻辑对齐 C# `DH.NCode`（`G:\Code\Pek.FrameWork\DH.NCode`）与 Rust `Pek.RCode`（`G:\Code\Rust\Pek.RCode`）：
> **共用同一份 `Model.xml`、共用同一个数据库**，生成的 SQL 文本与结构迁移行为可逐一对照。
> 详细对照见 [`docs/移植对照-NCode.md`](docs/移植对照-NCode.md)。
>
> 与 ORM 无关的通用件（Decimal / DateTime / 值模型 / SQLite 驱动 / 字符串缓冲 / 临时文件）
> 已下沉到公共库 **`zzig`**（`G:\Code\Zig\zzig`），本包只保留 XCode 语义层。

## 当前范围（v0.1.0 第一轮）

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
| `dbtable` | `EntitySession` / `TableRef` | ✅ insert / update / delete / find_by_pk / query / count |
| `entity` | `Entity`（对象实体） | ✅ 脏字段更新（只写变化列、无变化不发 SQL）、insert/save/update/delete/find/query/count、`insert_only`/视图保护 |
| `batch` | `EntityExtension`（批量写） | ✅ `insertBatch`（多行 VALUES，按方言参数上限分批）/ `deleteByPkBatch` / `saveBatch`（新增合并批插、已有按脏列逐条更新） |
| `codegen` + `zcodegen` | `XCodeTool` / `rcodegen` | ✅ `Model.xml` → Zig 实体（meta/脏位图/访问器/取值与装载） |
| `dal` | `DAL` | ✅ 连接串解析、模型持有、`sync_schema` 增量建表/补列/建索引（幂等） |

**本轮未做**（后续轮次）：对象实体与脏字段更新、整表/单对象缓存、批量写、分表、
其它数据库驱动、反向工程、备份、代码生成器、读写分离。

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
powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1   # 一键回归
```

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

## 语义要点（与 C#/Rust 一致的部分，易被误判）

- `Nullable` 缺省为 **false**（即 NOT NULL）——`Model.xml` 不写 `Nullable="True"` 的列必须有值。
- SQLite 的 `decimal` 列是 **NUMERIC 亲和度**：`"12.3400"` 入库后会变成 `12.34`，尾随零在存储层就丢了（C# 侧同样如此）。
  需要逐字保留请用 `DataType="String"`/`"Text"`。
- SQLite 的 `String` 列建表带 `COLLATE NOCASE`（XCode 约定）。
- 结构同步 **只增不减**：缺表建表、缺列补列、缺索引建索引；不删列、不改列类型、不删索引。
