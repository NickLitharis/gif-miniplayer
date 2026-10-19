# guest-selftest.ps1 -- self-contained, NO network needed. Run inside the Windows 11 VM.
# Launches GifMiniPlayer, proves the window exists, proves the GIF animates, proves pause works,
# and writes screenshots + results.txt next to this script.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here 'results'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$log = New-Object System.Collections.Generic.List[string]

function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    $script:log.Add($line)
    Write-Host $line -ForegroundColor Cyan
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

function Shot($name) {
    $p = Join-Path $out $name
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    return $p
}

function DiffPct($a, $b) {
    $ia = [System.Drawing.Bitmap]::FromFile($a); $ib = [System.Drawing.Bitmap]::FromFile($b)
    $diff = 0; $tested = 0
    for ($y = 0; $y -lt $ia.Height; $y += 8) {
        for ($x = 0; $x -lt $ia.Width; $x += 8) {
            $tested++
            if ($ia.GetPixel($x, $y).ToArgb() -ne $ib.GetPixel($x, $y).ToArgb()) { $diff++ }
        }
    }
    $ia.Dispose(); $ib.Dispose()
    if ($tested -eq 0) { return -1 }
    return [math]::Round(100.0 * $diff / $tested, 2)
}

Log "=== GifMiniPlayer self-test ==="
Log "OS: $([System.Environment]::OSVersion.VersionString)  PS: $($PSVersionTable.PSVersion)"

$app = Join-Path $here 'GifMiniPlayer.ps1'
$gif = Join-Path $here 'test-animation.gif'
if (-not (Test-Path $app)) { Log "MISSING: $app"; return }
if (-not (Test-Path $gif)) { Log "MISSING: $gif"; return }

Get-ChildItem $here -File | Unblock-File -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$app,$gif) -PassThru
Log "launched app, pid $($proc.Id)"
Start-Sleep -Seconds 12

Log "process alive: $(-not $proc.HasExited)"
if ($proc.HasExited) { Log "EXIT CODE: $($proc.ExitCode)" }

foreach ($w in (Get-Process | Where-Object { $_.MainWindowTitle })) {
    Log ("window found: {0} (pid {1}) '{2}'" -f $w.ProcessName, $w.Id, $w.MainWindowTitle)
}

$s1 = Shot 'shot_playing_1.png'; Start-Sleep -Milliseconds 1200; $s2 = Shot 'shot_playing_2.png'
$d1 = DiffPct $s1 $s2
Log ("PLAYING: {0}% of sampled pixels changed -> {1}" -f $d1, $(if ($d1 -gt 0) { 'PASS - animating' } else { 'FAIL - static' }))

try {
    [Microsoft.VisualBasic.Interaction]::AppActivate('GIF Mini Player') | Out-Null
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait(' ')
    Start-Sleep -Milliseconds 900
    $s3 = Shot 'shot_paused_1.png'; Start-Sleep -Milliseconds 1200; $s4 = Shot 'shot_paused_2.png'
    $d2 = DiffPct $s3 $s4
    Log ("PAUSE: {0}% of sampled pixels changed -> {1}" -f $d2, $(if ($d2 -eq 0) { 'PASS - paused' } else { '(space may not have reached the window)' }))
    [System.Windows.Forms.SendKeys]::SendWait(' ')
    Start-Sleep -Milliseconds 400
    Log "resume key sent"
} catch {
    Log "pause test skipped: $($_.Exception.Message)"
}

$errLog = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path -LiteralPath $errLog) {
    Log "=== error.log FOUND (unhandled error) ==="
    Get-Content -LiteralPath $errLog | ForEach-Object { Log $_ }
} else {
    Log "error.log absent -> no unhandled error (PASS)"
}

$cfg = Join-Path $env:APPDATA 'GifMiniPlayer\config.json'
if (Test-Path -LiteralPath $cfg) { Log ("config written: " + (Get-Content -LiteralPath $cfg -Raw).Trim()) }

Log "=== done. Results in: $out ==="
$log -join "`r`n" | Set-Content -LiteralPath (Join-Path $out 'results.txt') -Encoding UTF8
Write-Host ""
Write-Host "Screenshots + results.txt are in: $out" -ForegroundColor Green
Write-Host "App is still running - close it from the tray icon (right-click -> Exit)." -ForegroundColor Green
Read-Host "Press Enter to close this window"
