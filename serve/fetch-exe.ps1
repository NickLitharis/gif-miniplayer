$H = 'http://192.168.103.1:8001'
$exe = Join-Path $env:USERPROFILE 'Desktop\GifMiniPlayer\GifMiniPlayer.exe'
$bytes = [System.IO.File]::ReadAllBytes($exe)
(New-Object Net.WebClient).UploadData("$H/upload?name=GifMiniPlayer.exe", 'POST', $bytes) | Out-Null
Write-Host "uploaded $([math]::Round($bytes.Length/1KB,1)) KB"
