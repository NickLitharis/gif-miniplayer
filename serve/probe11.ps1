# probe11.ps1 -- leak test for emptying the playlist.
# Counts the app's GDI objects (GetGuiResources) before and after two Delete presses, which
# remove both GIFs and leave the playlist empty. A leak shows as no drop; the fix shows a drop.
#   fixed : the served (fixed) build
#   loot  : the stale build in GifMiniTest (pre-fix), as the negative control
param([string]$Which = 'fixed')
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Post($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }

Add-Type -AssemblyName System.Windows.Forms
try {
    Add-Type -ErrorAction Stop @'
using System;
using System.Runtime.InteropServices;
public class ResProbe {
    [DllImport("user32.dll", SetLastError=true)] public static extern uint GetGuiResources(IntPtr hProcess, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    public static int GdiObjects(int pid) {
        IntPtr h = OpenProcess(0x0400, false, pid);
        if (h == IntPtr.Zero) h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return -2;
        uint v = GetGuiResources(h, 0);
        CloseHandle(h);
        return (int)v;
    }
    public static int UserObjects(int pid) {
        IntPtr h = OpenProcess(0x0400, false, pid);
        if (h == IntPtr.Zero) h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return -2;
        uint v = GetGuiResources(h, 1);
        CloseHandle(h);
        return (int)v;
    }
}
'@
    Log "helper compiled OK"
} catch {
    Log "ADD-TYPE FAILED: $($_.Exception.Message)"
}
function Gdi-Count([int]$targetPid) {
    try { return [ResProbe]::GdiObjects($targetPid) } catch { Log "GdiObjects failed: $($_.Exception.Message)"; return -3 }
}
function Usr-Count([int]$targetPid) {
    try { return [ResProbe]::UserObjects($targetPid) } catch { return -3 }
}

if ($Which -eq 'fixed') {
    $dir = Join-Path $env:USERPROFILE 'GifMiniTest2'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Invoke-WebRequest -UseBasicParsing "$H/gif-miniplayer.zip" -OutFile (Join-Path $dir 'b.zip') -TimeoutSec 60
    Expand-Archive -LiteralPath (Join-Path $dir 'b.zip') -DestinationPath $dir -Force
    Get-ChildItem $dir -File | Unblock-File -ErrorAction SilentlyContinue
} else {
    $dir = Join-Path $env:USERPROFILE 'GifMiniTest'
}
$app = Join-Path $dir 'GifMiniPlayer.ps1'
$a = Join-Path $env:USERPROFILE 'GifMiniTest\gifA.gif'
$b = Join-Path $env:USERPROFILE 'GifMiniTest\gifB.gif'
$errLog = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path -LiteralPath $errLog) { Remove-Item -LiteralPath $errLog -Force }
Log "build=$Which app=$app"

$proc = Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList @(
    '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$app,$a,$b)
$appPid = $proc.Id
Start-Sleep -Seconds 10
$gdiBefore = Gdi-Count $appPid
$usrBefore = Usr-Count $appPid
Log "before delete: gdi=$gdiBefore user=$usrBefore (two GIFs loaded)"

# focus so Delete reaches the form
[System.Windows.Forms.SendKeys]::SendWait('{DELETE}')
Start-Sleep -Milliseconds 900
[System.Windows.Forms.SendKeys]::SendWait('{DELETE}')
Start-Sleep -Seconds 2
$gdiAfter = Gdi-Count $appPid
$usrAfter = Usr-Count $appPid
$alive = -not $proc.HasExited
Log "after deleting both: gdi=$gdiAfter user=$usrAfter (playlist empty) alive=$alive"

$delta = if ($gdiBefore -gt 0 -and $gdiAfter -gt 0) { $gdiAfter - $gdiBefore } else { 999 }
$errorPresent = Test-Path -LiteralPath $errLog
if ($errorPresent) { Log 'error.log PRESENT:'; Get-Content -LiteralPath $errLog | Select-Object -First 4 | ForEach-Object { Log "err $_" } }

$verdict = "build=$Which gdi_before=$gdiBefore gdi_after=$gdiAfter gdi_delta=$delta user_after=$usrAfter alive=$alive errorlog=$errorPresent"
Log "VERDICT: $verdict"
Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue
Post "probe11-summary-$Which.txt" $verdict
Post 'probe11.log' ($log -join "`r`n")
