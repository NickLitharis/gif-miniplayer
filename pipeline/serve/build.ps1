# build.ps1 -- the ONE smoke test. Deploy a build, prove it runs, upload the evidence.
#   -Build <id>   build identifier (also used to name the uploaded results)
# Every step uploads a result; a hang is visible instead of silent.
param([string]$Build = 'manual')
$ErrorActionPreference = 'Continue'
$Script:BaseUrl = 'http://192.168.103.1:8001'

# The agent could see the same queued command twice; only the first execution may run.
$lock = Join-Path (Join-Path $env:LOCALAPPDATA "GifMiniPlayer\builds\$Build") 'running.lock'
if (Test-Path -LiteralPath $lock) { Write-Host "already ran for build $Build - exiting"; return }
New-Item -ItemType Directory -Force -Path (Split-Path $lock) | Out-Null
Set-Content -LiteralPath $lock -Value (Get-Date -Format o)   # NOT $H: $h is used for window height
$H   = 'http://192.168.103.1:8001'
$dir = Join-Path $env:LOCALAPPDATA "GifMiniPlayer\builds\$Build"
$log = New-Object System.Collections.Generic.List[string]
$results = [ordered]@{}
$script:uploadErrors = @()
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; $script:log.Add($l); Write-Host $l }
function Post($n, $t) {
    try {
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('Content-Type', 'text/plain; charset=utf-8')
        $wc.UploadString("$($Script:BaseUrl)/upload?name=$Build-$n", 'POST', $t) | Out-Null
    } catch {
        $script:uploadErrors += "$n : $($_.Exception.Message)"
        Log "UPLOAD FAILED $n : $($_.Exception.Message)"
    }
}
function Up($p, $n) {
    if (-not (Test-Path -LiteralPath $p)) { Log "UPLOAD SKIP $n (no file)"; return }
    try {
        # UploadFile wraps the bytes in multipart/form-data; UploadData sends the file raw
        $bytes = [System.IO.File]::ReadAllBytes($p)
        (New-Object Net.WebClient).UploadData("$($Script:BaseUrl)/upload?name=$Build-$n", 'POST', $bytes) | Out-Null
    } catch {
        $script:uploadErrors += "$n : $($_.Exception.Message)"
        Log "UPLOAD FAILED $n : $($_.Exception.Message)"
    }
}
function Assert($name, $ok, $detail = '') {
    $script:results[$name] = [ordered]@{ ok = [bool]$ok; detail = "$detail" }
    Log ("{0}  {1} {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
}
function Upload-Results {
    $payload = [ordered]@{
        build      = $Build
        when       = (Get-Date -Format s)
        sha256     = $script:sha
        pass       = (@($script:results.Values | Where-Object { -not $_.ok }).Count -eq 0)
        assertions = $script:results
        uploadErrors = $script:uploadErrors
        log        = $script:log
    }
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=$Build-result.json" -Method Post `
                -Body $json -ContentType 'application/json' -TimeoutSec 25 | Out-Null
            break
        } catch { Start-Sleep -Milliseconds 500 }
    }
    [Console]::Out.WriteLine("RESULT_JSON:$json")   # raw: Write-Host would wrap it at console width
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class BT {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
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
    public static string WantTitle = "GIF Mini Player";
    public static IntPtr FindApp(out uint pidOut, out RECT rect, out bool vis) {
        IntPtr found = IntPtr.Zero; uint fp = 0; RECT fr = new RECT(); bool fv = false;
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (!t.ToString().StartsWith(WantTitle)) return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 100) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            found = h; fp = pid; fr = r; fv = IsWindowVisible(h); return false;
        }, IntPtr.Zero);
        pidOut = fp; rect = fr; vis = fv;
        return found;
    }
    public static string[] Children(IntPtr parent) {
        var list = new List<string>();
        EnumChildWindows(parent, (h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            RECT r; GetWindowRect(h, out r);
            list.Add(string.Format("{0}\t{1}\t{2}x{3}\t{4},{5}", c, t, r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top));
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);

    // Capture THIS window's own content -- independent of z-order, other windows and layering.
    public static bool Capture(IntPtr hwnd, string path, int width, int height) {
        using (var bmp = new System.Drawing.Bitmap(width, height))
        using (var g = System.Drawing.Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            bool ok = PrintWindow(hwnd, hdc, 2);   // PW_RENDERFULLCONTENT
            g.ReleaseHdc(hdc);
            if (!ok) return false;
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            return true;
        }
    }
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(80);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);   // LEFTDOWN
        System.Threading.Thread.Sleep(80);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);   // LEFTUP
        System.Threading.Thread.Sleep(120);
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
}
'@

