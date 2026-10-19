$root = Join-Path $env:LOCALAPPDATA 'GifMiniPlayer\builds'
$dir  = Get-ChildItem $root -Directory | Sort-Object Name -Descending | Select-Object -First 1
$run  = Join-Path $dir.FullName 'GifMiniPlayer.ps1'
$env:GMP_INSTANCE = 'dbg'
$outF = Join-Path $env:TEMP 'dbg-out.txt'; $errF = Join-Path $env:TEMP 'dbg-err.txt'
Remove-Item $outF, $errF -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ArgumentList @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$run) `
  -RedirectStandardOutput $outF -RedirectStandardError $errF -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 8
$lines = @("script: $run", "instance env: $env:GMP_INSTANCE", "started pid=$($proc.Id) exited=$($proc.HasExited) code=$(if($proc.HasExited){$proc.ExitCode}else{'n/a'})")
if (Test-Path $outF) { $lines += '--- stdout ---'; $lines += (Get-Content $outF -Raw) }
if (Test-Path $errF) { $lines += '--- stderr ---'; $lines += (Get-Content $errF -Raw) }
$lines += "--- windows titled GIF Mini ---"
$lines += (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like 'GIF Mini*' } | ForEach-Object { "pid=$($_.Id) title='$($_.MainWindowTitle)'" }) -join "`r`n"
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=rundebug.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
