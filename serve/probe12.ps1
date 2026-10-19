# probe12.ps1 -- leak test, done right: FOCUS the app window first, then Delete twice.
# GDI object count (GetGuiResources) must DROP when the playlist empties if the buffer,
# Image and stream are really disposed.
param([string]$Which = 'fixed')
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Post($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W12 {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr h, uint flags);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    public static IntPtr FindApp() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 100) return true;
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }
    public static bool Focus(IntPtr target) {
        IntPtr fg = GetForegroundWindow();
        uint fgT = fg == IntPtr.Zero ? 0 : (uint)0;
        IntPtr pidRef = IntPtr.Zero;
        SetForegroundWindow(target); BringWindowToTop(target); SetFocus(target);
        return GetForegroundWindow() == target;
    }
    public static int Gdi(int pid) {
        IntPtr h = OpenProcess(0x0400, false, pid);
        if (h == IntPtr.Zero) h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return -2;
        int v = (int)GetGuiResources(h, 0);
        CloseHandle(h); return v;
    }
}
'@

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

$proc = Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList @(
    '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$app,$a,$b)
$appPid = $proc.Id
Start-Sleep -Seconds 9

$hwnd = [W12]::FindApp()
$focused = $false
if ($hwnd -ne [IntPtr]::Zero) { $focused = [W12]::Focus($hwnd) }
Log "build=$Which pid=$appPid hwnd=0x$($hwnd.ToString('X')) focused=$focused"
Start-Sleep -Milliseconds 800

$gdiBefore = [W12]::Gdi($appPid)
Log "before: gdi=$gdiBefore"

[System.Windows.Forms.SendKeys]::SendWait('{DELETE}')
Start-Sleep -Milliseconds 1000
[System.Windows.Forms.SendKeys]::SendWait('{DELETE}')
Start-Sleep -Seconds 2

$gdiAfter = [W12]::Gdi($appPid)
$alive = -not $proc.HasExited
Log "after 2x DELETE: gdi=$gdiAfter alive=$alive"
$errLog = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
$errPresent = Test-Path -LiteralPath $errLog

$verdict = "build=$Which focused=$focused gdi_before=$gdiBefore gdi_after=$gdiAfter delta=$($gdiAfter - $gdiBefore) alive=$alive errorlog=$errPresent"
Log "VERDICT: $verdict"
Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue
Post "probe12-summary-$Which.txt" $verdict
Post 'probe12.log' ($log -join "`r`n")
