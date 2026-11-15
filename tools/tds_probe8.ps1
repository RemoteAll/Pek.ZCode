# Capture a REAL parameterized query (sp_executesql RPC) by MITM-ing System.Data.SqlClient
# -> LocalDB. sqlcmd only sends SQL batches, so it cannot show the RPC frame; SqlClient
# sends RPC for parameterized commands, which is exactly what tds.zig's sendRpc must match.
$ErrorActionPreference = 'Continue'

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

public static class TdsMitm2 {
    static readonly ManualResetEventSlim ready = new ManualResetEventSlim(false);
    static NamedPipeServerStream srv;
    static NamedPipeClientStream cli;

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
        if (!srv.WaitForConnectionAsync().Wait(15000)) { Console.WriteLine("NO_CLIENT"); return; }

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

$name = 'zcode_rpc_' + (Get-Random -Maximum 99999)
[TdsMitm2]::Start($name, $realPipe)

# 参数化查询：SqlClient 会把它编成 sp_executesql 的 RPC 调用
$cs = "Data Source=np:\\.\pipe\$name;Initial Catalog=zcode_test;User ID=zcode_t;Password=Zcode!Test123;Connect Timeout=10"
try {
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cn.Open()
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = 'SELECT TOP 1 1 FROM information_schema.tables WHERE table_name = @p0'
    $p = $cmd.Parameters.Add('@p0', [System.Data.SqlDbType]::BigInt)
    $p.Value = 42
    $scalar = $cmd.ExecuteScalar()
    Write-Output "SCALAR=$scalar"
    $cn.Close()
} catch {
    Write-Output ("CLIENT_FAIL " + $_.Exception.Message)
}
Start-Sleep -Milliseconds 1200
Write-Output 'PROBE_DONE'
