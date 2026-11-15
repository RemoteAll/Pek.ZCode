# Capture SQLCMD's own PRELOGIN bytes by impersonating a named-pipe TDS server.
# Gives the authoritative byte layout to compare against tds.zig's prelogin().
$ErrorActionPreference = 'Continue'

$sc = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE'
if (-not (Test-Path $sc)) { Write-Output 'NO_SQLCMD'; exit 1 }

$name = 'zcode_tds_probe'

$job = Start-Job -ScriptBlock {
    param($pipeName)
    try {
        $srv = New-Object System.IO.Pipes.NamedPipeServerStream(
            $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut,
            1,
            [System.IO.Pipes.PipeTransmissionMode]::Message,
            [System.IO.Pipes.PipeOptions]::None)
    } catch {
        "SERVER_CREATE_FAIL $($_.Exception.Message)"
        return
    }
    $conn = $srv.WaitForConnectionAsync()
    if (-not $conn.Wait(8000)) { 'SERVER_NO_CLIENT'; $srv.Dispose(); return }
    $buf = New-Object byte[] 8192
    $total = 0
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) {
        if (-not $srv.IsConnected) { break }
        $n = $srv.Read($buf, $total, 256)
        if ($n -le 0) { break }
        $total += $n
        if ($total -ge 8) {
            $declared = ([int]$buf[2] * 256 + [int]$buf[3])
            if ($total -ge $declared) { break }
        }
    }
    $hex = ($buf[0..([Math]::Max(0, $total - 1))] | ForEach-Object { $_.ToString('x2') }) -join ' '
    "CAPTURED len=$total"
    "HEX=$hex"
    try { $srv.Dispose() } catch { }
} -ArgumentList $name

Start-Sleep -Milliseconds 800
& $sc -S "np:\\.\pipe\$name" -U probe_user -P probe_pass -l 4 -Q 'SELECT 1' 2>&1 | Out-Null
$out = Receive-Job $job -Wait -AutoRemoveJob
$out
