# probe10.ps1 -- animation CORRECTNESS probe. Exports every frame of a GIF through the exact
# API the player uses (Image.SelectActiveFrame) so the host can diff them against a reference
# renderer. Also reports the frame count and per-frame delays the player actually reads.
param([string]$File = 'hard.gif')
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$dir = Join-Path $env:USERPROFILE 'GifMiniTest\anim'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Post($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }
function Up($p, $n) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -InFile $p -ContentType 'application/octet-stream' -TimeoutSec 25 | Out-Null } catch { } }

Add-Type -AssemblyName System.Drawing
$path = Join-Path $dir $File
Invoke-WebRequest -UseBasicParsing "$H/$File" -OutFile $path -TimeoutSec 60
Log "file=$File size=$((Get-Item $path).Length)"

$img = [System.Drawing.Image]::FromFile($path)
$fd  = [System.Drawing.Imaging.FrameDimension]::Time
$n   = $img.GetFrameCount($fd)
Log "GetFrameCount(Time) = $n"
Log "image logical size = $($img.Width)x$($img.Height)"

$delays = @()
try {
    $prop = $img.GetPropertyItem(0x5100)
    $raw = $prop.Value
    for ($i = 0; $i -lt [int]($raw.Length / 4); $i++) { $delays += [System.BitConverter]::ToInt32($raw, $i * 4) }
    Log "delays from 0x5100 ($($delays.Count) values): $($delays -join ',')"
    Log "total duration per loop: $((($delays | Measure-Object -Sum).Sum * 10)) ms"
} catch {
    Log "0x5100 frame delay property MISSING: $($_.Exception.Message)"
}

for ($i = 0; $i -lt $n; $i++) {
    $img.SelectActiveFrame($fd, $i) | Out-Null
    $out = Join-Path $dir ("gdi-{0:00}.png" -f $i)
    $img.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    Log ("frame {0}: size after SelectActiveFrame = {1}x{2}" -f $i, $img.Width, $img.Height)
    Up $out ("gdi-{0:00}.png" -f $i)
}
$img.Dispose()

Log '=== done ==='
Post 'probe10.log' ($log -join "`r`n")
Post 'probe10-summary.txt' "frames=$n delays=$($delays -join ',') file=$File"
