# probe4.ps1 -- verify the FIXED build: focus by window size+pid (not by title), send a real
# SPACE, and prove pause/resume by pixel-diffing only the app's 320x320 corner.
# Also reports error.log, which now captures both script traps AND WinForms UI exceptions.
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$w = Join-Path $env:USERPROFILE 'GifMiniTest'
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Up($p, $n) { if (Test-Path -LiteralPath $p) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -InFile $p -ContentType 'application/octet-stream' -TimeoutSec 30 | Out-Null } catch { Log "upload failed $n" } } }
function UpText($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 30 | Out-Null } catch { } }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W4 {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    public static IntPtr FindBySize(int width, int height, out uint pidOut, out int ax, out int ay) {
        IntPtr found = IntPtr.Zero; uint fp = 0; int fx = 0, fy = 0;
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) == width && (r.Bottom - r.Top) == height) {
                uint pid; GetWindowThreadProcessId(h, out pid);
                found = h; fp = pid; fx = r.Left; fy = r.Top; return false;
            }
            return true;
        }, IntPtr.Zero);
        pidOut = fp; ax = fx; ay = fy;
        return found;
    }
    public static bool ForceForeground(IntPtr target) {
        IntPtr fg = GetForegroundWindow();
        uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero);
        uint myThread = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != 0 && fgThread != myThread) attached = AttachThreadInput(myThread, fgThread, true);
        BringWindowToTop(target); SetForegroundWindow(target); SetFocus(target);
        if (attached) AttachThreadInput(myThread, fgThread, false);
        return GetForegroundWindow() == target;
    }
}
'@

Log '=== probe4: fixed build, real keystroke ==='

# clear out any old instance and stale exception dialog
foreach ($p in Get-Process -Name powershell -ErrorAction SilentlyContinue) {
    if ($p.Id -ne $PID -and $p.MainWindowTitle -eq 'GIF Mini Player') { Stop-Process -Id $p.Id -Force; Log "killed old app pid $($p.Id)" }
}
$tmpPid = 0; $x = 0; $y = 0
$old = [W4]::FindBySize(320, 320, [ref]$tmpPid, [ref]$x, [ref]$y)
if ($old -ne [IntPtr]::Zero) { Stop-Process -Id $tmpPid -Force -ErrorAction SilentlyContinue; Log "killed lingering app pid $tmpPid" }
Start-Sleep -Seconds 2

$errLog = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path -LiteralPath $errLog) { Remove-Item -LiteralPath $errLog -Force; Log 'cleared previous error.log' }

# fresh, CLEAN (uninstrumented) build
Invoke-WebRequest -UseBasicParsing "$H/gif-miniplayer.zip" -OutFile (Join-Path $w 'g.zip') -TimeoutSec 60
Expand-Archive -LiteralPath (Join-Path $w 'g.zip') -DestinationPath $w -Force
Get-ChildItem $w -File | Unblock-File -ErrorAction SilentlyContinue
$hasDbg = (Select-String -Path (Join-Path $w 'GifMiniPlayer.ps1') -Pattern 'gmp-dbg' -SimpleMatch).Count
Log "served build debug points: $hasDbg (expect 0)"

$proc = Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList @(
    '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $w 'GifMiniPlayer.ps1'),(Join-Path $w 'test-animation.gif'))
Start-Sleep -Seconds 10

$appPid = 0; $appX = 0; $appY = 0
$hwnd = [W4]::FindBySize(320, 320, [ref]$appPid, [ref]$appX, [ref]$appY)
Log "app hwnd=0x$($hwnd.ToString('X')) pid=$appPid at $appX,$appY alive=$(-not $proc.HasExited)"
if ($hwnd -eq [IntPtr]::Zero) { UpText 'probe4.log' ($log -join "`r`n"); return }

function Shot($n) {
    $p = Join-Path $w $n
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $b = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($b); $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $b.Size)
    $b.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $b.Dispose(); return $p
}
function DiffApp($a, $b, $left, $top) {
    $ia = [System.Drawing.Bitmap]::FromFile($a); $ib = [System.Drawing.Bitmap]::FromFile($b)
    $d = 0; $n = 0
    # inset by 4px so the rounded-corner antialiasing against the wallpaper cannot count
    for ($yy = $top + 4; $yy -lt $top + 316; $yy += 4) { for ($xx = $left + 4; $xx -lt $left + 316; $xx += 4) {
        $n++; if ($ia.GetPixel($xx, $yy).ToArgb() -ne $ib.GetPixel($xx, $yy).ToArgb()) { $d++ } } }
    $ia.Dispose(); $ib.Dispose(); return [math]::Round(100.0 * $d / [Math]::Max(1, $n), 2)
}

$focused = [W4]::ForceForeground($hwnd)
Log "foreground=$focused"

$a1 = Shot 'v_anim_1.png'; Start-Sleep -Milliseconds 1200; $a2 = Shot 'v_anim_2.png'
$dA = DiffApp $a1 $a2 $appX $appY
Log "BASELINE: $dA% -> $(if ($dA -gt 0) { 'moving' } else { 'STATIC (bad)' })"

[System.Windows.Forms.SendKeys]::SendWait(' ')
Log 'sent real SPACE #1'
Start-Sleep -Milliseconds 1000
$b1 = Shot 'v_paused_1.png'; Start-Sleep -Milliseconds 1200; $b2 = Shot 'v_paused_2.png'
$dB = DiffApp $b1 $b2 $appX $appY
Log "AFTER SPACE #1: $dB% -> $(if ($dB -eq 0) { 'PASS paused' } else { 'FAIL still moving' })"

[System.Windows.Forms.SendKeys]::SendWait(' ')
Log 'sent real SPACE #2'
Start-Sleep -Milliseconds 1000
$c1 = Shot 'v_resumed_1.png'; Start-Sleep -Milliseconds 1200; $c2 = Shot 'v_resumed_2.png'
$dC = DiffApp $c1 $c2 $appX $appY
Log "AFTER SPACE #2: $dC% -> $(if ($dC -gt 0) { 'PASS resumed' } else { 'FAIL still frozen' })"

if (Test-Path -LiteralPath $errLog) { Log '=== error.log PRESENT ==='; Get-Content -LiteralPath $errLog | ForEach-Object { Log "err $_" } }
else { Log 'error.log absent -> no exception thrown (PASS)' }

$verdict = "focused=$focused baseline=$dA paused=$dB resumed=$dC errlog=$(Test-Path $errLog)"
Log "VERDICT: $verdict"
foreach ($f in @($a1,$a2,$b1,$b2,$c1,$c2)) { Up $f (Split-Path -Leaf $f) }
UpText 'probe4.log' ($log -join "`r`n")
UpText 'probe4-summary.txt' $verdict
Log '=== probe4 done ==='
