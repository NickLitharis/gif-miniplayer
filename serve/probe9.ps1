# probe9.ps1 -- fair A/B of playing CPU: alternate old/new builds, 3 samples each,
# so host/VM noise and warm-up drift hit both builds equally.
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Post($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }

$oldDir = Join-Path $env:USERPROFILE 'GifMiniTest'
$newDir = Join-Path $env:USERPROFILE 'GifMiniTest2'
$gif    = Join-Path $oldDir 'gifA.gif'

# make sure the new build is present (no network churn during measurement)
if (-not (Test-Path (Join-Path $newDir 'GifMiniPlayer.ps1'))) {
    New-Item -ItemType Directory -Force -Path $newDir | Out-Null
    Invoke-WebRequest -UseBasicParsing "$H/gif-miniplayer.zip" -OutFile (Join-Path $newDir 'b.zip') -TimeoutSec 60
    Expand-Archive -LiteralPath (Join-Path $newDir 'b.zip') -DestinationPath $newDir -Force
    Get-ChildItem $newDir -File | Unblock-File -ErrorAction SilentlyContinue
}
foreach ($d in @($oldDir, $newDir)) {
    if (-not (Test-Path (Join-Path $d 'GifMiniPlayer.ps1'))) { Log "MISSING build in $d"; Post 'probe9-summary.txt' "MISSING $d"; return }
}
Log "both builds present"

$cores = [Environment]::ProcessorCount
Log "logical cores visible to the guest: $cores"
$samples = @{ old = @(); new = @() }
$mem     = @{ old = @(); new = @() }

function One-Run($which, $pass) {
    $dir = if ($which -eq 'old') { $oldDir } else { $newDir }
    $app = Join-Path $dir 'GifMiniPlayer.ps1'
    $proc = Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList @(
        '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$app,$gif)
    $appPid = $proc.Id
    Start-Sleep -Seconds 8          # settle: startup, JIT, first frame loads
    try {
        $p = Get-Process -Id $appPid -ErrorAction Stop
        $t0 = $p.TotalProcessorTime
        Start-Sleep -Seconds 6
        $p.Refresh()
        $dt = ($p.TotalProcessorTime - $t0).TotalSeconds
        $cpu = [math]::Round(($dt / 6) * 100.0 / $cores, 2)
        $m = [math]::Round($p.WorkingSet64 / 1MB, 1)
        Log "pass$pass $which : cpu=$cpu% mem=${m}MB"
        $script:samples[$which] += $cpu
        $script:mem[$which] += $m
    } catch {
        Log "pass$pass $which : FAILED $($_.Exception.Message)"
    }
    Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

for ($pass = 1; $pass -le 3; $pass++) {
    One-Run 'old' $pass
    One-Run 'new' $pass
}

function Mean($arr) { if ($arr.Count -eq 0) { return 0 }; return [math]::Round((($arr | Measure-Object -Average).Average), 2) }
$oldMean = Mean $samples['old']; $newMean = Mean $samples['new']
$oldMem  = Mean $mem['old'];     $newMem  = Mean $mem['new']
$delta   = if ($oldMean -gt 0) { [math]::Round((($newMean - $oldMean) / $oldMean) * 100, 1) } else { 0 }

$verdict = "old_cpu=[$($samples['old'] -join ',')] mean=$oldMean% | new_cpu=[$($samples['new'] -join ',')] mean=$newMean% | change=$delta% | old_mem=${oldMem}MB new_mem=${newMem}MB"
Log "VERDICT: $verdict"
Post 'probe9-summary.txt' $verdict
Post 'probe9.log' ($log -join "`r`n")
