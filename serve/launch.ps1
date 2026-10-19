# launch.ps1 -- start the player and LEAVE IT RUNNING. Reports the window + button rects.
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$dir = Join-Path $env:USERPROFILE 'Desktop\GifMiniPlayer'
function Post($n, $t) { try { (New-Object Net.WebClient).UploadString("$H/upload?name=$n", 'POST', $t) | Out-Null } catch { } }
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class L1 {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public static IntPtr Find(out RECT rect) {
        IntPtr found = IntPtr.Zero; RECT fr = new RECT();
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 100) return true;
            found = h; fr = r; return false;
        }, IntPtr.Zero);
        rect = fr; return found;
    }
    public static string[] Kids(IntPtr parent) {
        var list = new List<string>();
        EnumChildWindows(parent, (h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            RECT r; GetWindowRect(h, out r);
            list.Add(string.Format("{0}\t{1}\t{2}x{3}\t{4},{5}\tvis={6}", c, t, r.Right-r.Left, r.Bottom-r.Top, r.Left, r.Top, IsWindowVisible(h)));
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
'@
# ALWAYS refresh from the served bundle: a stale local folder is how the old mojibake
# buttons kept reappearing.
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$zip = Join-Path $dir 'b.zip'
(New-Object Net.WebClient).DownloadFile("$H/gif-miniplayer.zip", $zip)
Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
Get-ChildItem $dir -File | Unblock-File -ErrorAction SilentlyContinue
Write-Host "refreshed $dir from server"

foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
    if ($p.ProcessId -ne $PID -and $p.CommandLine -and $p.CommandLine -match 'GifMiniPlayer\.ps1') {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2
$gifs = @(Get-ChildItem $dir -Filter 'demo-*.gif' | Sort-Object Name | ForEach-Object FullName)
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList (@(
    '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $dir 'GifMiniPlayer.ps1')) + $gifs) | Out-Null
Start-Sleep -Seconds 8
$r = New-Object L1+RECT
$hwnd = [L1]::Find([ref]$r)
$lines = @("hwnd=0x$($hwnd.ToString('X')) rect=$($r.Left),$($r.Top) $($r.Right-$r.Left)x$($r.Bottom-$r.Top)")
foreach ($k in [L1]::Kids($hwnd)) { $lines += $k }
$lines | ForEach-Object { Write-Host $_ }
Post 'layout.txt' ($lines -join "`r`n")
"left running"
