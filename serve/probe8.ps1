# probe8.ps1 -- measure CPU/working set of a chosen build, in three states, then kill it.
#   old : the copy already sitting in GifMiniTest (pre-optimisation build)
#   new : the freshly served zip, unpacked to GifMiniTest2 (optimised build)
param([string]$Which = 'new')
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Post($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }

Post 'p8-00-start.txt' "which=$Which"
Add-Type -AssemblyName System.Windows.Forms

if ($Which -eq 'old') {
    $dir = Join-Path $env:USERPROFILE 'GifMiniTest'
} else {
    $dir = Join-Path $env:USERPROFILE 'GifMiniTest2'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Invoke-WebRequest -UseBasicParsing "$H/gif-miniplayer.zip" -OutFile (Join-Path $dir 'b.zip') -TimeoutSec 60
    Expand-Archive -LiteralPath (Join-Path $dir 'b.zip') -DestinationPath $dir -Force
    Get-ChildItem $dir -File | Unblock-File -ErrorAction SilentlyContinue
}
$app = Join-Path $dir 'GifMiniPlayer.ps1'
if (-not (Test-Path -LiteralPath $app)) {
    Log "MISSING $app"; Post "probe8-summary-$Which.txt" "MISSING"; Post 'probe8.log' ($log -join "`r`n"); return
}
$gif = Join-Path $env:USERPROFILE 'GifMiniTest\gifA.gif'
if (-not (Test-Path -LiteralPath $gif)) { Invoke-WebRequest -UseBasicParsing "$H/gifA.gif" -OutFile $gif -TimeoutSec 60 }
Log "build=$Which app=$app"

$errLog = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path -LiteralPath $errLog) { Remove-Item -LiteralPath $errLog -Force }

$proc = Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList @(
    '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$app,$gif)
$appPid = $proc.Id
Log "launched pid=$appPid"
Post 'p8-01-launched.txt' "pid=$appPid build=$Which"
Start-Sleep -Seconds 10
Log "alive after 10s: $(-not (Get-Process -Id $appPid -ErrorAction SilentlyContinue | Select-Object -First 1).HasExited)"

function Sample-State($label, $seconds = 5) {
    try {
        $p = Get-Process -Id $appPid -ErrorAction Stop
        $t0 = $p.TotalProcessorTime
        $m0 = $p.WorkingSet64
        $h0 = $p.HandleCount
        Start-Sleep -Seconds $seconds
        $p.Refresh()
        $t1 = $p.TotalProcessorTime
        $m1 = $p.WorkingSet64
        $h1 = $p.HandleCount
        $cores = [Environment]::ProcessorCount
        $cpu = [math]::Round((($t1 - $t0).TotalSeconds / $seconds) * 100.0 / $cores, 2)
        $mem = [math]::Round($m1 / 1MB, 1)
        $memDelta = [math]::Round(($m1 - $m0) / 1KB, 0)
        $line = "{0}: cpu={1}% mem={2}MB dMem={3}KB handles={4} dHandles={5}" -f $label, $cpu, $mem, $memDelta, $h1, ($h1 - $h0)
        Log $line
        return [pscustomobject]@{ Label = $label; Cpu = $cpu; Mem = $mem; Line = $line }
    } catch {
        $msg = "SAMPLE($label) FAILED: $($_.Exception.Message)"
        Log $msg
        Post "p8-err-$label.txt" $msg
        return [pscustomobject]@{ Label = $label; Cpu = 'n/a'; Mem = 'n/a'; Line = $msg }
    }
}

$mPlay = Sample-State 'playing'
Post 'p8-02-playing.txt' $mPlay.Line

[System.Windows.Forms.SendKeys]::SendWait(' ')
Start-Sleep -Milliseconds 700
$mPause = Sample-State 'paused'
Post 'p8-03-paused.txt' $mPause.Line
[System.Windows.Forms.SendKeys]::SendWait(' ')
Start-Sleep -Milliseconds 500

[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
Start-Sleep -Seconds 1
$mHide = Sample-State 'hidden'
Post 'p8-04-hidden.txt' $mHide.Line

if (Test-Path -LiteralPath $errLog) {
    Log '=== app error.log present ==='
    Get-Content -LiteralPath $errLog | Select-Object -First 5 | ForEach-Object { Log "err $_" }
}

$verdict = "build=$Which playing_cpu=$($mPlay.Cpu)% paused_cpu=$($mPause.Cpu)% hidden_cpu=$($mHide.Cpu)% mem=$($mPlay.Mem)MB"
Log "VERDICT: $verdict"
Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue
Post "probe8-summary-$Which.txt" $verdict
Post 'probe8.log' ($log -join "`r`n")
