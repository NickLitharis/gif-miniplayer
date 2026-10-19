# close-app.ps1 -- close GifMiniPlayer gracefully in the guest.
# Posts WM_CLOSE (the same path as clicking the X), so FormClosing runs and config is saved,
# then verifies the window is gone and the process exited.
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$w = Join-Path $env:USERPROFILE 'GifMiniTest'
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function UpText($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 25 | Out-Null } catch { } }

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class WC {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);

    // small or large: match the WinForms window titled 'GIF Mini Player' regardless of size
    public static List<IntPtr> FindAppWindows(out List<string> info) {
        var hits = new List<IntPtr>(); var meta = new List<string>();
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            RECT r; GetWindowRect(h, out r);
            bool vis = IsWindowVisible(h);
            uint pid; GetWindowThreadProcessId(h, out pid);
            hits.Add(h);
            meta.Add(string.Format("hwnd=0x{0:X} pid={1} visible={2} {3}x{4} at {5},{6}",
                (long)h, pid, vis, r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top));
            return true;
        }, IntPtr.Zero);
        info = meta;
        return hits;
    }
}
'@

Log '=== close-app ==='
$info = $null
$wins = [WC]::FindAppWindows([ref]$info)
foreach ($i in $info) { Log "found $i" }
if ($wins.Count -eq 0) {
    Log 'no GifMiniPlayer window found -> already closed'
    UpText 'close-summary.txt' 'already-closed'
    UpText 'close.log' ($log -join "`r`n")
    return
}

foreach ($h in $wins) { [WC]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }  # WM_CLOSE
Log "posted WM_CLOSE to $($wins.Count) window(s)"
Start-Sleep -Seconds 3

$after = $null
$still = [WC]::FindAppWindows([ref]$after)
foreach ($i in $after) { Log "still there: $i" }
$running = @(Get-Process -Name powershell -ErrorAction SilentlyContinue |
             Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -eq 'GIF Mini Player' })
Log "windows remaining: $($still.Count)"
Log "app processes remaining: $($running.Count)"

$cfg = Join-Path $env:APPDATA 'GifMiniPlayer\config.json'
if (Test-Path -LiteralPath $cfg) {
    Log ('config saved on close: ' + ((Get-Content -LiteralPath $cfg -Raw) -replace '\s+', ' ').Trim())
} else { Log 'config.json missing' }

$verdict = if ($still.Count -eq 0) { 'CLOSED' } else { 'STILL RUNNING' }
Log "VERDICT: $verdict"
UpText 'close-summary.txt' $verdict
UpText 'close.log' ($log -join "`r`n")
Log '=== close-app done ==='
