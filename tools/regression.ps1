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
    # 绿色版自检（真实 SQLite，一次跑通建表/CRUD/脏字段更新）
    if ($buildText -match 'green-test') {
        Invoke-External 'zig build green-test（绿色版自检）' $zigCmd.Source @('build', 'green-test')
    } else {
        Add-Log '[SKIP] build.zig 中没有 green-test 步骤'
    }

    # 方言覆盖审计：19 个可实现方言 × 全部 SQL 生成函数（不连库，纯生成层）
    if ($buildText -match 'audit-dialects') {
        Invoke-External 'zig build audit-dialects（方言覆盖审计）' $zigCmd.Source @('build', 'audit-dialects')
    } else {
        Add-Log '[SKIP] build.zig 中没有 audit-dialects 步骤'
    }

    # 生成产物漂移：重新生成后工作区必须无差异（防止 Model.xml 改了没重新生成）
    if ($buildText -match 'codegen' -and (Test-Path (Join-Path $root 'examples\entities'))) {
        Invoke-External 'zig build codegen（重新生成实体）' $zigCmd.Source @(
            'build', 'codegen', '-Dmodel=examples/demo-model.xml', '-Dout=examples/entities'
        )
        # git 可能不在 PATH（-NoProfile 下 Git 的 PATH 注入会失效）：先找一遍，找不到就显式 SKIP
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if (-not $gitCmd) {
            foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
                if (Test-Path $p) { $gitCmd = Get-Item $p; break }
            }
        }
        if (-not $gitCmd) {
            Add-Log '[SKIP] 找不到 git（PATH 与常见安装路径都没有）——跳过生成漂移检查，请人工确认 examples\entities 已重新生成'
        } else {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $out = (& $gitCmd.Source -C $root diff --quiet -- examples/entities 2>&1 | Out-String)
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prev
            }
            if ($code -eq 0) {
                Add-Log '[PASS] 生成产物无漂移（git diff 为空）'
            } else {
                if ($out.Trim().Length -gt 0) { Add-Log $out.Trim() }
                Add-Log '[FAIL] examples/entities 与 demo-model.xml 不一致——请重新生成并提交'
                $script:failed++
            }
        }
    } else {
        Add-Log '[SKIP] 没有 codegen 步骤或 examples\entities 目录——跳过生成漂移检查'
    }

    # 生成器自检：拿 C# / Rust 的真实 Model.xml 生成实体 → 编译 → 真 SQLite 建表 + 增删改查
    #   （这是「模型完全共用 + 有实体代码生成器」的可执行证明；三个夹具任一缺失就显式 SKIP）
    if ((Test-Path (Join-Path $root 'tools\gencheck.zig')) -and ($buildText -match 'gen-check')) {
        $fixtures = @(
            @{ Name = 'C# DH.NCode 模型'; Path = 'tests/fixtures/dh-ncode-model.xml'; Out = 'zig-out/gen-check-csharp' },
            @{ Name = 'C# 测试模型';       Path = 'tests/fixtures/dh-ncode-test-model.xml'; Out = 'zig-out/gen-check-csharp-test' },
            @{ Name = 'Rust Pek.RCode 模型'; Path = 'tests/fixtures/wms-model-sample.xml'; Out = 'zig-out/gen-check-rust' }
        )
        foreach ($f in $fixtures) {
            if (-not (Test-Path (Join-Path $root $f.Path))) {
                Add-Log ('[SKIP] 缺少夹具 {0}——跳过 {1} 的生成器自检' -f $f.Path, $f.Name)
                continue
            }
            Push-Location $root
            try {
                Invoke-External ("codegen：{0}" -f $f.Name) $zigCmd.Source @(
                    'build', 'codegen', ("-Dmodel={0}" -f $f.Path), ("-Dout={0}" -f $f.Out)
                )
                # 生成了 mod.zig 才继续编译自检；否则说明 codegen 已失败（上面已记 FAIL）
                if (Test-Path (Join-Path $root ("{0}/mod.zig" -f $f.Out))) {
                    Invoke-External ("gen-check：{0}" -f $f.Name) $zigCmd.Source @(
                        'build', 'gen-check', ("-Dgen-check={0}" -f $f.Out), ("-Dmodel={0}" -f $f.Path)
                    )
                } else {
                    Add-Log ("[SKIP] {0} 未生成 mod.zig——跳过 {1} 的自检" -f $f.Out, $f.Name)
                }
            } finally {
                Pop-Location
            }
        }
    } else {
        Add-Log '[SKIP] 没有 tools\gencheck.zig 或 build.zig 无 gen-check 步骤——跳过生成器自检'
    }

    # 公共库 zzig（源码依赖）：改了它必须一起回归，否则本仓可能被下游改动打破而不自知
    $zzigDir = Join-Path (Split-Path $root -Parent) 'zzig'
    if (Test-Path (Join-Path $zzigDir 'build.zig')) {
        Push-Location $zzigDir
        try {
            Invoke-External 'zzig: zig build test（公共库）' $zigCmd.Source @('build', 'test')
        } finally {
            Pop-Location
        }
    } else {
        Add-Log "[SKIP] 未找到公共库 $zzigDir——跳过 zzig 回归"
    }

    # 真库集成：PG 实例（tools/pg-local.ps1 起的 5433）在跑就带上连接串跑
    $pgPort = 5433
    $pgUp = $false
    try {
        $tc = New-Object Net.Sockets.TcpClient
        $tc.Connect('127.0.0.1', $pgPort)
        $pgUp = $true
        $tc.Dispose()
    } catch { $pgUp = $false }
    if (-not $pgUp) {
        Add-Log "[SKIP] PostgreSQL 真库用例：127.0.0.1:$pgPort 不可连（先跑 tools/pg-local.ps1 -Action setup）"
    } elseif ($buildText -match 'pg-conn') {
        Invoke-External 'zig build integration（PostgreSQL 真库）' $zigCmd.Source @(
            'build', 'integration',
            ("-Dpg-conn=Provider=PostgreSQL;Server=127.0.0.1;Port={0};Database=postgres;UserID=postgres;Password=" -f $pgPort),
            ("-Dpg-conn-scram=Provider=PostgreSQL;Server=127.0.0.1;Port={0};Database=zcode_it;UserID=postgres;Password=zcode_pwd" -f $pgPort)
        )
    } else {
        Add-Log '[SKIP] build.zig 无 pg-conn 选项——跳过 PostgreSQL 真库用例'
    }

    # 真库集成：MySQL 实例（tools/mysql-local.ps1 起的 3307）在跑就带上连接串跑
    $myPort = 3307
    $myUp = $false
    try {
        $tc = New-Object Net.Sockets.TcpClient
        $tc.Connect('127.0.0.1', $myPort)
        $myUp = $true
        $tc.Dispose()
    } catch { $myUp = $false }
    if (-not $myUp) {
        Add-Log "[SKIP] MySQL 真库用例：127.0.0.1:$myPort 不可连（先跑 tools/mysql-local.ps1 -Action setup）"
    } elseif ($buildText -match 'mysql-conn') {
        Invoke-External 'zig build integration（MySQL 真库）' $zigCmd.Source @(
            'build', 'integration',
            ("-Dmysql-conn=Provider=MySQL;Server=127.0.0.1;Port={0};Database=zcode_test;UserID=root;Password=" -f $myPort)
        )
    } else {
        Add-Log '[SKIP] build.zig 无 mysql-conn 选项——跳过 MySQL 真库用例'
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
