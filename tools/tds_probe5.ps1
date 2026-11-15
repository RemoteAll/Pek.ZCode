# Capture sqlcmd's LOGIN7 by impersonating a named-pipe TDS server:
#   1) read client PRELOGIN, reply with a valid PRELOGIN response (ENCRYPTION=OFF)
#   2) read the client LOGIN7 and dump it
$ErrorActionPreference = 'Continue'

$sc = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE'
if (-not (Test-Path $sc)) { Write-Output 'NO_SQLCMD'; exit 1 }

$name = 'zcode_tds_login7'
# PRELOGIN response captured from a real server (48 bytes, ENCRYPTION=OFF)
$preloginRespHex = '04 01 00 30 00 00 01 00 00 00 1f 00 06 01 00 25 00 01 02 00 26 00 01 03 00 27 00 00 04 00 27 00 01 05 00 28 00 00 ff 11 00 0f b9 00 00 02 00 00'
$preloginResp = [byte[]]($preloginRespHex -split ' ' | ForEach-Object { [Convert]::ToByte($_, 16) })

$job = Start-Job -ScriptBlock {
    param($pipeName, $resp)
    $srv = New-Object System.IO.Pipes.NamedPipeServerStream(
        $pipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Message,
        [System.IO.Pipes.PipeOptions]::None)
    $conn = $srv.WaitForConnectionAsync()
    if (-not $conn.Wait(8000)) { 'NO_CLIENT'; $srv.Dispose(); return }

    $buf = New-Object byte[] 8192
    $n = $srv.Read($buf, 0, $buf.Length)
    "RX1 len=$n type=$($buf[0])"
    $srv.Write($resp, 0, $resp.Length)
    $srv.Flush()

    $n2 = $srv.Read($buf, 0, $buf.Length)
    "RX2 len=$n2 type=$($buf[0])"
    if ($n2 -gt 0) {
        $hex = ($buf[0..($n2 - 1)] | ForEach-Object { $_.ToString('x2') }) -join ' '
        "HEX=$hex"
    }
    try { $srv.Dispose() } catch { }
} -ArgumentList $name, $preloginResp

Start-Sleep -Milliseconds 800
& $sc -S "np:\\.\pipe\$name" -U zcode_t -P 'Zcode!Test123' -d zcode_test -l 4 -Q 'SELECT 1' 2>&1 | Out-Null
Receive-Job $job -Wait -AutoRemoveJob
