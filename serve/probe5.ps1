# probe5.ps1 -- verify the playlist: launch with two GIFs, switch with arrow keys, and prove
# the DISPLAYED content actually changed (background colour A=green vs B=blue), incl. wrapping.
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
using System.Collections.Generic;
public class W5 {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    public static List<IntPtr> FindApp(out List<string> meta) {
        var hits = new List<IntPtr>(); var m = new List<string>();
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            RECT r; GetWindowRect(h, out r);
            uint pid; GetWindowThreadProcessId(h, out pid);
            hits.Add(h);
            m.Add(string.Format("hwnd=0x{0:X} pid={1} {2}x{3} at {4},{5}", (long)h, pid, r.Right-r.Left, r.Bottom-r.Top, r.Left, r.Top));
            return true;
        }, IntPtr.Zero);
        meta = m; return hits;
    }
    public static bool Focus(IntPtr target) {
        IntPtr fg = GetForegroundWindow();
        uint fgT = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero);
        uint myT = GetCurrentThreadId();
        bool att = false;
        if (fgT != 0 && fgT != myT) att = AttachThreadInput(myT, fgT, true);
        BringWindowToTop(target); SetForegroundWindow(target); SetFocus(target);
        if (att) AttachThreadInput(myT, fgT, false);
        return GetForegroundWindow() == target;
    }
    public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
}
'@

Log '=== probe5: playlist switching ==='

# 0. kill any previous instance (the window is gone once its process dies)
$meta = $null
$old = [W5]::FindApp([ref]$meta)
foreach ($m in $meta) { Log "existing: $m" }
foreach ($h in $old) {
    $m2 = $null; [W5]::FindApp([ref]$m2) | Out-Null
    [W5]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE
}
Start-Sleep -Seconds 3
$left = $null
$still = [W5]::FindApp([ref]$stillMeta)
if ($still.Count -gt 0) {
    Log "graceful close left $($still.Count) window(s) -> forcing"
    foreach ($m in $stillMeta) { if ($m -match 'pid=(\d+)') { Stop-Process -Id ([int]$matches[1]) -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Seconds 2
}
$left = $null; $c = [W5]::FindApp([ref]$left)
Log "windows after cleanup: $($c.Count)"

# 1. fetch both GIFs
foreach ($n in @('gifA.gif', 'gifB.gif', 'gif-miniplayer.zip')) {
    Invoke-WebRequest -UseBasicParsing "$H/$n" -OutFile (Join-Path $w $n) -TimeoutSec 60
}
Expand-Archive -LiteralPath (Join-Path $w 'gif-miniplayer.zip') -DestinationPath $w -Force
Get-ChildItem $w -File | Unblock-File -ErrorAction SilentlyContinue
Log "bundle + 2 gifs ready"

# 2. launch with BOTH gifs on the command line -> playlist of 2, starting at A
$a = Join-Path $w 'gifA.gif'
$b = Join-Path $w 'gifB.gif'
$proc = Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList @(
    '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $w 'GifMiniPlayer.ps1'),$a,$b)
Log "launched pid=$($proc.Id) with 2 gifs"
Start-Sleep -Seconds 10

$meta = $null
$wins = [W5]::FindApp([ref]$meta)
foreach ($m in $meta) { Log "app window: $m" }
if ($wins.Count -eq 0) { Log 'NO APP WINDOW'; UpText 'probe5.log' ($log -join "`r`n"); return }
$hwnd = $wins[0]
$rect = [W5]::Rect($hwnd)
Log "rect: $($rect.Left),$($rect.Top) $($rect.Right - $rect.Left)x$($rect.Bottom - $rect.Top)"
$focused = [W5]::Focus($hwnd)
Log "foreground=$focused"

function Shot($n) {
    $p = Join-Path $w $n
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose(); return $p
}

# classify which GIF is on screen from the background colour in the lower-right corner
function Classify($path, $r) {
    $img = [System.Drawing.Bitmap]::FromFile($path)
    $px = $img.GetPixel([int]($r.Right - 40), [int]($r.Bottom - 40))
    $img.Dispose()
    $kind = if ($px.G -gt $px.B + 15) { 'A' } elseif ($px.B -gt $px.G + 15) { 'B' } else { '?' }
    return [pscustomobject]@{ Kind = $kind; R = $px.R; G = $px.G; B = $px.B }
}

$results = New-Object System.Collections.Generic.List[string]
function Check($step, $expect, $shotName) {
    $shot = Shot $shotName
    $cls = Classify $shot $rect
    $ok = ($cls.Kind -eq $expect)
    $line = "$step -> shown=$($cls.Kind) expected=$expect rgb=$($cls.R),$($cls.G),$($cls.B) $(if ($ok) {'PASS'} else {'FAIL'})"
    Log $line
    $script:results.Add($line)
    return $shot
}

$shots = @()
$shots += Check 'initial'  'A' 'sw1_initial.png'
[System.Windows.Forms.SendKeys]::SendWait('{RIGHT}')
Start-Sleep -Milliseconds 800
$shots += Check 'right x1' 'B' 'sw2_right.png'
[System.Windows.Forms.SendKeys]::SendWait('{RIGHT}')
Start-Sleep -Milliseconds 800
$shots += Check 'right x2 (wrap)' 'A' 'sw3_right_wrap.png'
[System.Windows.Forms.SendKeys]::SendWait('{LEFT}')
Start-Sleep -Milliseconds 800
$shots += Check 'left x1 (wrap back)' 'B' 'sw4_left_wrap.png'

# animation must still run after switching
$an1 = Shot 'sw5_anim_1.png'; Start-Sleep -Milliseconds 1200; $an2 = Shot 'sw6_anim_2.png'
$i1 = [System.Drawing.Bitmap]::FromFile($an1); $i2 = [System.Drawing.Bitmap]::FromFile($an2)
$d = 0; $n = 0
for ($y = $rect.Top + 4; $y -lt $rect.Bottom - 4; $y += 4) { for ($x = $rect.Left + 4; $x -lt $rect.Right - 4; $x += 4) {
    $n++; if ($i1.GetPixel($x, $y).ToArgb() -ne $i2.GetPixel($x, $y).ToArgb()) { $d++ } } }
$i1.Dispose(); $i2.Dispose()
$pct = [math]::Round(100.0 * $d / [Math]::Max(1, $n), 2)
Log "animation after switching: $pct% -> $(if ($pct -gt 0) { 'PASS still animating' } else { 'FAIL frozen' })"
$script:results.Add("animation=$pct%")

$pass = ($script:results | Where-Object { $_ -match 'FAIL' }).Count -eq 0
$verdict = if ($pass) { 'ALL PASS' } else { 'FAILURES PRESENT' }
Log "VERDICT: $verdict"
foreach ($s in $shots) { Up $s (Split-Path -Leaf $s) }
Up $an1 'sw5_anim_1.png'; Up $an2 'sw6_anim_2.png'

$cfg = Join-Path $env:APPDATA 'GifMiniPlayer\config.json'
if (Test-Path -LiteralPath $cfg) { Log ('config: ' + ((Get-Content -LiteralPath $cfg -Raw) -replace '\s+', ' ').Trim()) }
UpText 'probe5.log' ($log -join "`r`n")
UpText 'probe5-summary.txt' $verdict
Log '=== probe5 done ==='
