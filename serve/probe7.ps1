# probe7.ps1 -- measure CPU + working set of GifMiniPlayer in each state.
#   att    = measure the already-running instance
#   fresh  = close it, launch the build from the served zip, then measure
# Reports CPU% (share of one core = 100%) and memory per state, plus a pause/switch regression.
param([string]$Mode = 'att')
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$w = Join-Path $env:USERPROFILE 'GifMiniTest'
$log = New-Object System.Collections.Generic.List[string]
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Beat($n, $t) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$n" -Method Post -Body $t -ContentType 'text/plain' -TimeoutSec 20 | Out-Null } catch { } }

Beat 'p7-00-started.txt' "mode=$Mode"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W7 {
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
    public static IntPtr FindApp(out uint pidOut) {
        IntPtr found = IntPtr.Zero; uint fp = 0;
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 100) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            found = h; fp = pid; return false;
        }, IntPtr.Zero);
        pidOut = fp; return found;
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

# ---- optional: close the old instance and launch the freshly served build ----
$appPid = 0
if ($Mode -eq 'fresh') {
    $oldHwnd = [W7]::FindApp([ref]$appPid)
    if ($oldHwnd -ne [IntPtr]::Zero) {
        Log "closing old instance pid=$appPid"
        [W7]::PostMessageW($oldHwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Start-Sleep -Seconds 2
    }
    $stillHwnd = [W7]::FindApp([ref]$appPid)
    if ($stillHwnd -ne [IntPtr]::Zero) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
    Beat 'p7-01-closed.txt' 'old instance closed'

    foreach ($n in @('gif-miniplayer.zip', 'gifA.gif', 'gifB.gif')) {
        Invoke-WebRequest -UseBasicParsing "$H/$n" -OutFile (Join-Path $w $n) -TimeoutSec 60
    }
    Expand-Archive -LiteralPath (Join-Path $w 'gif-miniplayer.zip') -DestinationPath $w -Force
    Get-ChildItem $w -File | Unblock-File -ErrorAction SilentlyContinue
    Beat 'p7-02-downloaded.txt' 'bundle fetched'

    $proc = Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList @(
        '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $w 'GifMiniPlayer.ps1'),
        (Join-Path $w 'gifA.gif'), (Join-Path $w 'gifB.gif'))
    Log "launched new build pid=$($proc.Id)"
    Beat 'p7-03-launched.txt' "pid=$($proc.Id)"
    Start-Sleep -Seconds 10
}

$hwnd = [W7]::FindApp([ref]$appPid)
Log "app hwnd=0x$($hwnd.ToString('X')) pid=$appPid"
if ($hwnd -eq [IntPtr]::Zero) { Beat 'probe7-summary.txt' 'NO APP WINDOW'; Beat 'probe7.log' ($log -join "`r`n"); return }
$rect = [W7]::Rect($hwnd)
$focused = [W7]::Focus($hwnd)
Log "rect $($rect.Left),$($rect.Top) $($rect.Right - $rect.Left)x$($rect.Bottom - $rect.Top) focused=$focused"

# ---- measurement helper -------------------------------------------------
function Measure-State($label, $seconds = 5) {
    $p = Get-Process -Id $appPid -ErrorAction Stop
    $p.Refresh()
    $t0 = $p.TotalProcessorTime
    $m0 = $p.WorkingSet64
    Start-Sleep -Seconds $seconds
    $p.Refresh()
    $t1 = $p.TotalProcessorTime
    $m1 = $p.WorkingSet64
    $cores = [Environment]::ProcessorCount
    $cpu = [math]::Round((($t1 - $t0).TotalSeconds / $seconds) * 100.0 / $cores, 2)
    $mem = [math]::Round($m1 / 1MB, 1)
    $deltaMb = [math]::Round(($m1 - $m0) / 1MB, 2)
    $line = "{0}: cpu={1}% (of one core) mem={2}MB delta={3}MB over {4}s" -f $label, $cpu, $mem, $deltaMb, $seconds
    Log $line
    return [pscustomobject]@{ Label = $label; Cpu = $cpu; Mem = $mem; Delta = $deltaMb; Line = $line }
}

function Shot($n) {
    $p = Join-Path $w $n
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose(); return $p
}
function DiffApp($a, $b) {
    $ia = [System.Drawing.Bitmap]::FromFile($a); $ib = [System.Drawing.Bitmap]::FromFile($b)
    $d = 0; $n = 0
    for ($y = $rect.Top + 4; $y -lt $rect.Bottom - 4; $y += 4) { for ($x = $rect.Left + 4; $x -lt $rect.Right - 4; $x += 4) {
        $n++; if ($ia.GetPixel($x, $y).ToArgb() -ne $ib.GetPixel($x, $y).ToArgb()) { $d++ } } }
    $ia.Dispose(); $ib.Dispose(); return [math]::Round(100.0 * $d / [Math]::Max(1, $n), 2)
}

# ---- states -------------------------------------------------------------
$mPlaying = Measure-State 'playing'
Beat 'p7-04-playing.txt' $mPlaying.Line

$a1 = Shot 'p7_anim_1.png'; Start-Sleep -Milliseconds 1200; $a2 = Shot 'p7_anim_2.png'
$anim = DiffApp $a1 $a2
Log "animation check: $anim% -> $(if ($anim -gt 0) { 'moving' } else { 'STATIC' })"

[System.Windows.Forms.SendKeys]::SendWait(' ')
Start-Sleep -Milliseconds 600
$b1 = Shot 'p7_paused_1.png'; Start-Sleep -Milliseconds 1200; $b2 = Shot 'p7_paused_2.png'
$pausedDiff = DiffApp $b1 $b2
Log "pause check: $pausedDiff% -> $(if ($pausedDiff -eq 0) { 'PASS paused' } else { 'FAIL moving' })"
$mPaused = Measure-State 'paused'
Beat 'p7-05-paused.txt' $mPaused.Line

[System.Windows.Forms.SendKeys]::SendWait('{RIGHT}')
Start-Sleep -Milliseconds 800
$r1 = Shot 'p7_switched.png'
$switched = DiffApp $b1 $r1
Log "switch check: $switched% vs paused shot -> $(if ($switched -gt 0) { 'PASS changed GIF' } else { 'FAIL unchanged' })"
[System.Windows.Forms.SendKeys]::SendWait(' ')   # resume
Start-Sleep -Milliseconds 600

[System.Windows.Forms.SendKeys]::SendWait('{ESC}')  # hide to tray
Start-Sleep -Seconds 1
$mHidden = Measure-State 'hidden-to-tray'
Beat 'p7-06-hidden.txt' $mHidden.Line

$verdict = "playing_cpu=$($mPlaying.Cpu)% paused_cpu=$($mPaused.Cpu)% hidden_cpu=$($mHidden.Cpu)% mem=$($mPlaying.Mem)MB anim=$anim% paused=$pausedDiff% switched=$switched%"
Log "VERDICT: $verdict"
foreach ($f in @($a1,$a2,$b1,$b2,$r1)) { try { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$(Split-Path -Leaf $f)" -Method Post -InFile $f -ContentType 'application/octet-stream' -TimeoutSec 25 | Out-Null } catch { } }
Beat 'probe7-summary.txt' $verdict
Beat 'probe7.log' ($log -join "`r`n")
