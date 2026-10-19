# probe6.ps1 -- minimal risk: attach to the ALREADY RUNNING playlist app and verify switching.
# No downloads, no process killing, no relaunch. Uploads a heartbeat after every step so a
# hang is visible instead of silent.
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$w = Join-Path $env:USERPROFILE 'GifMiniTest'
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Beat($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }
function Up($p, $n) { if (Test-Path -LiteralPath $p) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -InFile $p -ContentType 'application/octet-stream' -TimeoutSec 25 | Out-Null } catch { } } }

Beat 'p6-00-started.txt' 'script started'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class W6 {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    public static IntPtr FindApp() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 100) return true;      // skip the tiny helper windows
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }
    public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
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
}
'@
Beat 'p6-01-types.txt' 'types loaded'

$hwnd = [W6]::FindApp()
Log "app hwnd=0x$($hwnd.ToString('X'))"
Beat 'p6-02-found.txt' "hwnd=$($hwnd.ToString('X'))"
if ($hwnd -eq [IntPtr]::Zero) { Beat 'probe6-summary.txt' 'NO APP WINDOW'; Beat 'probe6.log' ($log -join "`r`n"); return }

$rect = [W6]::Rect($hwnd)
Log "rect $($rect.Left),$($rect.Top) $($rect.Right - $rect.Left)x$($rect.Bottom - $rect.Top)"
$focused = [W6]::Focus($hwnd)
Log "foreground=$focused"
Beat 'p6-03-focused.txt' "focused=$focused"

function Shot($n) {
    $p = Join-Path $w $n
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose(); return $p
}
function Kind($path) {
    $img = [System.Drawing.Bitmap]::FromFile($path)
    $px = $img.GetPixel([int]($rect.Right - 40), [int]($rect.Bottom - 40))
    $img.Dispose()
    $k = if ($px.G -gt $px.B + 15) { 'A' } elseif ($px.B -gt $px.G + 15) { 'B' } else { '?' }
    return "$k($($px.R),$($px.G),$($px.B))"
}
function Step($name, $keys, $expectDiff) {
    if ($keys) { [System.Windows.Forms.SendKeys]::SendWait($keys); Start-Sleep -Milliseconds 900 }
    $shot = Shot "$name.png"
    $kind = Kind $shot
    return [pscustomobject]@{ Name = $name; Kind = $kind; Key = ($kind -split '\(')[0]; Shot = $shot }
}

$s0 = Step 'p6_a_initial' $null $false
Log "initial: $($s0.Kind)"
Beat 'p6-04-initial.txt' $s0.Kind

$s1 = Step 'p6_b_next' '{RIGHT}' $true
Log "after RIGHT: $($s1.Kind)"
Beat 'p6-05-next.txt' $s1.Kind

$s2 = Step 'p6_c_next_wrap' '{RIGHT}' $true
Log "after RIGHT again: $($s2.Kind)"
Beat 'p6-06-wrap.txt' $s2.Kind

$s3 = Step 'p6_d_prev' '{LEFT}' $true
Log "after LEFT: $($s3.Kind)"
Beat 'p6-07-prev.txt' $s3.Kind

$result = @(
    "initial=$($s0.Key)"
    "after_right=$($s1.Key) changed=$($s1.Key -ne $s0.Key)"
    "after_right_wrap=$($s2.Key) back_to_initial=$($s2.Key -eq $s0.Key)"
    "after_left=$($s3.Key) back_to_next=$($s3.Key -eq $s1.Key)"
)
foreach ($r in $result) { Log $r }

$ok = ($s1.Key -ne $s0.Key) -and ($s2.Key -eq $s0.Key) -and ($s3.Key -eq $s1.Key)
$verdict = $(if ($ok) { 'ALL PASS' } else { 'FAIL' }) + " :: " + ($result -join ' ')
Log "VERDICT: $verdict"

foreach ($s in @($s0, $s1, $s2, $s3)) { Up $s.Shot (Split-Path -Leaf $s.Shot) }
Beat 'probe6-summary.txt' $verdict
Beat 'probe6.log' ($log -join "`r`n")
