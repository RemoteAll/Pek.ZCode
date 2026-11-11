#Requires -Version 5.1
<#
.SYNOPSIS
  项目内 MySQL 测试实例（绿色版/免安装）管理：初始化、启动、停止、状态、重置。
.DESCRIPTION
  为什么需要：MySQL 驱动要「真库验证」才算数（本机没有服务、没有 Docker）。
  本脚本用免安装版 mysqld 在项目内起一个**独立实例**（默认端口 3307），
  数据目录放在仓库的 `.tools\mysql\data`（已 gitignore），**重启机器后仍在**，可反复复用。

  二进制目录默认自动探测（本机已有绿色版就不再下载），也可 `-Dist` 显式指定；
  找不到时打印下载地址要求先放置，绝不静默跳过。

  自动创建：数据库 `zcode_test` + 两个测试用户
    - root（mysql_native_password，无密码）：验证 native 鉴权 + CRUD
    - zcode_sha2 / zcode_pwd（caching_sha2_password）：验证 **完整鉴权（RSA）** 路径

.PARAMETER Action
  setup（初始化+启动+建库建用户，幂等）/ start / stop / status / reset（删数据目录重建）
.PARAMETER Port
  实例端口，默认 3307（避免和已有的 3306 冲突）
.PARAMETER Dist
  mysqld 所在目录（含 bin\mysqld.exe），默认自动探测
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\mysql-local.ps1 -Action setup
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\mysql-local.ps1 -Action status
.NOTES
  本脚本含中文，必须以 UTF-8 with BOM 保存（PS 5.1 按 ANSI 读无 BOM 会 ParserError）。
#>
param(
    [ValidateSet('setup', 'start', 'stop', 'status', 'reset')]
    [string]$Action = 'setup',
    [int]$Port = 3307,
    [string]$Dist = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$base = Join-Path $root '.tools\mysql'
$data = Join-Path $base "data-$Port"
$cfg = Join-Path $base "my-$Port.ini"
$log = Join-Path $base "mysqld-$Port.log"
$pidFile = Join-Path $base "mysqld-$Port.pid"

if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }

function Write-Step([string]$text) { Write-Host "[mysql-local] $text" }

# PS 5.1：$ErrorActionPreference='Stop' 会把外部程序写 stderr 当终止错误 —— 统一包一层
function Invoke-Exe([string]$exe, [string[]]$argList, [int[]]$OkCodes = @(0)) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $exe @argList 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($OkCodes -notcontains $code) {
        throw "命令失败（退出码 $code）：$exe $($argList -join ' ')`r`n$out"
    }
    return $out
}

function Find-Dist {
    if ($Dist) {
        if (Test-Path (Join-Path $Dist 'bin\mysqld.exe')) { return (Resolve-Path $Dist).Path }
        throw "指定的 -Dist 里没有 bin\mysqld.exe：$Dist"
    }
    $candidates = @(
        'G:\Tools\mysql-portable\mysql-8.0.29-winx64',
        'E:\Soft\mysql-dist\mysql-8.0.28-winx64'
    )
    # 再扫一遍常见根目录（深度 3，避免全盘扫太慢）
    foreach ($root2 in @('G:\Tools', 'E:\Soft', 'C:\Tools')) {
        if (-not (Test-Path $root2)) { continue }
        Get-ChildItem -Path $root2 -Directory -Filter 'mysql-*' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            ForEach-Object { $candidates += $_.FullName }
    }
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'bin\mysqld.exe')) { return (Resolve-Path $c).Path }
    }
    throw @'
未找到免安装版 MySQL（bin\mysqld.exe）。
请下载 MySQL Community Server 的 winx64 ZIP 解压后，用 -Dist 指定目录，例如：
  https://dev.mysql.com/downloads/mysql/  （选 Windows (x86, 64-bit), ZIP Archive）
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\mysql-local.ps1 -Action setup -Dist "D:\mysql-8.0.xx-winx64"
'@
}

function Write-Config([string]$distPath) {
    $basedir = $distPath -replace '\\', '/'
    $datadir = $data -replace '\\', '/'
    $text = @"
[mysqld]
basedir=$basedir
datadir=$datadir
port=$Port
bind-address=127.0.0.1
character-set-server=utf8mb4
collation-server=utf8mb4_general_ci
default_authentication_plugin=mysql_native_password
max_connections=50
innodb_buffer_pool_size=64M
log-error=$($log -replace '\\', '/')
"@
    [IO.File]::WriteAllText($cfg, $text, (New-Object Text.UTF8Encoding($false)))
}

