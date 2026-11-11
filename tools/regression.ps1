#Requires -Version 5.1
<#
.SYNOPSIS
  Pek.ZCode 一键回归入口：构建 -> 单元测试（-> 冒烟）。
.DESCRIPTION
  退出码：0 = 无失败项（无源码时以 SKIP 显式说明原因）；1 = 有失败项。
  有 build.zig 时执行 zig build / zig build test；无 build.zig 时打印 SKIP + 原因，
  绝不静默返回（否则"全绿"是假象）。
  报告落 artifacts/regression/report-<时间戳>.txt，便于回溯对比。
  本脚本含中文，必须以 UTF-8 with BOM 保存（Windows PowerShell 5.1 按 GBK 读无 BOM 会 ParserError）。
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1 -SkipBuild
#>
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$reportDir = Join-Path $root 'artifacts\regression'
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$reportPath = Join-Path $reportDir ('report-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt')

$lines = New-Object 'System.Collections.Generic.List[string]'
$script:failed = 0

function Add-Log([string]$text) {
    Write-Host $text
    [void]$lines.Add($text)
}

function Invoke-External([string]$name, [string]$exe, [string[]]$argList) {
    Add-Log "=== $name ==="
    $prev = $ErrorActionPreference
    # PS 5.1：$ErrorActionPreference='Stop' 会把外部命令的正常 stderr 当终止错误，先把脚本炸掉
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $exe @argList 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($out.Trim().Length -gt 0 -and $out.Trim().Length -le 4000) { [void]$lines.Add($out.TrimEnd()) }
    elseif ($out.Trim().Length -gt 4000) { [void]$lines.Add($out.Trim().Substring(0, 4000) + "`r`n…（输出已截断，共 $($out.Trim().Length) 字符）") }
    if ($code -ne 0) {
        Add-Log "[FAIL] $name 退出码 $code"
        $script:failed++
    } else {
        Add-Log "[PASS] $name"
    }
}

Add-Log ('Pek.ZCode 回归 ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Add-Log ("项目根：$root")

$zigCmd = Get-Command zig -ErrorAction SilentlyContinue
if ($zigCmd) {
    $zigVer = (& $zigCmd.Source version 2>&1 | Out-String).Trim()
    Add-Log ("zig：$($zigCmd.Source)（版本 $zigVer）")
} else {
    Add-Log '[SKIP] 未找到 zig（PATH 中无 zig.exe）——跳过构建与单元测试'
}

$buildZig = Join-Path $root 'build.zig'
if (-not (Test-Path $buildZig)) {
    Add-Log '[SKIP] 尚无 build.zig（仓库当前无源码）——跳过构建与单元测试'
} elseif (-not $zigCmd) {
    Add-Log '[SKIP] 有 build.zig 但 zig 不可用——无法构建'
} else {
    if ($SkipBuild) {
        Add-Log '[SKIP] 指定了 -SkipBuild——跳过 zig build'
    } else {
        Invoke-External 'zig build' $zigCmd.Source @('build')
    }
    $buildText = [IO.File]::ReadAllText($buildZig, [Text.Encoding]::UTF8)
    if ($buildText -match 'addTest|b\.step\(\s*"test"') {
        Invoke-External 'zig build test' $zigCmd.Source @('build', 'test')
    } else {
        Add-Log '[SKIP] build.zig 中没有 test 步骤（无 addTest / b.step("test")）——跳过单元测试'
    }
}

Add-Log ''
if ($script:failed -eq 0) {
    Add-Log 'RESULT: PASSED（失败 0；SKIP 项见上，均附原因）'
} else {
    Add-Log "RESULT: FAILED（失败 $($script:failed) 项）"
}
Add-Log ("报告：" + $reportPath)

[IO.File]::WriteAllText($reportPath, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
if ($script:failed -gt 0) { exit 1 }
exit 0
