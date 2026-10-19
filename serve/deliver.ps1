# deliver.ps1 -- put the finished player on the guest's Desktop and start it. No tests.
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
function Post($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }

$dest = Join-Path $env:USERPROFILE 'Desktop\GifMiniPlayer'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$zip = Join-Path $dest 'gif-miniplayer.zip'
Invoke-WebRequest -UseBasicParsing "$H/gif-miniplayer.zip" -OutFile $zip -TimeoutSec 60
Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
Get-ChildItem $dest -File | Unblock-File -ErrorAction SilentlyContinue

# make sure there are at least two GIFs to flip between, right next to the app
$gifs = @()
foreach ($n in @('gifA.gif', 'gifB.gif', 'test-animation.gif')) {
    $p = Join-Path $dest $n
    if (-not (Test-Path -LiteralPath $p)) {
        try { Invoke-WebRequest -UseBasicParsing "$H/$n" -OutFile $p -TimeoutSec 60 } catch { }
    }
    if (Test-Path -LiteralPath $p) { $gifs += $p }
}

$app = Join-Path $dest 'GifMiniPlayer.ps1'
$proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList (@(
    '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$app) + $gifs)
Start-Sleep -Seconds 8

$alive = -not $proc.HasExited
$files = (Get-ChildItem $dest -File | ForEach-Object Name) -join ', '
$msg = "installed_to=$dest pid=$($proc.Id) alive=$alive gifs=$($gifs.Count) files=[$files]"
Write-Host $msg
Post 'deliver-summary.txt' $msg