# ---- 1. deploy -----------------------------------------------------------------
Log "build=$Build dir=$dir"
$zipPath = Join-Path $dir 'b.zip'
$deployed = $false
for ($attempt = 1; $attempt -le 4 -and -not $deployed; $attempt++) {
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
        # two different APIs: Defender scanning the fresh file can lock it for a moment
        try {
            Invoke-WebRequest -UseBasicParsing "$($Script:BaseUrl)/gif-miniplayer.zip" -OutFile $zipPath -TimeoutSec 60
        } catch {
            Log "IWR failed (attempt $attempt): $($_.Exception.Message) -> WebClient fallback"
            Start-Sleep -Milliseconds 700
            (New-Object Net.WebClient).DownloadFile("$($Script:BaseUrl)/gif-miniplayer.zip", $zipPath)
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $dir -Force -ErrorAction Stop
        Get-ChildItem $dir -File | Unblock-File -ErrorAction SilentlyContinue
        $deployed = $true
    } catch {
        Log "deploy attempt $attempt failed: $($_.Exception.Message)"
        Start-Sleep -Milliseconds 900
    }
}
if (-not $deployed) {
    Assert 'deploy' $false 'all attempts failed (file lock?)'
    Upload-Results; return
}
$app = Join-Path $dir 'GifMiniPlayer.ps1'
$script:sha = (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash.ToLower()
Log "deployed sha256=$($script:sha)"
Assert 'deploy' (Test-Path $app) $script:sha

# ---- 2. kill any running instance ----------------------------------------------
$killed = @()
try {
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
        if ($p.ProcessId -ne $PID -and $p.CommandLine -and $p.CommandLine -match 'GifMiniPlayer\.ps1') {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $killed += $p.ProcessId
        }
    }
} catch { }

# CommandLine can come back empty for a process the query cannot inspect, so ALSO kill
# whatever process currently owns the player window. Belt and braces: verify it is gone.
$p0 = 0; $r0 = New-Object BT+RECT; $v0 = $false
$h0 = [BT]::FindApp([ref]$p0, [ref]$r0, [ref]$v0)
if ($h0 -ne [IntPtr]::Zero -and $p0 -gt 0) {
    # Stop-Process can no-op silently here; taskkill reports why
    $tk = & taskkill.exe /F /PID $p0 2>&1 | Out-String
    Log "taskkill $p0 -> $($tk.Trim())"
    if (-not (Get-Process -Id $p0 -ErrorAction SilentlyContinue)) { $killed += $p0 }
}
Start-Sleep -Seconds 3
$p1 = 0; $r1 = New-Object BT+RECT; $v1 = $false
$h1 = [BT]::FindApp([ref]$p1, [ref]$r1, [ref]$v1)
Log "killed: $($killed -join ',')  stale window after kill: $(if ($h1 -eq [IntPtr]::Zero) { 'none' } else { "pid=$p1" })"
# a window can be mid-destruction (pid 0); give it a moment before declaring a stale instance
if ($h1 -ne [IntPtr]::Zero -and $p1 -le 0) {
    Start-Sleep -Seconds 2
    $h1 = [BT]::FindApp([ref]$p1, [ref]$r1, [ref]$v1)
    Log "re-checked stale window: hwnd=0x$($h1.ToString('X')) pid=$p1"
}
if ($h1 -ne [IntPtr]::Zero -and $p1 -le 0) {
    Log 'ignoring a window with no resolvable pid (mid-destroy)'
    $h1 = [IntPtr]::Zero
}
if ($hwnd -eq [IntPtr]::Zero -and $h1 -ne [IntPtr]::Zero) {
    Assert 'no stale instance before launch' $false ("pid=$p1 still owns a player window (it may be hidden in the tray) and it was started elevated, so this session can neither kill it nor post WM_CLOSE to it. Right-click its TRAY icon -> Exit, or reboot the VM; the agent comes back by itself.")
    Upload-Results
    Write-Host 'ABORTED: unevictable stale player window'
    return
}
Assert 'no stale instance before launch' $true ''

