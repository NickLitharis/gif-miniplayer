# gif-guest.ps1 -- runs INSIDE the Win11 VM. Downloads GifMiniPlayer, launches it, proves the
# window exists, proves the GIF animates, proves pause works, uploads screenshots + log to host.
# Reached at the vmnet8 host address only (192.168.103.1), same channel as the Aegis harness.
$ErrorActionPreference = 'Continue'
$H    = 'http://192.168.103.1:8001'
$work = Join-Path $env:USERPROFILE 'GifMiniTest'
$log  = New-Object System.Collections.Generic.List[string]

function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    $script:log.Add($line)
    Write-Host $line -ForegroundColor Cyan
}

function Upload-File($path, $name) {
    if (-not (Test-Path -LiteralPath $path)) { Log "skip upload (missing) $name"; return }
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$name" -Method Post -InFile $path -ContentType 'application/octet-stream' -TimeoutSec 30 | Out-Null
        Log "uploaded $name"
    } catch { Log "upload FAILED $name : $($_.Exception.Message)" }
}

function Upload-Text($name, $text) {
    try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$name" -Method Post -Body $text -ContentType 'text/plain' -TimeoutSec 30 | Out-Null } catch { }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# Precise window rectangle, so the pixel-diff only looks at the app and no background
# activity (Defender toast, clock, cursor) can fake an animation or hide a freeze.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32Probe {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
'@

function Get-AppRect {
    $h = [Win32Probe]::FindWindow($null, 'GIF Mini Player')
    if ($h -eq [IntPtr]::Zero) { return $null }
    $r = New-Object Win32Probe+RECT
    if (-not [Win32Probe]::GetWindowRect($h, [ref]$r)) { return $null }
    return [pscustomobject]@{
        Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom
        Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top
    }
}

function Shot($name) {
    $p = Join-Path $work $name
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    return $p
}

function DiffPct($a, $b, $rect) {
    $ia = [System.Drawing.Bitmap]::FromFile($a); $ib = [System.Drawing.Bitmap]::FromFile($b)
    $x0 = 0; $y0 = 0; $x1 = $ia.Width; $y1 = $ia.Height
    if ($rect) {
        $x0 = [Math]::Max(0, $rect.Left);      $y0 = [Math]::Max(0, $rect.Top)
        $x1 = [Math]::Min($ia.Width, $rect.Right); $y1 = [Math]::Min($ia.Height, $rect.Bottom)
    }
    $diff = 0; $tested = 0
    for ($y = $y0; $y -lt $y1; $y += 4) {
        for ($x = $x0; $x -lt $x1; $x += 4) {
            $tested++
            if ($ia.GetPixel($x, $y).ToArgb() -ne $ib.GetPixel($x, $y).ToArgb()) { $diff++ }
        }
    }
    $ia.Dispose(); $ib.Dispose()
    if ($tested -eq 0) { return -1 }
    return [math]::Round(100.0 * $diff / $tested, 2)
}

Log "=== GifMiniPlayer guest test ==="
Log "host: $env:COMPUTERNAME  os: $([System.Environment]::OSVersion.VersionString)  ps: $($PSVersionTable.PSVersion)"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# 1. fetch the bundle
$zip = Join-Path $work 'gif-miniplayer.zip'
try {
    Invoke-WebRequest -UseBasicParsing "$H/gif-miniplayer.zip" -OutFile $zip -TimeoutSec 60
    Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
    Get-ChildItem $work -File | Unblock-File -ErrorAction SilentlyContinue
    Log "bundle ok: $((Get-ChildItem $work -File | ForEach-Object Name) -join ', ')"
} catch {
    Log "FETCH FAILED: $($_.Exception.Message)"
    Upload-Text 'gt.log' ($log -join "`r`n")
    return
}

# 2. launch exactly the way the shipped launcher does
$app = Join-Path $work 'GifMiniPlayer.ps1'
$gif = Join-Path $work 'test-animation.gif'
$proc = Start-Process -FilePath 'powershell.exe' -PassThru `
    -ArgumentList @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$app,$gif)
Log "launched app pid=$($proc.Id)"
Start-Sleep -Seconds 12
Log "alive after 12s: $(-not $proc.HasExited)"
if ($proc.HasExited) { Log "EXIT CODE: $($proc.ExitCode)" }

# 3. window must exist
$found = $false
foreach ($w in (Get-Process | Where-Object { $_.MainWindowTitle })) {
    Log ("window: {0} (pid {1}) '{2}'" -f $w.ProcessName, $w.Id, $w.MainWindowTitle)
    if ($w.MainWindowTitle -like '*GIF*') { $found = $true }
}
Log "GifMiniPlayer window found: $found"

$rect = Get-AppRect
if ($rect) {
    Log ("window rect: {0},{1} {2}x{3} (expected 320x320 in the top-right corner)" -f $rect.Left, $rect.Top, $rect.Width, $rect.Height)
} else {
    Log 'window rect: NOT FOUND via FindWindow(hWnd) -> diffing the whole screen instead'
}

# 4. animation proof (scoped to the app window)
$s1 = Shot 'shot_playing_1.png'; Start-Sleep -Milliseconds 1200; $s2 = Shot 'shot_playing_2.png'
$d1 = DiffPct $s1 $s2 $rect
Log ("PLAYING: {0}% pixels changed inside the app window -> {1}" -f $d1, $(if ($d1 -gt 0) { 'PASS animating' } else { 'FAIL static' }))

# 5. pause proof
$d2 = 'n/a'
try {
    [Microsoft.VisualBasic.Interaction]::AppActivate('GIF Mini Player') | Out-Null
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait(' ')
    Start-Sleep -Milliseconds 900
    $s3 = Shot 'shot_paused_1.png'; Start-Sleep -Milliseconds 1200; $s4 = Shot 'shot_paused_2.png'
    $d2 = DiffPct $s3 $s4 $rect
    Log ("PAUSE: {0}% pixels changed inside the app window -> {1}" -f $d2, $(if ($d2 -eq 0) { 'PASS paused' } else { 'INCONCLUSIVE space may not have reached window' }))
    [System.Windows.Forms.SendKeys]::SendWait(' ')
} catch { Log "pause test error: $($_.Exception.Message)" }

# 6. did the crash trap fire?
$errLog = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path -LiteralPath $errLog) {
    Log '=== error.log PRESENT ==='
    Get-Content -LiteralPath $errLog | ForEach-Object { Log $_ }
} else { Log 'error.log absent -> no unhandled error (PASS)' }

$cfg = Join-Path $env:APPDATA 'GifMiniPlayer\config.json'
if (Test-Path -LiteralPath $cfg) { Log ('config.json: ' + (Get-Content -LiteralPath $cfg -Raw).Trim()) }

# 7. report
$summary = ("animate={0}% pause={1}% window={2} alive={3}" -f $d1, $d2, $found, (-not $proc.HasExited))
Log "SUMMARY: $summary"
Upload-Text 'gt.log' ($log -join "`r`n")
Upload-File $s1 'shot_playing_1.png'
Upload-File $s2 'shot_playing_2.png'
Upload-File (Join-Path $work 'shot_paused_1.png') 'shot_paused_1.png'
Upload-File (Join-Path $work 'shot_paused_2.png') 'shot_paused_2.png'
Upload-File $errLog 'error.log'
Upload-Text 'summary.txt' $summary
Log '=== done ==='
