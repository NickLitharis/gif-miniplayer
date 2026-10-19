# desktop.ps1 -- put the current build on the guest's Desktop: a folder plus a shortcut.
$ErrorActionPreference = 'Stop'
$H = 'http://192.168.103.1:8001'
function Post($name, $text) {
    try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$name" -Method Post -Body $text -ContentType 'text/plain' -TimeoutSec 15 | Out-Null } catch { }
}

$desk = [Environment]::GetFolderPath('Desktop')
$dest = Join-Path $desk 'GIF Mini Player'
$zip  = Join-Path $env:TEMP 'gmp-desktop.zip'
$ico  = Join-Path $dest 'app.ico'

(New-Object Net.WebClient).DownloadFile("$H/gif-miniplayer.zip", $zip)
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
# the bundle has no exe; the zip ships the .bat launcher. Its icon comes from the server.
try { (New-Object Net.WebClient).DownloadFile("$H/app.ico", $ico) } catch { }

$lnk = Join-Path $desk 'GIF Mini Player.lnk'
$sh = New-Object -ComObject WScript.Shell
$sc = $sh.CreateShortcut($lnk)
$sc.TargetPath       = Join-Path $dest 'Run-GifMiniPlayer.bat'
$sc.WorkingDirectory = $dest
$sc.Description      = 'GIF Mini Player'
if (Test-Path -LiteralPath $ico) { $sc.IconLocation = "$ico,0" }
$sc.Save()

$names = (Get-ChildItem -LiteralPath $dest -File | Select-Object -ExpandProperty Name) -join ', '
Post 'desktop-summary.txt' "placed the build on the Desktop`r`n  folder:   $dest`r`n  shortcut: $lnk`r`n  files:    $names"
Write-Host "ok: $lnk"