$errLog = Join-Path $env:APPDATA 'GifMiniPlayer\error.log'
if (Test-Path -LiteralPath $errLog) { Remove-Item -LiteralPath $errLog -Force }

# ---- 3. launch with both demo gifs --------------------------------------------
$gifs = @(Get-ChildItem $dir -Filter 'demo-*.gif' | Sort-Object Name | ForEach-Object FullName)
$script:Instance = "t$Build"
$env:GMP_INSTANCE = $script:Instance
$env:GMP_INSTANCE = $script:Instance
$proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList (@(
    '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$app) + $gifs)
$appPid = $proc.Id
Log "launched pid=$appPid gifs=$($gifs.Count)"
Start-Sleep -Seconds 10
Log "launcher pid=$appPid exited=$($proc.HasExited) (the terminal host owns the window)"

# The app publishes its own pid+hwnd on startup: read that instead of enumerating windows.
[BT]::WantTitle = "GIF Mini Player [$script:Instance]"
$instanceFile = Join-Path $env:APPDATA "GifMiniPlayer\instance-$($script:Instance).json"
$info = $null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $instanceFile) {
        try { $info = Get-Content -LiteralPath $instanceFile -Raw | ConvertFrom-Json } catch { }
        if ($false -and $info -and $info.hwnd) { break }
    }
}
$appPid2 = 0; $rect = New-Object BT+RECT; $vis = $false
if ($info -and $info.hwnd) {
    $appPid2 = [int]$info.pid
    $hwnd = [IntPtr][int64]$info.hwnd
    [void][BT]::GetWindowRect($hwnd, [ref]$rect)
    $vis = [BT]::IsWindowVisible($hwnd)
    Log "instance file: pid=$appPid2 hwnd=0x$($hwnd.ToString('X')) title='$($info.title)'"
} else {
    Log "using window enumeration"
    $hwnd = [BT]::FindApp([ref]$appPid2, [ref]$rect, [ref]$vis)
}
$winW = $rect.Right - $rect.Left; $winH = $rect.Bottom - $rect.Top
Log "window hwnd=0x$($hwnd.ToString('X')) pid=$appPid2 visible=$vis ${w}x${h}"
Assert 'window exists' (($hwnd -is [IntPtr]) -and ($hwnd -ne [IntPtr]::Zero)) "hwnd=0x$($hwnd.ToString('X')) owner pid=$appPid2"
Assert 'owner process alive' ($null -ne (Get-Process -Id $appPid2 -ErrorAction SilentlyContinue)) "pid=$appPid2"
Assert 'window visible' $vis ''
Assert 'window has room for the bar' ($winH -ge ($winW + 20)) "${winW}x${winH} (expected height >= width + 28)"

# ---- 4. button bar ------------------------------------------------------------
$children = @()
if ($hwnd -ne [IntPtr]::Zero) { $children = [BT]::Children($hwnd) }
$buttons = $children | Where-Object { $_ -match 'BUTTON' }
$uiText = ($children -join "`r`n")
Post 'ui.txt' $uiText
$zeroHeight = @($buttons | Where-Object { ($_ -split "`t")[2] -match '^\d+x0$' })
Log "buttons=$($buttons.Count) zero-height=$($zeroHeight.Count)"
Assert 'six buttons' ($buttons.Count -eq 6) "found $($buttons.Count)"
Assert 'no zero-height buttons' ($zeroHeight.Count -eq 0) "$($zeroHeight.Count) with height 0"