function Get-RunningPid {
    if (Test-Path $pidFile) {
        $saved = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($saved) {
            $p = Get-Process -Id ([int]$saved) -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -like 'mysqld*') { return $p.Id }
        }
    }
    $p = Get-Process -Name 'mysqld' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -like '*mysql*' } | Select-Object -First 1
    if ($p) { return $p.Id }
    return 0
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

function Wait-Port([int]$p, [int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Port $p) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

$distPath = Find-Dist
$mysqld = Join-Path $distPath 'bin\mysqld.exe'
$mysql = Join-Path $distPath 'bin\mysql.exe'
$mysqladmin = Join-Path $distPath 'bin\mysqladmin.exe'

switch ($Action) {
    'status' {
        $p = Get-RunningPid
        Write-Step "dist  : $distPath"
        Write-Step "data  : $data"
        Write-Step "port  : $Port（$([bool](Test-Port $Port)) 可连）"
        Write-Step "pid   : $(if ($p) { $p } else { '未运行' })"
        if (Test-Path $log) { Write-Step "日志  : $log" }
        break
    }
    'stop' {
        if (Test-Port $Port) {
            # 优先优雅关闭；失败再杀进程
            try { Invoke-Exe $mysqladmin @('-h', '127.0.0.1', "-P$Port", '-uroot', 'shutdown') | Out-Null }
            catch { Write-Step 'mysqladmin 关闭失败，改用 Stop-Process' }
        }
        $p = Get-RunningPid
        if ($p) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
        if (Test-Path $pidFile) { Remove-Item $pidFile -Force }
        Write-Step '已停止'
        break
    }
    'reset' {
        & $PSCommandPath -Action stop -Port $Port -Dist $distPath
        if (Test-Path $data) { Remove-Item -Recurse -Force $data }
        Write-Step "数据目录已删除：$data"
        break
    }
    'setup' {
        Write-Step "dist  : $distPath"
        Write-Step "data  : $data"

        if (-not (Test-Path $data)) {
            Write-Step '初始化数据目录（--initialize-insecure，root 无密码）'
            Write-Config $distPath
            Invoke-Exe $mysqld @("--defaults-file=$cfg", '--initialize-insecure') | Out-Null
        }

        # 为什么用 --init-file：`--initialize-insecure` 只建 `root@localhost`，
        # 而从 127.0.0.1 走 TCP 连进来时服务端认的是 IP（反查不到 localhost），会报
        # ERROR 1130 Host '127.0.0.1' is not allowed。--init-file 在启动时以完整权限执行，
        # 幂等地补 `root@'%'` 与测试账号，之后所有客户端都能走 TCP。
        $bootstrap = Join-Path $base "bootstrap-$Port.sql"
        $bootSql = @"
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS zcode_test CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'zcode_sha2'@'%' IDENTIFIED WITH caching_sha2_password BY 'zcode_pwd';
GRANT ALL PRIVILEGES ON zcode_test.* TO 'zcode_sha2'@'%';
CREATE USER IF NOT EXISTS 'zcode_native'@'%' IDENTIFIED WITH mysql_native_password BY 'zcode_pwd';
GRANT ALL PRIVILEGES ON zcode_test.* TO 'zcode_native'@'%';
FLUSH PRIVILEGES;
"@
        [IO.File]::WriteAllText($bootstrap, $bootSql, (New-Object Text.UTF8Encoding($false)))
        $bootArg = "--init-file=$($bootstrap -replace '\\','/')"

        if (-not (Test-Port $Port)) {
            Write-Step "启动 mysqld（端口 $Port）"
            Write-Config $distPath
            $proc = Start-Process -FilePath $mysqld -ArgumentList "--defaults-file=$cfg", $bootArg -WindowStyle Hidden -PassThru
            Set-Content -Path $pidFile -Value $proc.Id -Encoding ascii
            if (-not (Wait-Port $Port 90)) {
                $tail = if (Test-Path $log) { (Get-Content $log -Tail 20 | Out-String) } else { '（无日志）' }
                throw "mysqld 启动超时（端口 $Port 未监听）。日志尾部：`r`n$tail"
            }
            Write-Step '已启动'
        } else {
            Write-Step "端口 $Port 已可连，跳过启动"
        }

        $ver = Invoke-Exe $mysql @('-h', '127.0.0.1', "-P$Port", '-uroot', '-N', '-e', 'select version()')
        Write-Step "就绪：MySQL $($ver.Trim())  端口 $Port  库 zcode_test"
        Write-Step "连接串（native）：Provider=MySQL;Server=127.0.0.1;Port=$Port;Database=zcode_test;UserID=root;Password="
        Write-Step "连接串（sha2）  ：Provider=MySQL;Server=127.0.0.1;Port=$Port;Database=zcode_test;UserID=zcode_sha2;Password=zcode_pwd"
        break
    }
}
