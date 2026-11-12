#Requires -Version 5.1
<#
.SYNOPSIS
  项目内 PostgreSQL 测试实例（绿色版/免安装）管理：初始化、启动、停止、状态、重置。
.DESCRIPTION
  为什么需要：PostgreSQL 驱动与 PG 反向工程要「真库验证」才算数（本机没有服务、没有 Docker）。
  本脚本用免安装版 `initdb` / `pg_ctl` 在项目内起一个**独立实例**（默认端口 5433），
  数据目录放在仓库的 `.tools\pg\data-5433`（已 gitignore），**重启机器后仍在**，可反复复用。

  二进制目录默认自动探测（本机已有绿色版就不再下载），也可 `-Dist` 显式指定；
  找不到时打印获取方式要求先放置，绝不静默跳过。

  自动创建（幂等）：
    - 数据库 `zcode_test`
    - 角色 `zcode` / `zcode_pwd`：`scram-sha-256`（PG 默认档，验证 SCRAM 鉴权）
    - 角色 `zcode_md5` / `zcode_pwd`：`md5`（验证 MD5 鉴权分支）
    - 角色 `zcode_trust`：无密码 + `trust`（验证最简单的连接路径）
  pg_hba.conf 按「先具体后宽泛」排：先给三个测试角色单独开对应鉴权方式，
  再用 `host all all 127.0.0.1/32 trust` 兜底，这样三种鉴权都能在同一个实例上验证。

.PARAMETER Action
  setup（初始化+启动+建库建角色，幂等）/ start / stop / status / reset（删数据目录重建）
.PARAMETER Port
  实例端口，默认 5433（避免和已有的 5432 冲突；ZCode 的 PG 集成用例默认也用 5433）
.PARAMETER Dist
  `pg_ctl.exe` 所在目录的**上级**（即含 `bin\pg_ctl.exe` 的目录），默认自动探测
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\pg-local.ps1 -Action setup
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\pg-local.ps1 -Action status
.NOTES
  本脚本含中文，必须以 UTF-8 with BOM 保存（PS 5.1 按 ANSI 读无 BOM 会 ParserError）。
#>
param(
    [ValidateSet('setup', 'start', 'stop', 'status', 'reset')]
    [string]$Action = 'setup',
    [int]$Port = 5433,
    [string]$Dist = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$base = Join-Path $root '.tools\pg'
$data = Join-Path $base "data-$Port"
$log = Join-Path $base "pg-$Port.log"
$hba = Join-Path $data 'pg_hba.conf'

if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }

function Write-Step([string]$text) { Write-Host "[pg-local] $text" }

# PS 5.1：$ErrorActionPreference='Stop' 会把外部程序写 stderr 当终止错误 —— 统一包一层。
# 另外必须带**超时**：initdb / pg_ctl 在参数不对时会转到交互提示，而管道捕获会把提示吞掉，
# 表现为「脚本静默卡死」（本轮真踩：`--pwfile` 无换行 → initdb 等密码输入，卡了 5 分钟看不出来）。
function Invoke-Exe([string]$exe, [string[]]$argList, [int[]]$OkCodes = @(0), [int]$TimeoutSec = 180, [switch]$NoCapture) {
    # 参数拼接：只给含空格的参数加引号（否则 "-p 5433 -c ..." 会被拆开）
    $quoted = foreach ($a in $argList) {
        if ($a -match '\s' -and -not $a.StartsWith('"')) { '"' + $a + '"' } else { $a }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    if (-not $NoCapture) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
    }
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    if ($NoCapture) {
        # pg_ctl 必须走这条路：它会拉起 postgres 长命进程，子进程继承重定向句柄后
        # `ReadToEnd()` 永远不会结束（实测：pg_ctl 已退出但脚本卡在读输出）。
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            throw "命令超时（${TimeoutSec}s）：$exe $($psi.Arguments)"
        }
        $code = $p.ExitCode
        if ($OkCodes -notcontains $code) { throw "命令失败（退出码 $code）：$exe $($psi.Arguments)" }
        return ''
    }

    # 先异步读，避免缓冲区写满导致双方互等
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw "命令超时（${TimeoutSec}s）：$exe $($psi.Arguments)`r`n（常见原因：参数不对时转成交互提示）"
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    $out = "$($outTask.Result)$($errTask.Result)"
    if ($OkCodes -notcontains $code) {
        throw "命令失败（退出码 $code）：$exe $($psi.Arguments)`r`n$out"
    }
    return $out
}

