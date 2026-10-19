# agent.ps1 -- persistent guest-side runner.
#   -Install : register a Startup shortcut (survives reboot) and start now, then exit.
#   default  : poll the host for a command, run it, upload everything it printed.
param(
    [switch]$Install,
    [string]$Host_ = 'http://192.168.103.1:8001'
)
$ErrorActionPreference = 'Continue'
$self = $MyInvocation.MyCommand.Path
$dir  = Join-Path $env:LOCALAPPDATA 'GifMiniPlayer\agent'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$logFile = Join-Path $dir 'agent.log'

function Note($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -ErrorAction SilentlyContinue
}

if ($Install) {
    $ps = (Get-Process -Id $PID).Path
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'GifMiniPlayer-agent.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($lnk)
    $sc.TargetPath       = $ps
    $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$self`""
    $sc.WorkingDirectory = Split-Path -Parent $self
    $sc.Save()
    Write-Host "startup shortcut written: $lnk"
    # run it right away in the background (this process exits)
    Start-Process -FilePath $ps -ArgumentList $sc.Arguments -WindowStyle Minimized | Out-Null
    return
}

function Post($name, $text) {
    try { Invoke-WebRequest -UseBasicParsing -Uri "$Host_/upload?name=$name" -Method Post -Body $text -ContentType 'text/plain' -TimeoutSec 15 | Out-Null } catch { }
}

Note "agent polling $Host_ pid=$PID host=$env:COMPUTERNAME"
Post 'agent-ping.txt' "started pid=$PID host=$env:COMPUTERNAME at $(Get-Date -Format s)"

# Skip anything already in the queue: a restart must never replay the previous command
# (that is what let an old shutdown.ps1 kill the freshly started agent).
$last = ''
try { $last = (New-Object Net.WebClient).DownloadString("$Host_/cmd.txt").Trim() } catch { }
Note "ignoring pre-existing command: '$last'"

$tick = 0
while ($true) {
    $tick++
    if ($tick % 20 -eq 0) { Post 'agent-ping.txt' "alive pid=$PID at $(Get-Date -Format s)" }

    $raw = $null
    try { $raw = (New-Object Net.WebClient).DownloadString("$Host_/cmd.txt") } catch { }
    if ($raw) {
        $raw = $raw.Trim()
        if ($raw -and $raw -ne $last) {
            $last = $raw
            $parts  = $raw -split '\s+', 3
            $id     = $parts[0]
            $script = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $extra  = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            if ($script -eq 'update-agent') {
                Note 'self-update requested'
                try {
                    (New-Object Net.WebClient).DownloadFile("$Host_/agent.ps1", $self)
                    Unblock-File -LiteralPath $self -ErrorAction SilentlyContinue
                    Post "agent-out-$id.txt" 'agent updated and restarting'
                    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
                        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Minimized','-File',$self) | Out-Null
                } catch { Note "self-update failed: $_" }
                exit
            }
            if ($script) {
                Note "run $id : $script $extra"
                $local = Join-Path $dir "$id-$script"
                try {
                    (New-Object Net.WebClient).DownloadFile("$Host_/$script", $local)
                    Unblock-File -LiteralPath $local -ErrorAction SilentlyContinue
                    $cmdArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$local)
                    if ($extra) { $cmdArgs += ($extra -split '\s+') }
                    $out = & (Get-Process -Id $PID).Path @cmdArgs 2>&1 | Out-String
                    Note "done $id"
                    Post "agent-out-$id.txt" "[$id] $script $extra`r`n$out"
                } catch {
                    Note "error $id : $_"
                    Post "agent-err-$id.txt" "$script failed: $_"
                }
            }
        }
    }
    Start-Sleep -Milliseconds 1500
}
