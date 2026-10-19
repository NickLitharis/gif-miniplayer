$run  = Join-Path $env:LOCALAPPDATA 'GifMiniPlayer\run\GifMiniPlayer.ps1'
$demo = Join-Path $env:USERPROFILE 'Desktop\GifMiniPlayer\demo-a.gif'
$outF = Join-Path $env:TEMP 'gmp-out.txt'
$errF = Join-Path $env:TEMP 'gmp-err.txt'
Remove-Item $outF, $errF -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$run) `
    -RedirectStandardOutput $outF -RedirectStandardError $errF -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 9
$lines = @("pid=$($proc.Id) exited=$($proc.HasExited)")
if ($proc.HasExited) { $lines += "exitcode=$($proc.ExitCode)" }
if (Test-Path $outF) { $lines += '--- stdout ---'; $lines += (Get-Content $outF -Raw) }
if (Test-Path $errF) { $lines += '--- stderr ---'; $lines += (Get-Content $errF -Raw) }
$err = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path $err) { $lines += '--- error.log ---'; $lines += (Get-Content $err -Raw) } else { $lines += 'error.log absent' }
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=rundirect.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
