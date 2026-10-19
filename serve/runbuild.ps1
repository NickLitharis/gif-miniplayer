$root = Join-Path $env:LOCALAPPDATA 'GifMiniPlayer\builds'
$dir  = Get-ChildItem $root -Directory | Sort-Object Name -Descending | Select-Object -First 1
$run  = Join-Path $dir.FullName 'GifMiniPlayer.ps1'
$lines = @("build dir: $($dir.Name)", "script bytes: $((Get-Item $run).Length)")
# stop anything already running so the mutex is free
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
    if ($p.ProcessId -ne $PID -and $p.CommandLine -and $p.CommandLine -match 'GifMiniPlayer\.ps1') {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2
$outF = Join-Path $env:TEMP 'b-out.txt'; $errF = Join-Path $env:TEMP 'b-err.txt'
Remove-Item $outF, $errF -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$run) `
    -RedirectStandardOutput $outF -RedirectStandardError $errF -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 9
$lines += "pid=$($proc.Id) exited=$($proc.HasExited) exitcode=$(if ($proc.HasExited) { $proc.ExitCode } else { 'n/a' })"
if (Test-Path $outF) { $lines += '--- stdout ---'; $lines += (Get-Content $outF -Raw) }
if (Test-Path $errF) { $lines += '--- stderr ---'; $lines += (Get-Content $errF -Raw) }
$err = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path $err) { $lines += '--- error.log ---'; $lines += (Get-Content $err -Raw) } else { $lines += 'error.log absent' }
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=runbuild.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
