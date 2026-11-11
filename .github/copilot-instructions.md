# Pek.ZCode · 项目指令

> 全项目通用规则见用户级《跨项目接续协议》（本机 `%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md`，模板在 `tools/continuity/templates/`，当前版本 **2026.11.10.2**）。
> **开工先读（存在则读，按序）**：`.github/copilot-instructions.md` → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` → `docs/决策记录.md` 最新节。
> **机器自愈（有则快跑）**：`tools/continuity/install-global-instruction.ps1`（幂等：缺失补装 / 过旧更新 / 一致不动；VS Code 打开本项目时 `.vscode/tasks.json` 也会自动跑）。

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；
② `powershell -NoProfile -ExecutionPolicy Bypass -File tools/continuity/sync-memory.ps1` 同步记忆；
③ `powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1` 并**贴实际输出**（构建退出码 / 测试失败数 / SKIP 原因），不接受口头「已通过」。

## 项目现状（2026-11-11）

- 定位：**DH.NCode / Pek.RCode 的 Zig 实现**（共用 `Model.xml` 与数据库），逐项对照见 `docs/移植对照-NCode.md`。
- 已实现：`model` / `types` / `value` / `decimal` / `datetime` / `dialect`（SQLite、MySQL、SQL Server、
  PostgreSQL 系、Oracle）/ `query` / `sqlbuild` / `session`（含事务）/ **SQLite + MySQL 执行驱动** /
  `dbtable` / `dal`（增量建表）/ 对象实体与脏更新 / 批量写 / 整表缓存 + 单对象缓存 / **反向工程** / 代码生成。
- 未实现：分表、读写分离、SQL Server/PostgreSQL/Oracle 执行驱动、备份、MySQL TLS/压缩/LOCAL INFILE。
- 测试：`zig build test`（单元 48 + 集成 14，**62 项全通过**）；真库另跑
  `zig build integration -Dmysql-conn="…"`（14/14）；zzig 侧 84 项；`tools/regression.ps1` 已接入构建与测试。
- 性能：`zig build bench`（ReleaseFast）出数字，实测 insert 7.53 µs / 批量 2.20 µs 条 / 主键查 4.52 µs /
  缓存命中 0.01 µs / 分页 14.96 µs。**基准不进门禁**（机器抖动会误报），改热路径后手动对比。

## 工具链口径（本机实测）

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
