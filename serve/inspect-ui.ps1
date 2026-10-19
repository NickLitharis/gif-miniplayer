# inspect-ui.ps1 -- dump the player window's child controls (class, text, rect) + error.log
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
function Post($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class UI {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
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
    public static string[] Children(IntPtr parent) {
        var list = new List<string>();
        EnumChildWindows(parent, (h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            RECT r; GetWindowRect(h, out r);
            list.Add(string.Format("class='{0}' text='{1}' {2}x{3} at {4},{5} visible={6}",
                c, t, r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top, IsWindowVisible(h)));
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
'@
$h = [UI]::FindApp()
$out = New-Object System.Collections.Generic.List[string]
$out.Add("app hwnd=0x$($h.ToString('X'))")
if ($h -ne [IntPtr]::Zero) { foreach ($c in [UI]::Children($h)) { $out.Add("child $c") } }
$err = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path -LiteralPath $err) { $out.Add('--- error.log ---'); Get-Content -LiteralPath $err | Select-Object -First 8 | ForEach-Object { $out.Add($_) } } else { $out.Add('error.log: absent') }
$out | ForEach-Object { Write-Host $_ }
Post 'inspect-ui.txt' ($out -join "`r`n")
