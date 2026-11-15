#Requires -Version 5.1
<#
.SYNOPSIS
  SQL Server LocalDB 实例管理（创建 / 启动 / 停止 / 状态 / 删除）。
.DESCRIPTION
  为什么用它：本机**没有** SQL Server 服务实例、也没有 Docker，但已安装 **LocalDB**
  （`C:\Program Files\Microsoft SQL Server\<ver>\Tools\Binn\SqlLocalDB.exe`）。
  LocalDB 是「按用户运行、免安装服务」的 SQL Server 引擎：`sqllocaldb create/start` 即可用，
  数据落在 `%LOCALAPPDATA%\Microsoft\Microsoft SQL Server Local DB\Instances\<名字>`，随时可删。

  ✅ **2026-11-15 实测纠正**：以前这里写的是「LocalDB 只支持 Windows 认证、ZCode 的 TDS 驱动连不上」——
  **这是错的**。实测 `SERVERPROPERTY('IsIntegratedSecurityOnly')` = **0**（允许 SQL 认证），
  而 ZCode 的 TDS 驱动**本来就支持命名管道**（连接串写 `Server=np:\\.\pipe\<管道名>`）。
  所以：`-Action setup` 会建测试库 + SQL 登录并**直接打印可用的 `-Dsqlserver-conn` 连接串**。

  ⚠ 仍然成立的一条：LocalDB **不监听 TCP**，只能走命名管道/共享内存（所以管道写法是唯一路径）。
  管道名里的 `LOCALDB#XXXX` 每次实例启动会变 → 请用本脚本输出的连接串，不要手写死。

.PARAMETER Action
  setup（创建+启动，幂等）/ start / stop / status / delete（删除实例及其数据）
.PARAMETER Name
  实例名，默认 `zcode`（连接用 `(localdb)\zcode`）
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\mssql-local.ps1 -Action setup
.EXAMPLE
  sqlcmd -S "(localdb)\zcode" -Q "select @@version"
.NOTES
  本脚本含中文，必须以 UTF-8 with BOM 保存（PS 5.1 按 ANSI 读无 BOM 会 ParserError）。
#>
param(
    [ValidateSet('setup', 'start', 'stop', 'status', 'delete', 'connstr')]
    [string]$Action = 'setup',
    [string]$Name = 'zcode',
    # 测试库 / SQL 登录（`setup` 与 `connstr` 会幂等建好它们）
    [string]$Database = 'zcode_test',
    [string]$User = 'zcode_t',
    [string]$Password = 'Zcode!Test123'
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$text) { Write-Host "[mssql-local] $text" }

function Find-SqlLocalDB {
    $candidates = @()
    $cmd = Get-Command SqlLocalDB -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates += Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'Tools\Binn\SqlLocalDB.exe' }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    throw @'
未找到 SqlLocalDB.exe。两种获取方式：
  1) 安装 SQL Server Express LocalDB（微软官方，MSI，约 50 MB）：
     https://learn.microsoft.com/sql/database-engine/configure-windows/sql-server-express-localdb
  2) 或者装完整的 SQL Server Express（支持 TCP + SQL 账号，驱动可直接连）：
     https://www.microsoft.com/sql-server/sql-server-downloads  （Express 版）
'@
}

# PS 5.1：外部命令写 stderr 会被当成终止错误 —— 统一包一层并带超时
function Invoke-Exe([string]$exe, [string[]]$argList, [int[]]$OkCodes = @(0), [int]$TimeoutSec = 180) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($argList -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw "命令超时（${TimeoutSec}s）：$exe $($psi.Arguments)"
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    $out = "$($outTask.Result)$($errTask.Result)"
    if ($OkCodes -notcontains $code) {
        throw "命令失败（退出码 $code）：$exe $($psi.Arguments)`r`n$out"
    }
    return $out
}

$sqllocaldb = Find-SqlLocalDB

function Get-InstanceInfo([string]$n) {
    $out = Invoke-Exe $sqllocaldb @('info', $n) @(0, 1)
    if ($out -match '不存在|does not exist') { return $null }
    return $out
}

function Get-PipeName([string]$info) {
    if ($info -match '(np:\\[^\r\n]+)') { return $Matches[1] }
    return $null
}

