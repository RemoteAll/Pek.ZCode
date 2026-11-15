# Does the SECOND CreateFileW on the same LocalDB named pipe block?
# This isolates why opening a second SQL Server connection hangs (connection pool would hit it too).
$ErrorActionPreference = 'Continue'

$conn = (powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\mssql-local.ps1" -Action connstr) |
    Where-Object { $_ -like 'Provider=*' } | Select-Object -Last 1
if (-not $conn) { Write-Output 'NO_CONNSTR'; exit 1 }
$m = [regex]::Match($conn, 'Server=np:\\\\\.\\pipe\\([^;]+)')
if (-not $m.Success) { Write-Output "NO_PIPE in $conn"; exit 1 }
$realPipe = $m.Groups[1].Value
Write-Output "REAL_PIPE=$realPipe"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class K9 {
    [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string n, uint acc, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool WaitNamedPipeW(string n, uint timeout);
    [DllImport("kernel32", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
}
"@

$path = "\\.\pipe\$realPipe"

function Try-Open([string]$label) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $h = [K9]::CreateFileW($path, [uint32]3221225472, 0, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    $sw.Stop()
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($h -eq [IntPtr](-1)) {
        Write-Output "$label OPEN_FAIL err=$err ms=$($sw.ElapsedMilliseconds)"
        return [IntPtr](-1)
    }
    Write-Output "$label OPEN_OK ms=$($sw.ElapsedMilliseconds)"
    return $h
}

$h1 = Try-Open 'H1'
if ($h1 -ne [IntPtr](-1)) {
    # 第二次打开：不阻塞就会立刻返回；若实例数为 1 且 CreateFile 会等，这里会挂住
    $job = Start-Job -ScriptBlock {
        param($p, $asm)
        Add-Type -TypeDefinition $asm
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $h = [K9]::CreateFileW($p, [uint32]3221225472, 0, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        $sw.Stop()
        $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($h -eq [IntPtr](-1)) { "H2 OPEN_FAIL err=$e ms=$($sw.ElapsedMilliseconds)" }
        else { "H2 OPEN_OK ms=$($sw.ElapsedMilliseconds)"; [void][K9]::CloseHandle($h) }
    } -ArgumentList $path, @"
using System;
using System.Runtime.InteropServices;
public static class K9 {
    [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string n, uint acc, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
}
"@
    $done = $job | Wait-Job -Timeout 6
    if ($done) { Receive-Job $job } else { Write-Output 'H2 STILL BLOCKED after 6s'; $job | Stop-Job }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    [void][K9]::CloseHandle($h1)
}

# 对照：用 WaitNamedPipeW 预等实例，再看能否立刻打开
$w = [K9]::WaitNamedPipeW($path, 3000)
Write-Output "WaitNamedPipeW=$w err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