# Identify buttons by POSITION, not by label: the labels are Unicode transport glyphs now,
# and the console capture mangles them. Left-to-right order is part of the design.
function Btn-Info($line) {
    $f = $line -split "`t"
    $r = @{ Text = $f[1]; W = 0; H = 0; X = 0; Y = 0; Visible = $true }
    if ($f[2] -match '^(\d+)x(\d+)$')   { $r.W = [int]$matches[1]; $r.H = [int]$matches[2] }
    if ($f[3] -match '^(-?\d+),(-?\d+)$') { $r.X = [int]$matches[1]; $r.Y = [int]$matches[2] }
    return [pscustomobject]$r
}
$bi = @($buttons | ForEach-Object { Btn-Info $_ } | Sort-Object X)
foreach ($b in $bi) { Log ("button '{0}' at {1},{2} size {3}x{4}" -f $b.Text, $b.X, $b.Y, $b.W, $b.H) }

Assert 'buttons ordered transport-first' ($bi.Count -eq 6 -and $bi[0].X -lt $bi[1].X -and $bi[1].X -lt $bi[2].X) ($bi | ForEach-Object { $_.X }) -join ','
Assert 'buttons sit below the gif' ($bi[0].Y -ge ($rect.Top + $winW - 4)) "y=$($bi[0].Y) gif-bottom=$($rect.Top + $winW)"
Assert 'bar buttons are square-ish' (($bi | Where-Object { $_.W -lt 18 -or $_.H -lt 18 }).Count -eq 0) ($bi | ForEach-Object { "$($_.W)x$($_.H)" }) -join ' '
Assert 'play glyph present' ([bool]$bi[1].Text) $bi[1].Text

# ---- 5. behaviour -------------------------------------------------------------
function Shot($name) {
    $p = Join-Path $dir "$name.png"
    try {
        if ($hwnd -eq [IntPtr]::Zero) { Log "shot '$name': no window"; return $null }
        if (-not [BT]::Capture($hwnd, $p, [int]$winW, [int]$winH)) {
            Log "shot '$name': PrintWindow failed"
            return $null
        }
        return $p
    } catch {
        Log "screenshot '$name' failed: $($_.Exception.Message)"
        return $null
    }
}
function DiffWin($a, $b) {
    if (-not $a -or -not $b) { return -1 }     # no screenshots => cannot compare
    if (-not (Test-Path -LiteralPath $a) -or -not (Test-Path -LiteralPath $b)) { return -1 }
    try { $ia = [System.Drawing.Bitmap]::FromFile($a); $ib = [System.Drawing.Bitmap]::FromFile($b) }
    catch { Log "DiffWin could not load screenshots: $($_.Exception.Message)"; return -1 }
    $d = 0; $n = 0
    $gifBottom = $winH - 47          # 3px progress line + 44px control bar
    for ($y = 6; $y -lt ($gifBottom - 4); $y += 4) {
        for ($x = 6; $x -lt ($winW - 6); $x += 4) {
            $n++; if ($ia.GetPixel($x,$y).ToArgb() -ne $ib.GetPixel($x,$y).ToArgb()) { $d++ }
        }
    }
    $ia.Dispose(); $ib.Dispose()
    if ($n -eq 0) { return 0 }
    return [math]::Round(100.0 * $d / $n, 2)
}
function Corner($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return "ERR:no-file" }
    try { $i = [System.Drawing.Bitmap]::FromFile($path) } catch { return "ERR:load" }
    $px = $i.GetPixel([int]($winW - 40), [int]($winH - 60))
    $i.Dispose(); return "$($px.R),$($px.G),$($px.B)"
}

$focused = $false
if ($hwnd -ne [IntPtr]::Zero) { $focused = [BT]::Focus($hwnd) }
Log "focused=$focused"
Log "window focused: $focused (informational: we click buttons instead of typing)"

$a1 = Shot 'shot-playing-1'; Start-Sleep -Milliseconds 1200; $a2 = Shot 'shot-playing-2'
$anim = DiffWin $a1 $a2
$cornerA = Corner $a1
Assert 'animation runs' ($anim -gt 0) "$anim% pixels changed"

