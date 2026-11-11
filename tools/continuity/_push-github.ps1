param(
    [string] $Ip = '20.205.243.166',
    [string[]] $Names = @('Pek.RWaf', 'Pek.RAdmin', 'Pek.RAgent', 'Pek.RPanlServer', 'Pek.RPermissions', 'DH.RustBase', 'DH.Grpc', 'Pek.Mail', 'Pek.Sms', 'Pek.IP')
)

$ErrorActionPreference = 'Continue'
$env:GCM_INTERACTIVE = 'Never'

# Collect repo roots that carry a continuity template copy.
$map = @{}
foreach ($root in @('F:\Code', 'F:\Project')) {
    Get-ChildItem $root -Recurse -File -Filter '*.instructions.md' -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match 'continuity[\\/]templates$' } |
        ForEach-Object {
            $d = $_.Directory
            while ($d -and -not (Test-Path (Join-Path $d.FullName '.git'))) { $d = $d.Parent }
            if ($d) { $map[(Split-Path $d.FullName -Leaf)] = $d.FullName }
        }
}

foreach ($n in $Names) {
    $repo = $map[$n]
    if (-not $repo) { "{0,-16} NOT FOUND" -f $n; continue }

    $dirty = @(& git -C $repo status --porcelain 2>$null)
    if ($dirty.Count -gt 0) { "{0,-16} SKIP dirty({1})" -f $n, $dirty.Count; continue }

    $br = (& git -C $repo rev-parse --abbrev-ref HEAD 2>$null)
    $url = (& git -C $repo remote get-url origin 2>$null)
    $real = $url
    if ($url -match '^https://[^/]+/(https://.+)$') { $real = $Matches[1] }

    $cfg = "http.curloptResolve=github.com:443:$Ip"
    $rs = '+refs/heads/' + $br + ':refs/remotes/upr-tmp/' + $br

    & git -C $repo -c $cfg fetch --quiet $real $rs
    if ($LASTEXITCODE -ne 0) { "{0,-16} FETCH FAIL" -f $n; continue }

    & git -C $repo rebase -X theirs --quiet ('upr-tmp/' + $br)
    if ($LASTEXITCODE -ne 0) {
        & git -C $repo rebase --abort 2>$null
        "{0,-16} REBASE FAIL" -f $n
        continue
    }

    $ps = 'HEAD:refs/heads/' + $br
    $out = (& git -C $repo -c $cfg -c credential.helper=wincred push $real $ps 2>&1 | Out-String)
    $code = $LASTEXITCODE
    "{0,-16} push exit={1}" -f $n, $code
    if ($code -ne 0) {
        (($out -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -First 4) -join ' | ')
    }
}
