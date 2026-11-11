#Requires -Version 5.1
<#
.SYNOPSIS
    把本机用户级指令（跨项目接续协议）字节级同步到所有已装备仓库的模板副本。

.DESCRIPTION
    唯一真相源：%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md
    同步目标   ：<各仓库>\tools|Tools\continuity\templates\用户级指令.instructions.md

    旧版本把 16 个仓库路径硬编码在脚本里，仓库一多就漏（2026-11-05 全盘扫到 110 个副本，
    版本从 2026.10.10.4 到 2026.11.03.1 参差不齐）。本版改为**全盘扫描**：
    先改本机副本 -> 跑本脚本 -> 所有副本字节一致 -> 各仓库自行 commit/push。

    安全检查：
      · 只覆盖「模板副本」，不碰本机副本自身；
      · 覆盖前把旧内容备份到 _bak\<时间戳>\ 下（按序号 + 仓库名命名）。

.PARAMETER Roots
    扫描根目录，默认覆盖 G:\Code 与 G:\Project。

.PARAMETER SkipBackup
    跳过备份（仅在已确认副本都在 git 仓库内、可随时还原时使用）。

.EXAMPLE
    .\_sync-user-instruction.ps1

.EXAMPLE
    .\_sync-user-instruction.ps1 -Roots 'G:\Code\Rust'

.NOTES
    版本：2026.11.05.1
#>
[CmdletBinding()]
param(
    [string[]]$Roots = @('G:\Code', 'G:\Project'),
    [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $env:APPDATA 'Code\User\prompts\跨项目接续协议.instructions.md'
if (-not (Test-Path $source)) {
    Write-Host "未找到本机副本：$source" -ForegroundColor Red
    exit 2
}

$srcVer = ([regex]::Match([IO.File]::ReadAllText($source, [Text.Encoding]::UTF8), '版本：([0-9.]+)')).Groups[1].Value
$srcHash = (Get-FileHash $source -Algorithm SHA256).Hash
Write-Host "源：$source"
Write-Host "版本：$srcVer"
Write-Host "SHA256：$srcHash"
Write-Host ''

# ---- 全盘扫描模板副本 ----
$targets = @()
foreach ($r in $Roots) {
    if (-not (Test-Path $r)) { continue }
    $targets += Get-ChildItem $r -Recurse -Filter '用户级指令.instructions.md' -File -ErrorAction SilentlyContinue
}
$targets = $targets | Sort-Object FullName -Unique

if (-not $targets) {
    Write-Host '未找到任何模板副本（检查 -Roots）。' -ForegroundColor Yellow
    exit 1
}

# ---- 备份目录（放临时目录，不污染仓库工作区） ----
$bakDir = $null
if (-not $SkipBackup) {
    $bakDir = Join-Path $env:TEMP ("continuity-bak\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
}

$changed = 0
$skipped = 0
$i = 0
foreach ($f in $targets) {
    $i++
    $h = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    if ($h -eq $srcHash) { $skipped++; continue }

    if ($bakDir) {
        $repo = Split-Path (Split-Path (Split-Path (Split-Path $f.FullName)))
        $name = Split-Path $repo -Leaf
        $bak = Join-Path $bakDir ("{0:d3}_{1}.md" -f $i, $name)
        Copy-Item $f.FullName $bak -Force
    }

    Copy-Item $source $f.FullName -Force
    $changed++
    Write-Host "  更新 $($f.FullName)"
}

Write-Host ''
Write-Host "扫描 $($targets.Count) 个副本：更新 $changed 个，已一致 $skipped 个。"

$hashes = $targets | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
$uniq = ($hashes | Sort-Object -Unique).Count
Write-Host "哈希去重数：$uniq / 文件数 $($hashes.Count)"
$localHash = (Get-FileHash $source -Algorithm SHA256).Hash
$allMatch = -not ($hashes | Where-Object { $_ -ne $localHash })
Write-Host ("与本机副本完全一致：" + $(if ($allMatch) { '是' } else { '否（仍有差异）' })) -ForegroundColor $(if ($allMatch) { 'Green' } else { 'Red' })
if ($bakDir) { Write-Host "旧副本备份：$bakDir" }
