# restart-clean.ps1 -- kill EVERY GifMiniPlayer instance (visible or hidden in the tray),
# then launch exactly one instance of the build on the Desktop.
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Post($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WK {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    // every top-level app window, INCLUDING ones hidden in the tray
    public static string[] Dump(out int visibleCount) {
        var list = new System.Collections.Generic.List<string>();
        int vis = 0;
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 100) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            bool v = IsWindowVisible(h);
            if (v) vis++;
            list.Add(string.Format("{0}|{1}|{2}|{3}x{4}", pid, (long)h, v ? "visible" : "hidden", r.Right - r.Left, r.Bottom - r.Top));
            return true;
        }, IntPtr.Zero);
        visibleCount = vis;
        return list.ToArray();
    }
    public static void Raise(IntPtr h) { BringWindowToTop(h); SetForegroundWindow(h); }
}
'@

# 1. every process whose command line runs the player (catches hidden/tray instances)
$victims = @()
try {
    $victims = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'GifMiniPlayer\.ps1' } |
        ForEach-Object { $_.ProcessId }
} catch { Log "CIM query failed: $($_.Exception.Message)" }
Log "processes running the player: $($victims -join ',')"

# also add any pid that owns an app window, visible or not
$vis = 0
foreach ($row in [WK]::Dump([ref]$vis)) {
    $p = [int]($row -split '\|')[0]
    if ($victims -notcontains $p) { $victims += $p }
}
Log "all target pids: $($victims -join ',')  (windows now: $($vis) visible)"

foreach ($p in $victims) {
    if ($p -eq $PID) { continue }
    try { Stop-Process -Id $p -Force -ErrorAction Stop; Log "killed pid $p" } catch { Log "kill $p failed: $($_.Exception.Message)" }
}
Start-Sleep -Seconds 3

$vis2 = 0
$left = [WK]::Dump([ref]$vis2)
Log "after kill: $($left.Count) window(s) left, $vis2 visible"
if ($left.Count -gt 0) { Post 'restart-summary.txt' "FAILED to kill: $($left -join ' ; ')"; Post 'restart.log' ($log -join "`r`n"); return }

# 2. launch exactly one instance of the Desktop build
$dir = Join-Path $env:USERPROFILE 'Desktop\GifMiniPlayer'
$app = Join-Path $dir 'GifMiniPlayer.ps1'
# refresh the build so the Desktop copy is always the current one
$zip = Join-Path $dir 'gif-miniplayer.zip'
try {
    Invoke-WebRequest -UseBasicParsing "$H/gif-miniplayer.zip" -OutFile $zip -TimeoutSec 60
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    Get-ChildItem $dir -File | Unblock-File -ErrorAction SilentlyContinue
    Log 'build refreshed from server'
} catch { Log "refresh failed: $($_.Exception.Message)" }

if (-not (Test-Path -LiteralPath $app)) {
    Log "MISSING $app"
    Post 'restart-summary.txt' "MISSING $app"
    Post 'restart.log' ($log -join "`r`n")
    return
}
$gifs = Get-ChildItem $dir -Filter *.gif | Sort-Object Name | ForEach-Object FullName
Log "launching $app with $($gifs.Count) gifs"
$proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList (@(
    '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$app) + $gifs)
Start-Sleep -Seconds 8

$vis3 = 0
$now = [WK]::Dump([ref]$vis3)
Log "new pid=$($proc.Id) alive=$(-not $proc.HasExited) windows=$($now.Count) visible=$vis3"
foreach ($row in $now) { Log "window $row" }

# raise it so it is the one on screen
if ($now.Count -gt 0) {
    $hwnd = [IntPtr][Convert]::ToInt64(($now[0] -split '\|')[1])
    [WK]::Raise($hwnd)
    Log 'raised the new window'
}

$verdict = "killed=$($victims.Count) new_pid=$($proc.Id) windows=$($now.Count) visible=$vis3 gifs=$($gifs.Count)"
Log "VERDICT: $verdict"
Post 'restart-summary.txt' $verdict
Post 'restart.log' ($log -join "`r`n")
