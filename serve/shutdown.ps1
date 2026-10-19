# shutdown.ps1 -- kill the player(s), then kill the poller itself. Last thing I run.
$H = 'http://192.168.103.1:8001'
function Post($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 10 | Out-Null } catch { } }
$killed = @()
try {
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
        if ($p.ProcessId -eq $PID) { continue }
        if ($p.CommandLine -and ($p.CommandLine -match 'GifMiniPlayer\.ps1')) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $killed += $p.ProcessId
        }
    }
} catch { }
Post 'shutdown-summary.txt' "player_pids_killed=$($killed -join ',')"
# now kill the poller (its command line points at a.ps1 / gmp-agent)
try {
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
        if ($p.ProcessId -eq $PID) { continue }
        if ($p.CommandLine -and $p.CommandLine -match 'gmp-agent|\\a\.ps1') {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
} catch { }
