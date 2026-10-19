# nuke.ps1 -- stop every PowerShell in the guest except the agent and this script.
$agentPid = 0
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
    if ($p.CommandLine -and $p.CommandLine -match 'agent\\agent\.ps1|\\a\.ps1') { $agentPid = $p.ProcessId; break }
}
$lines = @("keeping agent pid=$agentPid, self pid=$PID")
$stopped = @()
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
    if ($p.ProcessId -eq $PID -or $p.ProcessId -eq $agentPid) { continue }
    $tk = & taskkill.exe /F /PID $p.ProcessId 2>&1 | Out-String
    $stopped += "$($p.ProcessId): $($tk.Trim())"
}
$lines += $stopped
Get-Process -Name GifMiniPlayer -ErrorAction SilentlyContinue | ForEach-Object {
    & taskkill.exe /F /IM GifMiniPlayer.exe 2>&1 | Out-Null
    $lines += "killed exe pid $($_.Id)"
}
Start-Sleep -Seconds 2
$still = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.ProcessId -ne $agentPid })
$lines += "powershell processes left: $($still.Count)"
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=nuke.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
