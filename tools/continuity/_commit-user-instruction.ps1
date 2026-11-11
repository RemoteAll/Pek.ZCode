#Requires -Version 5.1
<#
.SYNOPSIS
    把「用户级指令模板副本」的改动批量提交（并推送）到所有包含它的 git 仓库。

.DESCRIPTION
    配合 _sync-user-instruction.ps1 使用：
      1) 改本机副本   %APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md
      2) 全盘铺副本   .\_sync-user-instruction.ps1
      3) 批量提交     .\_commit-user-instruction.ps1

    只 add / commit 模板文件本身，不碰各仓库其它未提交改动（避免误提交业务代码）。
    提交信息一律中文，且用 `git commit -F <UTF-8 文件>`（PS 5.1 用 -m 传中文会变 gb2312）。

.PARAMETER Roots
    扫描根目录，默认 G:\Code 与 G:\Project。

.PARAMETER NoPush
    只提交不推送。

.PARAMETER Message
    提交主题（默认取本机副本的版本号自动生成）。
#>
[CmdletBinding()]
param(
    [string[]]$Roots = @('G:\Code', 'G:\Project'),
    [switch]$NoPush,
    [string]$Message
)

$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $prevEnc = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        $output = & $Exe @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally {
        $ErrorActionPreference = $prev
        try { [Console]::OutputEncoding = $prevEnc } catch { }
    }
}

$source = Join-Path $env:APPDATA 'Code\User\prompts\跨项目接续协议.instructions.md'
$ver = ([regex]::Match([IO.File]::ReadAllText($source, [Text.Encoding]::UTF8), '版本：([0-9.]+)')).Groups[1].Value
if (-not $ver) { Write-Host "无法从本机副本读取版本号：$source" -ForegroundColor Red; exit 2 }

if (-not $Message) {
    $Message = "docs(continuity): 同步用户级接续指令至 $ver`n`n由 _sync-user-instruction.ps1 全盘铺开，各仓库副本与本机副本字节级一致。"
}

$msgFile = Join-Path $env:TEMP "continuity-commit-$([guid]::NewGuid().ToString('N')).txt"
[IO.File]::WriteAllText($msgFile, $Message, (New-Object Text.UTF8Encoding($false)))

$copies = @()
foreach ($r in $Roots) {
    if (-not (Test-Path $r)) { continue }
    $copies += Get-ChildItem $r -Recurse -Filter '用户级指令.instructions.md' -File -ErrorAction SilentlyContinue
}

$results = @()
foreach ($c in $copies) {
    $d = $c.Directory
    while ($d -and -not (Test-Path (Join-Path $d.FullName '.git'))) { $d = $d.Parent }
    if (-not $d) { $results += [pscustomobject]@{ Repo = $c.FullName; Status = '无 git'; Detail = '' }; continue }

    $repo = $d.FullName
    $rel = $c.FullName.Substring($repo.Length).TrimStart('\')

    $st = Invoke-Native 'git' @('-C', $repo, 'status', '--porcelain', '--', $rel)
    if (-not $st.Output.Trim()) { $results += [pscustomobject]@{ Repo = $repo; Status = '无改动'; Detail = '' }; continue }

    $add = Invoke-Native 'git' @('-C', $repo, 'add', '--', $rel)
    if ($add.ExitCode -ne 0) { $results += [pscustomobject]@{ Repo = $repo; Status = 'add 失败'; Detail = $add.Output.Trim() }; continue }

    $ci = Invoke-Native 'git' @('-C', $repo, 'commit', '-F', $msgFile)
    if ($ci.ExitCode -ne 0) { $results += [pscustomobject]@{ Repo = $repo; Status = 'commit 失败'; Detail = $ci.Output.Trim() }; continue }

    if ($NoPush) { $results += [pscustomobject]@{ Repo = $repo; Status = '已提交'; Detail = '' }; continue }

    $up = Invoke-Native 'git' @('-C', $repo, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    if ($up.ExitCode -ne 0) { $results += [pscustomobject]@{ Repo = $repo; Status = '已提交(无 upstream)'; Detail = '' }; continue }

    $ps = Invoke-Native 'git' @('-C', $repo, 'push')
    if ($ps.ExitCode -ne 0) { $results += [pscustomobject]@{ Repo = $repo; Status = '推送失败'; Detail = $ps.Output.Trim() }; continue }
    $results += [pscustomobject]@{ Repo = $repo; Status = '已提交并推送'; Detail = '' }
}

Remove-Item $msgFile -Force -ErrorAction SilentlyContinue

$results | Group-Object Status | ForEach-Object {
    Write-Host ("{0,-16} {1}" -f $_.Name, $_.Count) -ForegroundColor $(if ($_.Name -like '*失败*') { 'Red' } else { 'Green' })
}
Write-Host ''
$results | Where-Object { $_.Status -like '*失败*' -or $_.Status -eq '无 git' } | ForEach-Object {
    Write-Host ("[{0}] {1}" -f $_.Status, $_.Repo) -ForegroundColor Yellow
    if ($_.Detail) { Write-Host ("        " + ($_.Detail -split "`n" | Select-Object -First 3) -join ' / ') }
}
Write-Host ''
Write-Host ("合计 {0} 个副本，涉及 {1} 个仓库。" -f $results.Count, ($results.Repo | Sort-Object -Unique).Count)
