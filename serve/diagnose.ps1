$lines = @()
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine -match 'GifMiniPlayer' }
foreach ($p in $procs) { $lines += "pid=$($p.ProcessId) cmd=$($p.CommandLine)" }
if (-not $procs) { $lines += 'no GifMiniPlayer powershell processes' }
$err = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path $err) { $lines += '--- error.log ---'; $lines += (Get-Content $err -Raw) }
else { $lines += 'error.log absent' }
$run = Join-Path $env:LOCALAPPDATA 'GifMiniPlayer\run\GifMiniPlayer.ps1'
$lines += "extracted script exists: $(Test-Path $run)"
if (Test-Path $run) { $lines += "extracted script bytes: $((Get-Item $run).Length)" }
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString("http://192.168.103.1:8001/upload?name=diag.txt",'POST',($lines -join "`r`n")) | Out-Null } catch {}
