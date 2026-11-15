# Man-in-the-middle between sqlcmd and a real LocalDB: logs every TDS message in both
# directions (one line per named-pipe message). Gives the authoritative
# LOGINACK/ENVCHANGE/DONE bytes AND the SQL batch bytes, without guessing the spec.
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\tds_probe7.ps1
# 输出形如 `C2S #5 len=60 hex=01 01 00 3c ...`（C2S = 客户端→服务端）。
# 2026-11-15 靠它定案：SQL batch 的 ALL_HEADERS 是 **22 字节**（含 TRANSACTION_DESCRIPTOR
# 头），不是 4 字节的 0 —— 这正是 `tds.zig` 早先 4009/4013 的根因。
$ErrorActionPreference = 'Continue'

$sc = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE'
if (-not (Test-Path $sc)) { Write-Output 'NO_SQLCMD'; exit 1 }

# 先把实例拉起来（RANU 实例空闲会自动终止，connstr 只打印名字不代表在跑）
powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\mssql-local.ps1" -Action start | Out-Null
$conn = (powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\mssql-local.ps1" -Action connstr) |
    Where-Object { $_ -like 'Provider=*' } | Select-Object -Last 1
if (-not $conn) { Write-Output 'NO_CONNSTR'; exit 1 }
$m = [regex]::Match($conn, 'Server=np:\\\\\.\\pipe\\([^;]+)')
if (-not $m.Success) { Write-Output "NO_PIPE in $conn"; exit 1 }
$realPipe = $m.Groups[1].Value
Write-Output "REAL_PIPE=$realPipe"

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Threading;

public static class TdsMitm {
    static readonly ManualResetEventSlim ready = new ManualResetEventSlim(false);
    static NamedPipeServerStream srv;
    static NamedPipeClientStream cli;

    // 后台线程起服务端并转发；主线程随后启动 sqlcmd（管道已就绪，不靠 sleep 赌时序）
    public static void Start(string serverPipe, string realPipe) {
        var t = new Thread(() => Run(serverPipe, realPipe));
        t.IsBackground = true;
        t.Start();
        if (!ready.Wait(5000)) Console.WriteLine("SERVER_SLOW");
    }

    static void Run(string serverPipe, string realPipe) {
        try {
            srv = new NamedPipeServerStream(serverPipe, PipeDirection.InOut, 1,
                PipeTransmissionMode.Message, PipeOptions.Asynchronous);
        } catch (Exception e) {
            Console.WriteLine("SERVER_CREATE_FAIL " + e.GetType().Name + ": " + e.Message);
            ready.Set();
            return;
        }
        ready.Set();
        if (!srv.WaitForConnectionAsync().Wait(12000)) { Console.WriteLine("NO_CLIENT"); return; }

        cli = new NamedPipeClientStream(".", realPipe, PipeDirection.InOut, PipeOptions.Asynchronous);
        try { cli.Connect(5000); }
        catch (Exception e) { Console.WriteLine("UPSTREAM_FAIL " + e.GetType().Name + ": " + e.Message); return; }

        var t1 = new Thread(() => Pump(srv, cli, "C2S"));
        var t2 = new Thread(() => Pump(cli, srv, "S2C"));
        t1.Start(); t2.Start();
        t1.Join(); t2.Join();
        Console.WriteLine("MITM_DONE");
    }

    static void Pump(Stream from, Stream to, string tag) {
        var buf = new byte[65536];
        var count = 0;
        try {
            while (true) {
                int n = from.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                count++;
                var hex = BitConverter.ToString(buf, 0, n).Replace("-", " ").ToLowerInvariant();
                Console.WriteLine(tag + " #" + count + " len=" + n + " hex=" + hex);
                to.Write(buf, 0, n);
                to.Flush();
            }
        } catch (Exception e) {
            Console.WriteLine(tag + " ERR " + e.GetType().Name + ": " + e.Message);
        }
        Console.WriteLine(tag + " CLOSED after " + count + " msgs");
    }
}
"@

$name = 'zcode_mitm_' + (Get-Random -Maximum 99999)
[TdsMitm]::Start($name, $realPipe)
& $sc -S "np:\\.\pipe\$name" -U zcode_t -P 'Zcode!Test123' -d zcode_test -l 10 -Q 'SELECT 1 AS one' 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500
Write-Output "SQLCMD_EXIT=$LASTEXITCODE"