function Find-Dist {
    if ($Dist) {
        if (Test-Path (Join-Path $Dist 'bin\pg_ctl.exe')) { return (Resolve-Path $Dist).Path }
        throw "指定的 -Dist 里没有 bin\pg_ctl.exe：$Dist"
    }
    $candidates = @(
        'G:\Tools\pgsql-portable\pgsql',
        'G:\Tools\pgsql-portable'
    )
    foreach ($root2 in @('G:\Tools', 'E:\Soft', 'C:\Tools')) {
        if (-not (Test-Path $root2)) { continue }
        Get-ChildItem -Path $root2 -Directory -Filter 'pgsql*' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            ForEach-Object { $candidates += $_.FullName }
    }
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'bin\pg_ctl.exe')) { return (Resolve-Path $c).Path }
    }
    throw @'
未找到免安装版 PostgreSQL（bin\pg_ctl.exe）。两种获取方式：

  1) 精简版（约 46 MB，推荐，来自 theseus-rs/postgresql-binaries）：
     https://github.com/theseus-rs/postgresql-binaries/releases
     下载 postgresql-<ver>-x86_64-pc-windows-msvc.zip，解压到 G:\Tools\pgsql-portable

  2) 官方 EDB 二进制包（约 323 MB）：
     https://www.enterprisedb.com/download-postgresql-binaries

然后用 -Dist 指定含 bin\pg_ctl.exe 的目录：
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\pg-local.ps1 -Action setup -Dist "G:\Tools\pgsql-portable\pgsql"
'@
}

function Test-Port([int]$p) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $c.Connect('127.0.0.1', $p)
        return $true
    } catch {
        return $false
    } finally {
        $c.Dispose()
    }
}

function Write-PgHba {
    # 双档鉴权（一个实例覆盖两种路径）：
    #   db=postgres  → trust（无密码即可连，用于用例自行建库/建 schema）
    #   其它库       → scram-sha-256（PG 默认档，验证 SCRAM 握手）
    # 顺序很重要：pg_hba 首条匹配生效，所以具体库必须写在前面。
    $text = @"
# 由 tools/pg-local.ps1 生成，请勿手改（重跑 setup 会覆盖）
# TYPE  DATABASE  USER      ADDRESS        METHOD
local   all       all                      trust
host    postgres  all       127.0.0.1/32   trust
host    all       all       127.0.0.1/32   scram-sha-256
host    all       all       ::1/128        scram-sha-256
"@
    [IO.File]::WriteAllText($hba, $text, (New-Object Text.UTF8Encoding($false)))
}

$distPath = Find-Dist
$pgCtl = Join-Path $distPath 'bin\pg_ctl.exe'
$initdb = Join-Path $distPath 'bin\initdb.exe'
# `Start-Process -ArgumentList` 会按空格重新拼命令行，`-o` 的值必须自带引号，否则 "-p 5433" 会被拆成两个参数
# （实测报错：pg_ctl: 无效的操作模式 "5433"）
$startOpts = '-p ' + $Port + ' -c listen_addresses=127.0.0.1'

