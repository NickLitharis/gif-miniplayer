$lines = @()
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
    if ($p.CommandLine -and $p.CommandLine -match 'GifMiniPlayer\.ps1') {
        $lines += "player pid=$($p.ProcessId) session=$($p.SessionId) path=$($p.CommandLine)"
    }
}
if (-not $lines) { $lines += 'no player processes' }
$lines += "agent pid=$PID elevated=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=whoami2.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
