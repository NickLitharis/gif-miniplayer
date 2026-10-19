# guest-test.ps1 -- runs inside the Windows 11 VM. Downloads GifMiniPlayer, launches it,
# proves the window exists and the GIF is actually animating, tests pause, then uploads
# screenshots and logs back to the host and shuts the VM down.
$ErrorActionPreference = 'Continue'
$Host_  = 'http://10.0.2.2:8001'
$Files_ = 'http://10.0.2.2:8000'
$log    = New-Object System.Collections.Generic.List[string]

function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    $script:log.Add($line)
    Write-Host $line
}

function Send-Text($name, $text) {
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$Host_/u?name=$name" -Method Post -Body $text -ContentType 'text/plain' -TimeoutSec 25 | Out-Null
    } catch { }
}

function Send-File($path, $name) {
    if (-not (Test-Path -LiteralPath $path)) { Log "skip upload (missing): $path"; return }
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$Host_/u?name=$name" -Method Post -InFile $path -ContentType 'application/octet-stream' -TimeoutSec 40 | Out-Null
        Log "uploaded $name ($((Get-Item $path).Length) bytes)"
    } catch { Log "upload FAILED $name : $($_.Exception.Message)" }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

function Shot($path) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Log "screenshot -> $path"
}

function DiffPixels($a, $b) {
    try {
        $ia = [System.Drawing.Bitmap]::FromFile($a)
        $ib = [System.Drawing.Bitmap]::FromFile($b)
        $diff = 0; $tested = 0
        for ($y = 0; $y -lt $ia.Height; $y += 8) {
            for ($x = 0; $x -lt $ia.Width; $x += 8) {
                $tested++
                if ($ia.GetPixel($x, $y).ToArgb() -ne $ib.GetPixel($x, $y).ToArgb()) { $diff++ }
            }
        }
        $ia.Dispose(); $ib.Dispose()
        return [pscustomobject]@{ Diff = $diff; Tested = $tested; Pct = [math]::Round(100.0 * $diff / [math]::Max(1, $tested), 2) }
    } catch { return [pscustomobject]@{ Diff = -1; Tested = 0; Pct = -1 } }
}

Log "=== guest test start on $env:COMPUTERNAME ($([System.Environment]::OSVersion.VersionString)) ==="

# 1. wait for the host to be reachable
$net = $false
for ($i = 0; $i -lt 60; $i++) {
    try { Invoke-WebRequest -UseBasicParsing "$Files_/" -TimeoutSec 5 | Out-Null; $net = $true; break } catch { Start-Sleep -Seconds 3 }
}
Log "network to host: $net"
if (-not $net) { Send-Text 'gt.log' ($log -join "`r`n"); exit 1 }

# 2. fetch and unpack the app
$zip = 'C:\gmp.zip'
try {
    Invoke-WebRequest -UseBasicParsing "$Files_/gif-miniplayer.zip" -OutFile $zip -TimeoutSec 60
    if (Test-Path C:\gmp) { Remove-Item C:\gmp -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath C:\gmp -Force
    Get-ChildItem C:\gmp -File | Unblock-File
    Log "unpacked: $((Get-ChildItem C:\gmp -File | ForEach-Object Name) -join ', ')"
} catch {
    Log "download/unpack FAILED: $($_.Exception.Message)"
    Send-Text 'gt.log' ($log -join "`r`n")
    exit 1
}

# 3. launch the app exactly as the .bat does
$psArgs = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\gmp\GifMiniPlayer.ps1', 'C:\gmp\test-animation.gif')
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -PassThru
Log "launched powershell pid=$($proc.Id)"
Start-Sleep -Seconds 12
Log "app process alive after 12s: $(-not $proc.HasExited)"
if ($proc.HasExited) { Log "exit code: $($proc.ExitCode)" }

# 4. does the window exist?
$wins = Get-Process | Where-Object { $_.MainWindowTitle } | Select-Object ProcessName, Id, MainWindowTitle
foreach ($w in $wins) { Log ("window: {0} (pid {1}) '{2}'" -f $w.ProcessName, $w.Id, $w.MainWindowTitle) }

# 5. animation proof: two shots 1.2s apart must differ
Shot 'C:\shot_playing_1.png'
Start-Sleep -Milliseconds 1200
Shot 'C:\shot_playing_2.png'
$d1 = DiffPixels 'C:\shot_playing_1.png' 'C:\shot_playing_2.png'
Log ("animation: {0} of {1} sampled pixels changed ({2}%) -> {3}" -f $d1.Diff, $d1.Tested, $d1.Pct,
     $(if ($d1.Diff -gt 0) { 'ANIMATING' } else { 'STATIC - animation NOT running' }))

# 6. pause test: focus the window, send Space, two more shots must match
try {
    [Microsoft.VisualBasic.Interaction]::AppActivate('GIF Mini Player') | Out-Null
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.SendKeys]::SendWait(' ')
    Start-Sleep -Milliseconds 800
    Shot 'C:\shot_paused_1.png'
    Start-Sleep -Milliseconds 1200
    Shot 'C:\shot_paused_2.png'
    $d2 = DiffPixels 'C:\shot_paused_1.png' 'C:\shot_paused_2.png'
    Log ("pause: {0} of {1} sampled pixels changed ({2}%) -> {3}" -f $d2.Diff, $d2.Tested, $d2.Pct,
         $(if ($d2.Diff -eq 0) { 'PAUSED correctly' } else { 'still moving - pause did NOT work' }))
} catch {
    Log "pause test error: $($_.Exception.Message)"
}

# 7. error log, if the trap fired
$errLog = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path -LiteralPath $errLog) {
    Log "=== error.log present ==="
    Get-Content -LiteralPath $errLog | ForEach-Object { Log $_ }
} else {
    Log "error.log: absent (no unhandled error)"
}

# 8. send everything back
Send-Text 'gt.log' ($log -join "`r`n")
Send-File 'C:\shot_playing_1.png' 'shot_playing_1.png'
Send-File 'C:\shot_playing_2.png' 'shot_playing_2.png'
Send-File 'C:\shot_paused_1.png'  'shot_paused_1.png'
Send-File 'C:\shot_paused_2.png'  'shot_paused_2.png'
Send-File $errLog                 'error.log'
Send-Text 'done.txt' ("diff_playing={0}% diff_paused={1}% alive={2}`r`n" -f $d1.Pct, $(if ($d2) { $d2.Pct } else { 'n/a' }), (-not $proc.HasExited))

# 9. leave the machine ready for shutdown from the host
Log "=== guest test finished ==="
Send-Text 'gt.log' ($log -join "`r`n")
