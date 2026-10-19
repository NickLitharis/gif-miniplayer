$lines = @()
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine -match 'GifMiniPlayer\.ps1' })
$lines += "player processes alive: $($procs.Count)"
foreach ($p in $procs) { $lines += "  pid=$($p.ProcessId)" }
$created = $false
$m = New-Object System.Threading.Mutex($false, 'Local\GifMiniPlayer.miniplayer', [ref]$created)
$lines += "mutex createdNew (no ownership requested) = $created"
$created2 = $false
$m2 = New-Object System.Threading.Mutex($true, 'Local\GifMiniPlayer.miniplayer', [ref]$created2)
$lines += "mutex createdNew (initially owned) = $created2"
$lines += "after [ref] writeback: created2 = $created2"
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=mutex.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
