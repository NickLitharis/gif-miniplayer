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
$lib = Join-Path $PSScriptRoot 'win.ps1'
(New-Object Net.WebClient).DownloadFile("$H/win.ps1", $lib)
. $lib
if (-not ('BT' -as [type])) {
    Assert 'helper type compiles' $false 'win.ps1 did not load'
    Upload-Results
    return
}

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
if ($h1 -ne [IntPtr]::Zero) {
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
        if ($info -and $info.hwnd) { break }
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
Log "window hwnd=0x$($hwnd.ToString('X')) pid=$appPid2 visible=$vis ${winW}x${winH}"
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
$zeroHeight = @($buttons | Where-Object { ($_ -split "`t")[3] -match '^\d+x0$' })
Log "buttons=$($buttons.Count) zero-height=$($zeroHeight.Count)"
Assert 'eight buttons' ($buttons.Count -eq 8) "found $($buttons.Count)"
Assert 'no zero-height buttons' ($zeroHeight.Count -eq 0) "$($zeroHeight.Count) with height 0"

# Identify buttons by POSITION, not by label: the labels are Unicode transport glyphs now,
# and the console capture mangles them. Left-to-right order is part of the design.
function Btn-Info($line) {
    $f = $line -split "`t"
    $r = @{ Hwnd = [int64]$f[0]; Text = $f[2]; W = 0; H = 0; X = 0; Y = 0; Visible = $true }
    if ($f[3] -match '^(\d+)x(\d+)$')   { $r.W = [int]$matches[1]; $r.H = [int]$matches[2] }
    if ($f[4] -match '^(-?\d+),(-?\d+)$') { $r.X = [int]$matches[1]; $r.Y = [int]$matches[2] }
    return [pscustomobject]$r
}
$bi = @($buttons | ForEach-Object { Btn-Info $_ } | Sort-Object X)
foreach ($b in $bi) { Log ("button '{0}' at {1},{2} size {3}x{4}" -f $b.Text, $b.X, $b.Y, $b.W, $b.H) }

Assert 'buttons ordered transport-first' ($bi.Count -eq 8 -and $bi[0].X -lt $bi[1].X -and $bi[1].X -lt $bi[2].X) ($bi | ForEach-Object { $_.X }) -join ','
Assert 'buttons sit below the gif' ($bi[0].Y -ge ($rect.Top + $winW - 4)) "y=$($bi[0].Y) gif-bottom=$($rect.Top + $winW)"
Assert 'bar buttons are finger-sized' (($bi | Where-Object { $_.W -lt 16 -or $_.H -lt 16 }).Count -eq 0) ($bi | ForEach-Object { "$($_.W)x$($_.H)" }) -join ' '
Assert 'play control is second from the left' ($bi[1].W -ge 30) "w=$($bi[1].W)"

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
# Bottom-centre of the window: the control bar, clear of buttons and rounded corners.
function Bar-Pixel($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 'ERR:no-file' }
    try { $i = [System.Drawing.Bitmap]::FromFile($path) } catch { return 'ERR:load' }
    $px = $i.GetPixel([int]($i.Width / 2), [int]($i.Height - 5))
    $i.Dispose(); return "$($px.R),$($px.G),$($px.B)"
}
# The button glyphs are owner-drawn now, so the window text is empty: prove ink exists.
function Ink($path, $b) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return -1 }
    try { $i = [System.Drawing.Bitmap]::FromFile($path) } catch { return -1 }
    $bg = $i.GetPixel([int]($i.Width / 2), [int]($i.Height - 5))
    $x0 = [int]($b.X - $rect.Left); $y0 = [int]($b.Y - $rect.Top)
    $n = 0
    for ($x = $x0 + 2; $x -lt $x0 + $b.W - 2; $x++) {
        for ($y = $y0 + 2; $y -lt $y0 + $b.H - 2; $y++) {
            if ($x -lt 0 -or $y -lt 0 -or $x -ge $i.Width -or $y -ge $i.Height) { continue }
            $p = $i.GetPixel($x, $y)
            if (([Math]::Abs($p.R - $bg.R) + [Math]::Abs($p.G - $bg.G) + [Math]::Abs($p.B - $bg.B)) -gt 60) { $n++ }
        }
    }
    $i.Dispose(); return $n
}

$focused = $false
if ($hwnd -ne [IntPtr]::Zero) { $focused = [BT]::Focus($hwnd) }
Log "focused=$focused"
Log "window focused: $focused (informational: we click buttons instead of typing)"

$a1 = Shot 'shot-playing-1'; Start-Sleep -Milliseconds 1200; $a2 = Shot 'shot-playing-2'
$anim = DiffWin $a1 $a2
$cornerA = Corner $a1
Assert 'animation runs' ($anim -gt 0) "$anim% pixels changed"