switch ($Action) {
    'status' {
        Write-Step "dist  : $distPath"
        Write-Step "data  : $data"
        $running = Test-Port $Port
        Write-Step "port  : $Port（$running 可连）"
        if (Test-Path $data) {
            $out = Invoke-Exe $pgCtl @('-D', $data, 'status') @(0, 3)
            Write-Step ("pg_ctl: " + ($out.Trim() -replace "`r`n", ' / '))
        } else {
            Write-Step 'pg_ctl: 数据目录不存在（先跑 -Action setup）'
        }
        if (Test-Path $log) { Write-Step "日志  : $log" }
        break
    }
    'stop' {
        if (Test-Path $data) {
            Invoke-Exe $pgCtl @('-D', $data, '-m', 'fast', 'stop') @(0, 1, 3) -NoCapture | Out-Null
        }
        Write-Step '已停止'
        break
    }
    'reset' {
        & $PSCommandPath -Action stop -Port $Port -Dist $distPath
        if (Test-Path $data) { Remove-Item -Recurse -Force $data }
        Write-Step "数据目录已删除：$data"
        break
    }
    'start' {
        if (-not (Test-Path $data)) { throw "数据目录不存在：$data（先跑 -Action setup）" }
        if (Test-Port $Port) { Write-Step "端口 $Port 已可连，跳过启动"; break }
        Invoke-Exe $pgCtl @('-D', $data, '-l', $log, '-o', $startOpts, '-w', 'start') @(0, 1, 3) -NoCapture | Out-Null
        if (-not (Test-Port $Port)) { throw "启动后端口 $Port 仍不可连，请看日志 $log" }
        Write-Step "已启动（端口 $Port）"
        break
    }
    'setup' {
        Write-Step "dist  : $distPath"
        Write-Step "data  : $data"

        # 先停掉在跑的实例：否则 initdb 会写进一个正被占用的目录、pg_ctl start 也会因端口占用而卡住
        # （实测踩过：旧实例还在跑时跑 setup，脚本在 start 处静默挂 5 分钟以上）
        if (Test-Path $data) {
            if (Test-Port $Port) {
                Write-Step '检测到实例在跑，先停止'
                Invoke-Exe $pgCtl @('-D', $data, '-m', 'fast', 'stop') @(0, 1, 3) -NoCapture | Out-Null
                Start-Sleep -Seconds 1
            }
        } else {
            # 数据目录不存在但端口被占：说明是别的实例或残留进程，明确报错而不是硬启
            if (Test-Port $Port) { throw "端口 $Port 已被占用，但数据目录不存在：$data（先排查占用进程）" }
        }

        if (-not (Test-Path $data)) {
            Write-Step '初始化数据目录（initdb：superuser=postgres，TCP 走 scram）'
            # 为什么要 --pwfile：精简版没有 psql，建不了角色；用 initdb 直接给 superuser 设密码，
            # 这样 scram-sha-256 鉴权路径不需要任何后置 SQL 就能验证。
            # 为什么 --no-locale：精简版二进制不带 locale 数据，用 C locale 最稳。
            # 注意：postgres.exe 直接启动会拒管理员身份（"不允许管理员权限的用户运行"），
            # 但 `initdb` 与 `pg_ctl` 内部会创建受限令牌，所以在管理员会话里也能正常工作。
            $pwFile = Join-Path $base "pwfile-$Port.txt"
            # 必须带换行：initdb 读 --pwfile 时按行读，没有换行会当作「没读到」→ 转成交互提示
            [IO.File]::WriteAllText($pwFile, "zcode_pwd`n", (New-Object Text.UTF8Encoding($false)))
            Invoke-Exe $initdb @('-D', $data, '-U', 'postgres', '--encoding=UTF8', '--no-locale',
                '--pwfile', $pwFile, '--auth-local=trust', '--auth-host=scram-sha-256') | Out-Null
            Remove-Item $pwFile -Force -ErrorAction SilentlyContinue
        }

        # 每次 setup 都重写 pg_hba（幂等，保证 trust / scram 两档都在）
        Write-PgHba

        # 改了 pg_hba 必须重启才生效
        if (Test-Port $Port) {
            Invoke-Exe $pgCtl @('-D', $data, '-m', 'fast', 'restart', '-l', $log, '-o', $startOpts, '-w') @(0, 1, 3) -NoCapture | Out-Null
            Write-Step '已重启（pg_hba 变更生效）'
        } else {
            # pg_ctl 在「已有 postmaster.pid / 怀疑有其它实例」时即使启动成功也会返回 1，所以只警告不报错，
            # 真正的判定看端口与日志
            Invoke-Exe $pgCtl @('-D', $data, '-l', $log, '-o', $startOpts, '-w', 'start') @(0, 1, 3) -NoCapture | Out-Null
            Write-Step '已启动'
        }
        if (-not (Test-Port $Port)) {
            $tail = if (Test-Path $log) { (Get-Content $log -Tail 20 | Out-String) } else { '（无日志）' }
            throw "pg_ctl 返回成功但端口 $Port 不可连。日志尾部：`r`n$tail"
        }

        Write-Step "就绪：PostgreSQL @ 127.0.0.1:$Port（库 postgres / 用户 postgres）"
        Write-Step "连接串（trust，用来自建库）：Provider=PostgreSQL;Server=127.0.0.1;Port=$Port;Database=postgres;UserID=postgres;Password="
        Write-Step "连接串（scram）：Provider=PostgreSQL;Server=127.0.0.1;Port=$Port;Database=<自建库>;UserID=postgres;Password=zcode_pwd"
        Write-Step '真库用例：zig build integration -Dpg-conn="<上面的连接串>"'
        break
    }
}

