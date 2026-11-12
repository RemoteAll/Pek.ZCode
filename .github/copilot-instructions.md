# Pek.ZCode · 项目指令

> 全项目通用规则见用户级《跨项目接续协议》（本机 `%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md`，模板在 `tools/continuity/templates/`，当前版本 **2026.11.11.1**）。
> **开工先读（存在则读，按序）**：`.github/copilot-instructions.md` → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` → `docs/决策记录.md` 最新节。
> **机器自愈（有则快跑）**：`tools/continuity/install-global-instruction.ps1`（幂等：缺失补装 / 过旧更新 / 一致不动；VS Code 打开本项目时 `.vscode/tasks.json` 也会自动跑）。

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；
② `powershell -NoProfile -ExecutionPolicy Bypass -File tools/continuity/sync-memory.ps1` 同步记忆；
③ `powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1` 并**贴实际输出**（构建退出码 / 测试失败数 / SKIP 原因），不接受口头「已通过」。

## 项目现状（2026-11-11）

- 定位：**DH.NCode / Pek.RCode 的 Zig 实现**（共用 `Model.xml` 与数据库），逐项对照见 `docs/移植对照-NCode.md`。
- 已实现：`model` / `types` / `value` / `decimal` / `datetime` / `dialect`（SQLite、MySQL、SQL Server、
  PostgreSQL 系、Oracle）/ `query` / `sqlbuild` / `session`（含事务 + **SQLite 语句缓存**）/ **SQLite + MySQL + PostgreSQL 执行驱动** /
  `dbtable` / `dal`（增量建表 + `Full` 删列删索引 + 表级档位收紧）/ 对象实体与脏更新 / 批量写 / 整表缓存 + 单对象缓存 /
  **分表分库（含跨库分片与分片表自动建表）** / **读写分离** / **连接池** / **写入拦截器** / **延迟写队列** / **导航属性** / **树形实体** /
  **备份** / **反向工程**（SQLite·MySQL·PostgreSQL·SQL Server） / 代码生成。
- 2026-11-12 第二十一~二十二轮补齐：`fieldcache` / `setting`（XCodeSetting 等价） / `sqltemplate` / `expression` /
  `batch`（BatchFinder+BatchOption） / `dbcache`（LazyConsumer+CacheInvalidator+DataCache+DbCache） /
  `dbpackage`（表级导出·导入·跳库同步，无 zip 归档）。
- 未实现：SQL Server（TDS）/ Oracle（OCI）、C# `DbTable` v3 二进制互通（`Db/Query` 现为 JSON 行列）。
  远程服务已做：`src/dbservice.zig` + `src/dbclient.zig`（HTTP/1.1 服务端在 `zzig/src/http/server.zig`）。
- MySQL TLS 已支持（`SslMode` 五档，缺省 `Preferred`）：连接串认 `SslMode` / `SslCa`（`None|Disabled|Preferred|Required|VerifyCA|VerifyFull`，认不出报 `error.InvalidSslMode`）。
- MySQL 压缩协议已支持（连接串 `Compression=True`，缺省关）：认证 OK 后所有包套一层 zlib 压缩帧，
  与 TLS 可叠加（压缩在 TLS 内层）；服务端不支持时明确打印而不是静默当成功。
  **供应商化文件 `zzig/src/db/tls_client.zig`**：std TLS 客户端副本 + 补 `CertificateRequest`（MySQL 8 默认 `ssl_ca` 必发这条，std 不处理会连不上）；
  改它前先看头部注释，std 支持后应整个删掉。
- 测试：`zig build test`（**单元 176 项全通过**；集成 72 项，其中 PG / MySQL 真库用例需连接串，未给时显式 SKIP）；真库另跑
  `zig build integration -Dmysql-conn="…" [-Dmysql-ca="…"]` / `-Dpg-conn="…"`；zzig 侧 **99 项**（自测 25 + XML 27 + 模块 47，含 PG 回环、MySQL LOCAL INFILE、TLS、压缩、HTTP/1.1 服务端）；`tools/regression.ps1` 已接入构建与测试。
- 方言覆盖：`zig build audit-dialects`（**19/19 可实现方言无缺口**；不连库，纯 SQL 生成层），已进 `tools/regression.ps1`。
  改 `src/dialect.zig` 的 `else` 分支后必跑（`else =>` 默认分支是静默错误高发区）。
- 性能：`zig build bench`（ReleaseFast）出数字，实测 insert 5.21 µs / 批量 2.46 µs 条 / 主键查 1.80 µs /
  缓存命中 0.01 µs / 分页 11.49 µs / 分表路由 0.11 µs / 拦截器开销 +0.8 µs / 导航批量填充 170 µs。
  **基准不进门禁**（机器抖动会误报），改热路径后手动对比。
- MySQL 带参语句已做**预处理句柄复用**（按 SQL 文本缓存，默认 32 条 FIFO）：`zig build bench-mysql` 同进程 A/B
  实测点查 **1.64×**、单行插入（同事务）**1.62×**；`setStmtCacheLimit(0)` 可关掉做对比，`stmtCacheStats()` 看命中率。

## 工具链口径（本机实测）

- **本地真库**（免安装，数据在仓库 `.tools\` 下，已 gitignore）：
  - MySQL：`tools/mysql-local.ps1`（3307，`G:\Tools\mysql-portable\mysql-8.0.29-winx64`）
  - PostgreSQL：`tools/pg-local.ps1`（5433，`G:\Tools\pgsql-portable\pgsql`，PG 16.2，来自阿里云 Maven 的 zonky 包）
  - SQL Server：只有 **LocalDB**（`tools/mssql-local.ps1`）——它**只支持 Windows 认证且不开 TCP**，
    ZCode 的 TDS 驱动（仅 SQL 账号认证）**连不上**；只能 `sqlcmd` 手工验证。驱动级真库验证需要 SQL Server Express。
  - `tools/regression.ps1` 会探测 5433/3307，在跑就自动带上真库用例，不在跑就显式 SKIP（不会静默跳过）。

- `zig 0.17.1`（VS Code Zig 扩展托管，`zig.exe` 已在 PATH；0.17.0 已验证同行为）；构建产物目录 `.zig-cache/`、`zig-out/`（已进 `.gitignore`）。
- **依赖公共库 `G:\Code\Zig\zzig`**（path 依赖）：`zzig.xml` + 通用件 `zzig.Decimal` / `zzig.DateTime` /
  `zzig.db.Value` / `zzig.db.sqlite` / `zzig.Buf` / `zzig.File`。**这些能力只在 zzig 改，本仓不要再复制一份**；
  改 zzig 后必须跑 `cd ..\zzig; zig build test`（并连带回归本仓）。
- **验证一律走分档**：`zig build` / `zig build test` 只做编译与测试验证；`zig build bench` 只出性能数字（不进门禁）；
  `dist/` 打包只在用户明确说「打包 / 出包 / 部署」时才做。
- **Zig 0.17 与旧版差异已踩过**（`std.DynLib` 不支持 Windows、`time.timestamp`/`crypto.random`/`fs.cwd`/`dupeZ` 移除等），
  详见 `docs/移植对照-NCode.md` 第 4 节——写新代码前先看，别按 0.15/0.16 的记忆写。

## 仓库约定（沿用已装备的 Zig 仓库）

- `.gitattributes`：`*.zig` / `*.md` / `*.zon` 存 LF、`*.ps1` 存 CRLF、二进制显式声明。**`tools/continuity/templates/*.md` 必须保持 LF**——`install-global-instruction.ps1` 用 SHA256 与本机副本比对，换行被改写会误判成「版本不一致」并把 CRLF 回灌本机。
- 含中文的 `.ps1` **必须 UTF-8 with BOM**（PS 5.1 按 GBK 读无 BOM 文件会直接 ParserError）；调外部命令后一律判 `$LASTEXITCODE`。
- **不要用 PowerShell 读写源码**（`Get-Content -Raw` + `WriteAllText` 会按 GBK 解码破坏 UTF-8）；一律用编辑工具。
- **提交信息一律中文**：用 `create_file` 直接写 UTF-8 消息文件，再 `git commit -F <文件>`；不要 `git commit -m "中文"`（PS 5.1 会按 gb2312 存进提交）。