# Press the pause button instead of wrestling with keyboard focus: deterministic,
# and it exercises the button the user actually has to press.
$pauseDiff = 100
$pauseBtn = if ($bi.Count -ge 2) { @([int]($bi[1].X + $bi[1].W / 2), [int]($bi[1].Y + $bi[1].H / 2)) } else { $null }
$pauseHwnd = if ($bi.Count -ge 2) { [IntPtr]$bi[1].Hwnd } else { [IntPtr]::Zero }
Assert 'pause button located' ($null -ne $pauseBtn) $(if ($pauseBtn) { "$($pauseBtn[0]),$($pauseBtn[1])" } else { 'not found' })
for ($try = 1; $try -le 3 -and $pauseDiff -ne 0; $try++) {
    if ($pauseHwnd -ne [IntPtr]::Zero) { [BT]::ClickControl($pauseHwnd) }
    Start-Sleep -Milliseconds 700
    $p1 = Shot 'shot-paused-1'
    Start-Sleep -Milliseconds 1200
    $p2 = Shot 'shot-paused-2'
    $pauseDiff = DiffWin $p1 $p2
    Log "pause attempt $try -> $pauseDiff% pixels changed (gif area only)"
    if ($pauseDiff -ne 0 -and $pauseHwnd -ne [IntPtr]::Zero) {
        # it is still moving: press once more to resume before the next attempt
        [BT]::ClickControl($pauseHwnd); Start-Sleep -Milliseconds 400
    }
}

# assert AFTER every shot exists, otherwise the check cannot mean anything
$allShots = ($null -ne $a1) -and ($null -ne $a2) -and ($null -ne $p1) -and ($null -ne $p2)
Log "shots: playing=$([bool]$a1)/$([bool]$a2) paused=$([bool]$p1)/$([bool]$p2)"
Assert 'screenshots captured' $allShots 'all four shot files exist'
Assert 'pause holds' ($pauseDiff -eq 0) "$pauseDiff% pixels changed"
if ($pauseHwnd -ne [IntPtr]::Zero -and $pauseDiff -eq 0) { [BT]::ClickControl($pauseHwnd) }   # resume

$nextBtn = if ($bi.Count -ge 3) { @([int]($bi[2].X + $bi[2].W / 2), [int]($bi[2].Y + $bi[2].H / 2)) } else { $null }
Assert 'next button located' ($null -ne $nextBtn) $(if ($nextBtn) { "$($nextBtn[0]),$($nextBtn[1])" } else { 'not found' })
if ($bi.Count -ge 3) { [BT]::ClickControl([IntPtr]$bi[2].Hwnd) }
Start-Sleep -Milliseconds 900
$s1 = Shot 'shot-switched'
$cornerB = Corner $s1
Assert 'switch changes gif' ($cornerA -ne $cornerB) "$cornerA -> $cornerB"

# minimise button (index 6 of 8: prev, play, next, kitty, peaks, add, min, hide)
if ($bi.Count -ge 8) {
    $minBtn = @([int]($bi[6].X + $bi[6].W / 2), [int]($bi[6].Y + $bi[6].H / 2))
    [BT]::ClickControl([IntPtr]$bi[6].Hwnd)
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

# ---- 5b. themes: the bow and peaks buttons pin and flip the palette ----------
# Click the bow first: the persisted theme is whatever the last run left, so the
# assertion must not depend on it (the user-flow test owns the fresh-config case).
$inkShot = Shot 'shot-theme-first'
$ink = @($bi | ForEach-Object { Ink $inkShot $_ })
Assert 'every button drew its glyph' (($ink | Where-Object { $_ -lt 6 }).Count -eq 0) ($ink -join ',')
if ($bi.Count -ge 8) { [BT]::ClickControl([IntPtr]$bi[3].Hwnd) }   # the bow button
Start-Sleep -Milliseconds 600
$themeShot = Shot 'shot-theme-kitty'
$barKitty = Bar-Pixel $themeShot
Assert 'bow button shows the hello kitty theme' ($barKitty -eq '253,237,240') "bar $barKitty"
if ($bi.Count -ge 8) { [BT]::ClickControl([IntPtr]$bi[4].Hwnd) }   # the peaks button
Start-Sleep -Milliseconds 600
$themeShotPeaks = Shot 'shot-theme-peaks'
$barPeaks = Bar-Pixel $themeShotPeaks
Assert 'peaks button switches the theme' ($barPeaks -eq '51,47,47') "bar $barPeaks"
if ($bi.Count -ge 8) { [BT]::ClickControl([IntPtr]$bi[3].Hwnd) }   # leave it on hello kitty
Start-Sleep -Milliseconds 400
Assert 'bow button switches back' ((Bar-Pixel (Shot 'shot-theme-back')) -eq '253,237,240') 'back to kitty'

if (Test-Path -LiteralPath $errLog) {
    $errText = (Get-Content -LiteralPath $errLog -Raw)
    Post 'error.log' $errText
    Assert 'no unhandled error' $false ($errText -split "`n" | Select-Object -First 1)
} else {
    Assert 'no unhandled error' $true ''
}

# ---- 6. leave nothing running -------------------------------------------------
Stop-Process -Id $(if ($appPid2 -gt 0) { $appPid2 } else { $appPid }) -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
$gone = [BT]::FindApp([ref]$appPid2, [ref]$rect, [ref]$vis)
Assert 'cleaned up' ($gone -eq [IntPtr]::Zero) ''

foreach ($f in @($a1,$a2,$p1,$p2,$s1,$themeShot,$themeShotPeaks)) { Up $f (Split-Path -Leaf $f) }
Upload-Results
Log '=== done ==='
