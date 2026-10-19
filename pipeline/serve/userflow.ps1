# userflow.ps1 -- the test the smoke test does not do: drive the app the way a person does.
#   double-click the launcher -> first-run picker -> their own GIF -> add another with "+"
#   -> close -> reopen -> wheel-resize -> launch a second copy (single instance).
# Reports PASS/FAIL lines as userflow-summary.txt; screenshots as uf-*.png.
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
$dir = Join-Path $env:LOCALAPPDATA 'GifMiniPlayer\userflow'
$cfgDir = Join-Path $env:APPDATA 'GifMiniPlayer'
$cfgPath = Join-Path $cfgDir 'config.json'
$cfgBak = Join-Path $env:TEMP 'gmp-cfg-backup.json'
$results = [ordered]@{}
$shots = @()

function Assert($name, $ok, $detail = '') {
    $results[$name] = [ordered]@{ ok = [bool]$ok; detail = "$detail" }
    Write-Host ("{0}  {1} {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
}
function Post($name, $text) {
    try {
        (New-Object Net.WebClient).UploadString("$H/upload?name=$name", 'POST', $text) | Out-Null
    } catch { Write-Host "upload $name failed: $($_.Exception.Message)" }
}
function Post-Bytes($name, $bytes) {
    try {
        (New-Object Net.WebClient).UploadData("$H/upload?name=$name", 'POST', $bytes) | Out-Null
    } catch { Write-Host "upload $name failed: $($_.Exception.Message)" }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$lib = Join-Path $PSScriptRoot 'win.ps1'
(New-Object Net.WebClient).DownloadFile("$H/win.ps1", $lib)
. $lib
if (-not ('BT' -as [type])) {
    $msg = 'FATAL: the BT helper type did not compile (win.ps1), so nothing below can be trusted'
    Write-Host $msg
    Post 'userflow-summary.txt' $msg
    return
}

function Wait-Window($prefix, $seconds) {
    for ($i = 0; $i -lt ($seconds * 4); $i++) {
        $h = [BT]::Find($prefix)
        if ($h -ne $null -and $h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 250
    }
    return [IntPtr]::Zero
}
function IsWin($h) { return ($null -ne $h) -and ($h -is [IntPtr]) -and ($h -ne [IntPtr]::Zero) }
function Hex($h) { if (IsWin $h) { return ('0x' + $h.ToString('X')) } else { return 'none' } }
function Rect($h) { $r = New-Object BT+RECT; [void][BT]::GetWindowRect($h, [ref]$r); return $r }
function Shot($h, $name) {
    if (-not (IsWin $h)) { return $null }
    $r = Rect $h; $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
    if ($w -lt 2 -or $hh -lt 2) { return $null }
    $path = Join-Path $dir "$name.png"
    if ([BT]::Capture($h, $path, $w, $hh)) { $script:shots += $path; return $path }
    return $null
}
function Shot-Screen($h, $name) {
    if (-not (IsWin $h)) { return $null }
    $path = Join-Path $dir "$name.png"
    if ([BT]::Grab($h, $path)) { $script:shots += $path; return $path }
    return $null
}
function Center-Pixel($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    try { $b = [System.Drawing.Bitmap]::FromFile($path) } catch { return $null }
    $p = $b.GetPixel([int]($b.Width / 2), [int]($b.Height / 2))
    $b.Dispose()
    return "$($p.R),$($p.G),$($p.B)"
}
# Bottom-centre of the window: the control bar, clear of buttons and rounded corners.
function Bar-Pixel($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 'ERR:no-file' }
    try { $b = [System.Drawing.Bitmap]::FromFile($path) } catch { return 'ERR:load' }
    $p = $b.GetPixel([int]($b.Width / 2), [int]($b.Height - 5))
    $b.Dispose()
    return "$($p.R),$($p.G),$($p.B)"
}
function Btn($children) {
    return @($children | Where-Object { $_ -match 'BUTTON' } | ForEach-Object {
        $f = $_ -split "`t"; $x = 0; $y = 0; $w = 0; $h = 0
        if ($f[3] -match '^(\d+)x(\d+)$') { $w = [int]$matches[1]; $h = [int]$matches[2] }
        if ($f[4] -match '^(-?\d+),(-?\d+)$') { $x = [int]$matches[1]; $y = [int]$matches[2] }
        [pscustomobject]@{ Hwnd = [int64]$f[0]; Text = $f[2]; X = $x; Y = $y; W = $w; H = $h }
    } | Sort-Object X)
}
function Ui-Text($h) {
    if (-not (IsWin $h)) { return '' }   # EnumChildWindows(0) would list the whole desktop
    return ([BT]::Children($h) -join "`r`n")
}
function Pick($dialog, $file) {
    if (-not (IsWin $dialog)) { return $false }
    return [BT]::PickFile($dialog, $file)
}
function Get-AppPid {
    $f = Join-Path $cfgDir 'instance-default.json'
    for ($i = 0; $i -lt 40; $i++) {
        if (Test-Path -LiteralPath $f) {
            try { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; if ($j.pid) { return [int]$j.pid } } catch { }
        }
        Start-Sleep -Milliseconds 250
    }
    return 0
}
function Start-App {
    return Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $app)
}
function Start-AppViaLauncher {
    $bat = Join-Path $dir 'Run-GifMiniPlayer.bat'
    return Start-Process -FilePath 'cmd.exe' -PassThru -WindowStyle Hidden -ArgumentList @('/c', "`"$bat`"")
}

# ---- setup --------------------------------------------------------------------
Remove-Item -LiteralPath $cfgBak -Force -ErrorAction SilentlyContinue   # never restore a stale backup
if (Test-Path -LiteralPath $cfgPath) { Copy-Item $cfgPath $cfgBak -Force }
Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue

Get-Process powershell -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
        if ($cl -and $cl -match 'GifMiniPlayer\.ps1') { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    } catch { }
}
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path (Join-Path $dir 'My Gifs') | Out-Null

$zip = Join-Path $dir 'bundle.zip'
(New-Object Net.WebClient).DownloadFile("$H/gif-miniplayer.zip", $zip)
Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
Get-ChildItem $dir -File | Unblock-File -ErrorAction SilentlyContinue
$app = Join-Path $dir 'GifMiniPlayer.ps1'
$errLog = Join-Path $cfgDir 'error.log'
Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue

# two GIFs the app has never seen, deliberately different sizes; one lives in a folder with a space
function New-Gif($path, $w, $h, $rgb) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2]))
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Gif)
    $bmp.Dispose()
}
$redGif  = Join-Path $dir 'My Gifs\holiday red.gif'
$blueGif = Join-Path $dir 'My Gifs\holiday blue.gif'
New-Gif $redGif  96 64 @(200, 30, 40)
New-Gif $blueGif 240 120 @(30, 90, 200)

$env:GMP_INSTANCE = $null
$appPid = 0
try {
    # ---- 1. double-click the launcher: it must ask for a file, then open their own gif ----
    $null = Start-AppViaLauncher
    $dlg = Wait-Window 'Add GIF(s) to the playlist' 25
    Assert 'launcher starts the app and it asks for a gif' (IsWin $dlg) "picker hwnd=$(Hex $dlg)"
    $pickShot = Shot-Screen $dlg 'uf-firstrun-picker'
    if (IsWin $dlg) { Pick $dlg $redGif }

    $w1 = Wait-Window 'GIF Mini Player' 25
    Start-Sleep -Milliseconds 800
    $appPid = Get-AppPid
    $r1 = Rect $w1
    $w1w = $r1.Right - $r1.Left; $w1h = $r1.Bottom - $r1.Top
    $ui1 = Ui-Text $w1
    $shot1 = Shot $w1 'uf-own-gif'
    $px1 = Center-Pixel $shot1
    Assert 'own gif opens' ((IsWin $w1) -and ($ui1 -match 'holiday red')) "window=$(Hex $w1) pid=$appPid"
    Assert 'own gif is what is drawn' ($px1 -and ([math]::Abs(([int]($px1 -split ',')[0])) - 200) -lt 25 -and ([math]::Abs(([int]($px1 -split ',')[1])) - 30) -lt 25) "center pixel $px1 (want ~200,30,40)"
    Assert 'window fits the own gif' ([math]::Abs($w1h - ([math]::Round($w1w * 64 / 96) + 47)) -le 3) "${w1w}x${w1h} (want $([math]::Round($w1w * 64 / 96) + 47))"
    Assert 'playlist says 1 of 1' ($ui1 -match '1 of 1') ''

    # ---- 2. add a second gif with the + button (the real control) -----------------------
    $btns = Btn ([BT]::Children($w1))
    Assert 'found the add button' ($btns.Count -ge 4) "$($btns.Count) buttons"
    if ($btns.Count -ge 4) {
        $add = $btns[5]      # prev, play, next, kitty, peaks, add, min, hide
        [BT]::ClickControl([IntPtr]$add.Hwnd)
    }
    $dlg2 = Wait-Window 'Add GIF(s) to the playlist' 20
    Assert 'add button opens the picker' (IsWin $dlg2) "picker hwnd=$(Hex $dlg2)"
    if (IsWin $dlg2) { Pick $dlg2 $blueGif }
    Start-Sleep -Seconds 1
    $ui2 = Ui-Text $w1
    $r2 = Rect $w1
    $w2w = $r2.Right - $r2.Left; $w2h = $r2.Bottom - $r2.Top
    $shot2 = Shot $w1 'uf-second-gif'
    $px2 = Center-Pixel $shot2
    $barKitty = Bar-Pixel $shot2
    Assert 'hello kitty theme is visible' ($barKitty -eq '253,237,240') "bar $barKitty"
    [BT]::PostMessage($w1, 0x0100, [IntPtr]0x54, [IntPtr]0)   # WM_KEYDOWN, 'T'
    Start-Sleep -Milliseconds 600
    $shotTheme = Shot $w1 'uf-theme-peaks'
    $barPeaks = Bar-Pixel $shotTheme
    Assert 'T switches to the twin peaks theme' ($barPeaks -eq '51,47,47') "bar $barPeaks"
    Assert 'second gif shows' ($ui2 -match 'holiday blue' -and $ui2 -match '2 of 2') '2 of 2 with the new name'
    Assert 'second gif is what is drawn' ($px2 -and ([math]::Abs(([int]($px2 -split ',')[0])) - 30) -lt 25 -and ([math]::Abs(([int]($px2 -split ',')[2])) - 200) -lt 25) "center pixel $px2 (want ~30,90,200)"
    Assert 'window refits to the second gif' ([math]::Abs($w2h - ([math]::Round($w2w * 120 / 240) + 47)) -le 3) "${w2w}x${w2h}"

    $cfg = $null
    try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json } catch { }
    Assert 'both own gifs saved to config' ($cfg -and @($cfg.Paths).Count -eq 2 -and @($cfg.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 2) "$(@($cfg.Paths).Count) paths"

    # ---- 3. close like a user, reopen: it must remember, not ask again ------------------
    [void][BT]::PostMessage($w1, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    $closed = $false
    if ($appPid -gt 0) {
        for ($i = 0; $i -lt 40; $i++) {
            if (-not (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) { $closed = $true; break }
            Start-Sleep -Milliseconds 250
        }
    }
    Assert 'closing the player exits cleanly' $closed "pid=$appPid"

    $null = Start-App
    $w3 = Wait-Window 'GIF Mini Player' 25
    Start-Sleep -Milliseconds 800
    $dlg3 = [BT]::Find('Add GIF(s) to the playlist')
    $ui3 = Ui-Text $w3
    $shot3 = Shot $w3 'uf-restarted'
    $px3 = Center-Pixel $shot3
    Assert 'restart does not ask again' ((IsWin $w3) -and (-not (IsWin $dlg3))) "picker present=$(IsWin $dlg3)"
    Assert 'restart restores the playlist' ($ui3 -match 'holiday blue' -and $ui3 -match '2 of 2') ''
    Assert 'restart restores the same picture' ($px3 -and ([math]::Abs(([int]($px3 -split ',')[2])) - 200) -lt 25) "center pixel $px3"
    $barAfter = Bar-Pixel $shot3
    Assert 'theme survives restart' ($barAfter -eq '51,47,47') "bar $barAfter"

    # ---- 4. wheel over the window resizes it, keeping the aspect -----------------------
    $r3 = Rect $w3
    $beforeW = $r3.Right - $r3.Left
    $cx = [int](($r3.Left + $r3.Right) / 2); $cy = [int]($r3.Top + ($r3.Bottom - $r3.Top) / 2)
    if (IsWin $w3) { [BT]::Wheel($w3, $cx, $cy, 120) }      # one notch up
    Start-Sleep -Milliseconds 800
    $r4 = Rect $w3
    $afterW = $r4.Right - $r4.Left; $afterH = $r4.Bottom - $r4.Top
    Assert 'wheel resizes the window' ($afterW -gt $beforeW) "${beforeW} -> ${afterW}"
    Assert 'resize keeps the gif shape' ([math]::Abs($afterH - ([math]::Round($afterW * 120 / 240) + 47)) -le 3) "${afterW}x${afterH}"

    # ---- 5. a second launch must not stack a second window -----------------------------
    $p3 = Start-App
    Start-Sleep -Seconds 5
    $wins = @([BT]::FindAll('GIF Mini Player'))
    Assert 'second launch makes no second window' ($wins.Count -eq 1) "$($wins.Count) windows"
    Assert 'second launch exits' (-not (Get-Process -Id $p3.Id -ErrorAction SilentlyContinue)) "pid=$($p3.Id)"

    Assert 'no unhandled error' (-not (Test-Path -LiteralPath $errLog)) ''
} catch {
    $where = @($_.ScriptStackTrace -split "`n")[0]
    Assert 'test ran to the end' $false "$($_.Exception.Message) | $where"
} finally {
    # Always put the playlist back, even when something above throws.
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match 'GifMiniPlayer\.ps1' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
    # Stop-Process returns before the process is gone, and a dying player still holds
    # config.json: restoring too early silently leaves the test's theme behind.
    for ($i = 0; $i -lt 20; $i++) {
        $alive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match 'GifMiniPlayer\.ps1' })
        if ($alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }
    Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $cfgBak) {
        try { Move-Item $cfgBak $cfgPath -Force } catch { }
    }
}

foreach ($s in $shots) {
    if (Test-Path -LiteralPath $s) { Post-Bytes (Split-Path -Leaf $s) ([IO.File]::ReadAllBytes($s)) }
}

$sha = ''
try { $sha = (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash.ToLower() } catch { }
$pass = (@($results.Values | Where-Object { -not $_.ok }).Count -eq 0)
$lines = @($results.GetEnumerator() | ForEach-Object {
    "{0}  {1} {2}" -f $(if ($_.Value.ok) { 'PASS' } else { 'FAIL' }), $_.Key, $_.Value.detail
})
$summary = "user flow: $(@($results.Values | Where-Object { $_.ok }).Count)/$($results.Count) passed  sha256=$sha`r`n" + ($lines -join "`r`n")
Write-Host $summary
Post 'userflow-summary.txt' $summary
Post 'userflow-result.json' ([ordered]@{ pass = $pass; sha256 = $sha; results = $results; shots = @($shots | ForEach-Object { Split-Path -Leaf $_ }) } | ConvertTo-Json -Depth 5)
