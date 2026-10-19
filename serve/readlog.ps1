$err = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
$lines = @()
if (Test-Path $err) {
    $lines += "error.log ($((Get-Item $err).Length) bytes):"
    $lines += (Get-Content $err -Raw)
} else { $lines += 'error.log absent' }
foreach ($p in (Get-Process -Id 5364 -ErrorAction SilentlyContinue)) {
    $lines += "pid 5364: responding=$($p.Responding) mainWindow='$($p.MainWindowTitle)' threads=$($p.Threads.Count) cpu=$($p.TotalProcessorTime)"
}
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=readlog.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