# Click the pause button instead of wrestling with keyboard focus: deterministic,
# and it exercises the button the user actually has to press.
$pauseDiff = 100
$pauseBtn = if ($bi.Count -ge 2) { @([int]($bi[1].X + $bi[1].W / 2), [int]($bi[1].Y + $bi[1].H / 2)) } else { $null }
Assert 'pause button located' ($null -ne $pauseBtn) $(if ($pauseBtn) { "$($pauseBtn[0]),$($pauseBtn[1])" } else { 'not found' })
for ($try = 1; $try -le 3 -and $pauseDiff -ne 0; $try++) {
    if ($pauseBtn) { [BT]::Click($pauseBtn[0], $pauseBtn[1]) }
    Start-Sleep -Milliseconds 700
    $p1 = Shot 'shot-paused-1'
    Start-Sleep -Milliseconds 1200
    $p2 = Shot 'shot-paused-2'
    $pauseDiff = DiffWin $p1 $p2
    Log "pause attempt $try -> $pauseDiff% pixels changed (gif area only)"
    if ($pauseDiff -ne 0 -and $pauseBtn) {
        # move the cursor off the button first so hover highlight cannot pollute the next shot
        [BT]::Click($pauseBtn[0], $pauseBtn[1]); Start-Sleep -Milliseconds 400
    }
}

# assert AFTER every shot exists, otherwise the check cannot mean anything
$allShots = ($null -ne $a1) -and ($null -ne $a2) -and ($null -ne $p1) -and ($null -ne $p2)
Log "shots: playing=$([bool]$a1)/$([bool]$a2) paused=$([bool]$p1)/$([bool]$p2)"
Assert 'screenshots captured' $allShots 'all four shot files exist'
Assert 'pause holds' ($pauseDiff -eq 0) "$pauseDiff% pixels changed"
[System.Windows.Forms.SendKeys]::SendWait(' ')

$nextBtn = if ($bi.Count -ge 3) { @([int]($bi[2].X + $bi[2].W / 2), [int]($bi[2].Y + $bi[2].H / 2)) } else { $null }
Assert 'next button located' ($null -ne $nextBtn) $(if ($nextBtn) { "$($nextBtn[0]),$($nextBtn[1])" } else { 'not found' })
if ($nextBtn) { [BT]::Click($nextBtn[0], $nextBtn[1]) }
Start-Sleep -Milliseconds 900
$s1 = Shot 'shot-switched'
$cornerB = Corner $s1
Assert 'switch changes gif' ($cornerA -ne $cornerB) "$cornerA -> $cornerB"

# minimise button (index 4 of 6: prev, play, next, add, min, hide)
if ($bi.Count -ge 6) {
    $minBtn = @([int]($bi[4].X + $bi[4].W / 2), [int]($bi[4].Y + $bi[4].H / 2))
    [BT]::Click($minBtn[0], $minBtn[1])
    Start-Sleep -Milliseconds 900
    $iconic = [BT]::IsIconic($hwnd)
    $stillVisible = [BT]::IsWindowVisible($hwnd)
    Log "after minimise click: iconic=$iconic visible=$stillVisible foreground=$([BT]::GetForegroundWindow() -eq $hwnd)"
    Assert 'minimize button minimizes' $iconic "clicked $($minBtn[0]),$($minBtn[1]) iconic=$iconic visible=$stillVisible"
    [void][BT]::ShowWindow($hwnd, 9)      # SW_RESTORE
    Start-Sleep -Milliseconds 900
    Assert 'restores from taskbar' ((-not [BT]::IsIconic($hwnd)) -and [BT]::IsWindowVisible($hwnd)) "iconic=$([BT]::IsIconic($hwnd)) visible=$([BT]::IsWindowVisible($hwnd))"
} else {
    Assert 'minimize button minimizes' $false "only $($bi.Count) buttons found"
}

if (Test-Path -LiteralPath $errLog) {
    $errText = (Get-Content -LiteralPath $errLog -Raw)
    Post 'error.log' $errText
    Assert 'no unhandled error' $false ($errText -split "`n" | Select-Object -First 1)
} else {
    Assert 'no unhandled error' $true ''
}

# ---- 6. leave nothing running -------------------------------------------------
Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
$gone = [BT]::FindApp([ref]$appPid2, [ref]$rect, [ref]$vis)
Assert 'cleaned up' ($gone -eq [IntPtr]::Zero) ''

foreach ($f in @($a1,$a2,$p1,$p2,$s1)) { Up $f (Split-Path -Leaf $f) }
Upload-Results
Log '=== done ==='
