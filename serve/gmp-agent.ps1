# gmp-agent.ps1 -- guest-side poller. Runs in the VM, pulls commands from the host, runs them,
# uploads their output. From this point on nothing on the host touches keyboard or mouse:
# no XTEST, no clicking, no typing into the guest.
#
# Started once by hand:
#   curl.exe -s -o $env:USERPROFILE\a.ps1 http://192.168.103.1:8001/gmp-agent.ps1; powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File $env:USERPROFILE\a.ps1
param([string]$Host_ = 'http://192.168.103.1:8001')

$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:USERPROFILE 'gmp-agent'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$last = ''
$ping = Join-Path $dir 'ping.txt'

function Post($name, $text) {
    try { Invoke-WebRequest -UseBasicParsing -Uri "$Host_/upload?name=$name" -Method Post -Body $text -ContentType 'text/plain' -TimeoutSec 15 | Out-Null } catch { }
}

Write-Host "gmp-agent polling $Host_ as pid $PID"
Post 'agent-ping.txt' "started pid=$PID host=$env:COMPUTERNAME at $(Get-Date -Format s)"

$tick = 0
while ($true) {
    $tick++
    if ($tick % 15 -eq 0) { Post 'agent-ping.txt' "alive pid=$PID at $(Get-Date -Format s)" }

    $raw = $null
    try { $raw = (New-Object Net.WebClient).DownloadString("$Host_/cmd.txt") } catch { }
    if ($raw) {
        $raw = $raw.Trim()
        if ($raw -and $raw -ne $last) {
            $last = $raw
            $parts = $raw -split '\s+', 3
            $id     = $parts[0]
            $script = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $args_  = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            if ($script) {
                Write-Host "--- $id : $script $args_"
                $local = Join-Path $dir "$id-$script"
                try {
                    (New-Object Net.WebClient).DownloadFile("$Host_/$script", $local)
                    Unblock-File -LiteralPath $local -ErrorAction SilentlyContinue
                    $cmdArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$local)
                    if ($args_) { $cmdArgs += ($args_ -split '\s+') }
                    $out = & powershell.exe @cmdArgs 2>&1 | Out-String
                    Write-Host $out
                    Post "agent-out-$id.txt" "[$id] $script $args_`r`n$out"
                } catch {
                    Write-Host "agent error: $_"
                    Post "agent-err-$id.txt" "$script failed: $_"
                }
            }
        }
    }
    Start-Sleep -Milliseconds 1500
}