function Find-SqlCmd {
    $cmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($d in (Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Directory -ErrorAction SilentlyContinue)) {
        foreach ($rel in @('Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE', 'Tools\Binn\SQLCMD.EXE')) {
            $p = Join-Path $d.FullName $rel
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

# 建测试库 + SQL 登录（幂等），返回可直接用的 `-Dsqlserver-conn` 连接串。
#
# 为什么能这么做：LocalDB 的 `IsIntegratedSecurityOnly = 0`（允许 SQL 认证，2026-11-15 实测），
# 而本仓 TDS 驱动支持命名管道，所以「管道 + SQL 账号」这条路是通的。
function New-TestDatabase([string]$Instance) {
    $sqlcmd = Find-SqlCmd
    if (-not $sqlcmd) {
        Write-Step '未找到 sqlcmd：跳过建库建号（装 SQL Server 客户端工具后重跑 -Action connstr）'
        return $null
    }

    $info = Get-InstanceInfo $Instance
    $pipe = Get-PipeName $info
    if (-not $pipe) {
        Write-Step "拿不到管道名（sqllocaldb info $Instance 的输出里没有 np: 行；先 -Action start）"
        return $null
    }

    $q = "IF DB_ID('$Database') IS NULL CREATE DATABASE [$Database];" +
        "IF NOT EXISTS(SELECT 1 FROM sys.server_principals WHERE name='$User') BEGIN " +
        "CREATE LOGIN [$User] WITH PASSWORD='$Password', CHECK_POLICY=OFF, CHECK_EXPIRATION=OFF; " +
        "ALTER SERVER ROLE sysadmin ADD MEMBER [$User]; END"
    Write-Step "建库建号（幂等）：$Database / $User"
    Invoke-Exe $sqlcmd @('-S', "`"(localdb)\$Instance`"", '-b', '-Q', "`"$q`"") | Out-Null

    return "Provider=SqlServer;Server=$pipe;Database=$Database;Uid=$User;Pwd=$Password"
}

switch ($Action) {
    'status' {
        Write-Step "SqlLocalDB: $sqllocaldb"
        $info = Get-InstanceInfo $Name
        if (-not $info) {
            Write-Step "实例 $Name 不存在（先跑 -Action setup）"
            break
        }
        Write-Step (($info -replace "`r`n", ' / ').Trim())
        $pipe = Get-PipeName $info
        if ($pipe) { Write-Step "管道：$pipe" }
        Write-Step '提醒：LocalDB 不监听 TCP，驱动只能走命名管道（连接串用 setup 输出的那个）；'
        Write-Step '     手工验证请用：sqlcmd -S "(localdb)\' + $Name + '" -Q "select @@version"'
        break
    }
    'start' {
        $info = Get-InstanceInfo $Name
        if (-not $info) { throw "实例 $Name 不存在（先跑 -Action setup）" }
        Invoke-Exe $sqllocaldb @('start', $Name) @(0, 1) | Out-Null
        Write-Step "已启动：$Name"
        break
    }
    'stop' {
        Invoke-Exe $sqllocaldb @('stop', $Name) @(0, 1) | Out-Null
        Write-Step "已停止：$Name"
        break
    }
    'delete' {
        Invoke-Exe $sqllocaldb @('stop', $Name) @(0, 1) | Out-Null
        Invoke-Exe $sqllocaldb @('delete', $Name) @(0, 1) | Out-Null
        Write-Step "已删除实例及其数据：$Name"
        break
    }
    'setup' {
        $info = Get-InstanceInfo $Name
        if (-not $info) {
            Write-Step "创建实例 $Name（按当前用户运行，无需管理员）"
            Invoke-Exe $sqllocaldb @('create', $Name) | Out-Null
            $info = Get-InstanceInfo $Name
        } else {
            Write-Step "实例 $Name 已存在"
        }
        Invoke-Exe $sqllocaldb @('start', $Name) @(0, 1) | Out-Null
        Write-Step '已启动'

        $info = Get-InstanceInfo $Name
        $pipe = Get-PipeName $info
        if ($pipe) { Write-Step "管道：$pipe" }

        Write-Step ('校验：sqlcmd -S "(localdb)\' + $Name + '" -Q "select @@version"')
        $conn = New-TestDatabase -Instance $Name
        if ($conn) {
            Write-Step "真库连接串（直接给 zig build test -Dsqlserver-conn=...）："
            Write-Host $conn
        }
        break
    }
    'connstr' {
        $info = Get-InstanceInfo $Name
        if (-not $info) { throw "实例 $Name 不存在（先跑 -Action setup）" }
        Invoke-Exe $sqllocaldb @('start', $Name) @(0, 1) | Out-Null
        $conn = New-TestDatabase -Instance $Name
        if (-not $conn) { throw '无法得到可用连接串（看上面的错误）' }
        Write-Host $conn
        break
    }
}
