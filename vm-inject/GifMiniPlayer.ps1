<#
    GifMiniPlayer.ps1
    A tiny frameless GIF mini-player that lives in the Windows system tray.
    Like Spotify's mini-player, but for animated GIFs.

    Run:   powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\GifMiniPlayer.ps1
    Stop:  right-click the tray icon -> Exit

    Mouse / keys:
      drag        move the window
      wheel       resize
      double-click or Space    play / pause
      right-click              menu
      Esc                      hide to tray
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$ErrorActionPreference = 'Stop'

$script:CfgDir  = Join-Path $env:APPDATA 'GifMiniPlayer'
$script:CfgPath = Join-Path $script:CfgDir 'config.json'
if (-not (Test-Path -LiteralPath $script:CfgDir)) {
    New-Item -ItemType Directory -Path $script:CfgDir -Force | Out-Null
}

# WinForms catches exceptions thrown inside event handlers itself and shows a modal
# "Unhandled exception" dialog -- a script-level trap never sees them. Log those too.
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    $detail = "UI thread exception at $([DateTime]::Now.ToString('s'))`r`n$($e.Exception.ToString())"
    try { Add-Content -LiteralPath (Join-Path $script:CfgDir 'error.log') -Value $detail } catch { }
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    $detail = "AppDomain exception at $([DateTime]::Now.ToString('s'))`r`n$($e.ExceptionObject.ToString())"
    try { Add-Content -LiteralPath (Join-Path $script:CfgDir 'error.log') -Value $detail } catch { }
})

# Any unhandled error: log it to %APPDATA%\GifMiniPlayer\error.log and say so once,
# instead of vanishing silently (the launcher runs windowless, so a bare crash is invisible).
trap {
    $detail = "GIF Mini Player failed at $([DateTime]::Now.ToString('s'))`r`n$($_ | Out-String)"
    try {
        Add-Content -LiteralPath (Join-Path $script:CfgDir 'error.log') -Value $detail
    } catch { }
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "GIF Mini Player could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nDetails: $script:CfgDir\error.log",
            'GIF Mini Player') | Out-Null
    } catch {
        Write-Host $detail
    }
    exit 1
}

$script:GifPath = $null
$script:Paused  = $false

# ---------------------------------------------------------------- config ----

function Get-Cfg {
    if (Test-Path -LiteralPath $script:CfgPath) {
        try {
            Get-Content -LiteralPath $script:CfgPath -Raw | ConvertFrom-Json
            return
        } catch { }
    }
    [pscustomobject]@{}
}

function Save-Cfg {
    if (-not $script:form) { return }
    $o = [ordered]@{
        Path    = $script:GifPath
        X       = $script:form.Location.X
        Y       = $script:form.Location.Y
        W       = $script:form.Width
        TopMost = [bool]$script:form.TopMost
    }
    try { ($o | ConvertTo-Json) | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8 } catch { }
}

# ------------------------------------------------------------- elements ----

function Set-RoundedRegion {
    param([System.Windows.Forms.Control]$Control, [int]$Radius)
    $rect = $Control.ClientRectangle
    if ($rect.Width -lt 4 -or $rect.Height -lt 4) { return }
    $d = [Math]::Min($Radius * 2, [Math]::Min($rect.Width, $rect.Height))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $old = $Control.Region
    $Control.Region = New-Object System.Drawing.Region $path
    if ($old) { $old.Dispose() }
    $path.Dispose()
}

function New-TrayIcon {
    $script:trayBmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($script:trayBmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 150, 130, 255))
    $points = [System.Drawing.Point[]]@(
        (New-Object System.Drawing.Point 10, 6),
        (New-Object System.Drawing.Point 10, 26),
        (New-Object System.Drawing.Point 25, 16)
    )
    $g.FillPolygon($brush, $points)
    $g.Dispose()
    $brush.Dispose()
    $handle = $script:trayBmp.GetHicon()
    return [System.Drawing.Icon]::FromHandle($handle)
}

# ------------------------------------------------------------------ form ----

$script:form = New-Object System.Windows.Forms.Form
$script:form.FormBorderStyle = 'None'
$script:form.StartPosition     = 'Manual'
$script:form.ShowInTaskbar     = $false
$script:form.Text              = 'GIF Mini Player'
$script:form.BackColor         = [System.Drawing.Color]::FromArgb(24, 24, 28)
$script:form.MinimumSize       = New-Object System.Drawing.Size 80, 60
$script:form.AllowDrop         = $true
$script:form.KeyPreview        = $true

$script:pic = New-Object System.Windows.Forms.PictureBox
$script:pic.Dock       = 'Fill'
$script:pic.SizeMode   = 'Zoom'
$script:pic.BackColor  = [System.Drawing.Color]::FromArgb(24, 24, 28)
$script:form.Controls.Add($script:pic)

# frame stepping state (own animation clock, so pause is real)
$script:frameDim   = [System.Drawing.Imaging.FrameDimension]::Time
$script:frameCount = 0
$script:frameIdx   = 0
$script:frameBmp   = $null
$script:delays     = @()
$script:animTimer  = New-Object System.Windows.Forms.Timer
$script:animTimer.Interval = 100
$script:animTimer.Add_Tick({ Step-Frame })

$script:form.Add_Resize({ Set-RoundedRegion -Control $script:form -Radius 10 })
$script:form.Add_FormClosing({ Save-Cfg })

# ------------------------------------------------------------- behaviour ----

function Resize-ToImage {
    param([int]$Width = 0)
    if (-not $script:gif) { return }
    $w = if ($Width -gt 0) { $Width } else { [int]$script:form.Width }
    if ($w -lt 80) { $w = 80 }
    $ratio = $script:gif.Width / $script:gif.Height
    $h = [int][Math]::Round($w / $ratio)
    if ($h -lt 60) { $h = 60 }
    $script:form.ClientSize = New-Object System.Drawing.Size $w, $h
    Set-RoundedRegion -Control $script:form -Radius 10
}

function Show-Gif {
    param([string]$FilePath)
    if (-not $FilePath) { return }
    if (-not (Test-Path -LiteralPath $FilePath)) { return }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $stream = New-Object System.IO.MemoryStream
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Position = 0
        $image = [System.Drawing.Image]::FromStream($stream)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Cannot open `"$FilePath`".`r`n$($_.Exception.Message)", 'GIF Mini Player') | Out-Null
        return
    }

    $script:animTimer.Stop()
    $script:pic.Image = $null
    if ($script:frameBmp) { $script:frameBmp.Dispose(); $script:frameBmp = $null }
    if ($script:gif)      { $script:gif.Dispose() }
    if ($script:stream)   { $script:stream.Dispose() }

    $script:stream  = $stream
    $script:gif     = $image
    $script:GifPath = $FilePath
    $script:Paused  = $false

    # Frame count and per-frame delays (PropertyTagFrameDelay 0x5100, units of 1/100 s).
    try { $script:frameCount = $image.GetFrameCount($script:frameDim) } catch { $script:frameCount = 1 }
    if ($script:frameCount -lt 1) { $script:frameCount = 1 }
    $script:delays = @()
    try {
        $prop = $image.GetPropertyItem(0x5100)
        $raw = $prop.Value
        for ($i = 0; $i -lt [Math]::Min($script:frameCount, [int]($raw.Length / 4)); $i++) {
            $d = [System.BitConverter]::ToInt32($raw, $i * 4)
            if ($d -le 0) { $d = 10 }
            $script:delays += $d
        }
    } catch { }

    $script:frameIdx = 0
    Show-Frame 0
    if ($script:frameCount -gt 1) { $script:animTimer.Start() }

    Resize-ToImage
    Save-Cfg
    Sync-Menu
}

# Frames are drawn by hand instead of letting PictureBox animate the Image itself.
# PictureBox has no way to pause (ImageAnimator.StopAnimate needs its private callback),
# so frame stepping is the only way to get a real pause/resume at the exact frame.
function Show-Frame {
    param([int]$Index)
    if (-not $script:gif) { return }
    if ($script:frameCount -gt 1) {
        try { $script:gif.SelectActiveFrame($script:frameDim, $Index) | Out-Null } catch { }
    }
    $bmp = New-Object System.Drawing.Bitmap $script:gif.Width, $script:gif.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($script:gif, 0, 0, $script:gif.Width, $script:gif.Height)
    $g.Dispose()

    $old = $script:pic.Image
    $script:pic.Image = $bmp
    $script:frameBmp = $bmp
    if ($old -and -not [object]::ReferenceEquals($old, $script:gif)) {
        try { $old.Dispose() } catch { }
    }

    $delay = 10
    if ($script:delays.Count -gt $Index) { $delay = $script:delays[$Index] }
    if ($delay -le 0) { $delay = 10 }
    $script:animTimer.Interval = [int][Math]::Max(20, $delay * 10)
}

function Step-Frame {
    if (-not $script:gif -or $script:Paused) { return }
    if ($script:frameCount -le 1) { return }
    $script:frameIdx = ($script:frameIdx + 1) % $script:frameCount
    Show-Frame $script:frameIdx
}

function Toggle-Pause {
    if (-not $script:gif -or $script:frameCount -le 1) {
        $script:Paused = $false
        return
    }
    if ($script:Paused) {
        $script:Paused = $false
        $script:animTimer.Start()
    } else {
        $script:Paused = $true
        $script:animTimer.Stop()
    }
    Sync-Menu
}

function Open-GifDialog {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Animated GIF (*.gif)|*.gif|Images (*.gif;*.png;*.jpg)|*.gif;*.png;*.jpg|All files (*.*)|*.*'
    $dlg.Title  = 'Pick a GIF'
    if ($dlg.ShowDialog() -eq 'OK') { Show-Gif -FilePath $dlg.FileName }
    $dlg.Dispose()
}

function Get-StartupLink {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'GifMiniPlayer.lnk'
}

function Set-StartWithWindows {
    param([bool]$Enable)
    $link = Get-StartupLink
    if (-not $Enable) {
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        return
    }
    $shell  = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = (Get-Process -Id $PID).Path
    $psArgs = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    if ($script:GifPath) { $psArgs += " `"$script:GifPath`"" }
    $shortcut.Arguments  = $psArgs
    $shortcut.WorkingDirectory = Split-Path -Parent $PSCommandPath
    $shortcut.IconLocation = (Get-Process -Id $PID).Path + ',0'
    $shortcut.Save()
}

function Show-Window {
    $script:form.Show()
    $script:form.Activate()
    $script:form.BringToFront()
}

function Hide-Window {
    Save-Cfg
    $script:form.Hide()
}

# ------------------------------------------------------------ tray menu ----

$script:menu = New-Object System.Windows.Forms.ContextMenuStrip

$script:miOpen = New-Object System.Windows.Forms.ToolStripMenuItem 'Open GIF...'
$script:miOpen.Add_Click({ Open-GifDialog })
$script:menu.Items.Add($script:miOpen) | Out-Null

$script:miPlay = New-Object System.Windows.Forms.ToolStripMenuItem 'Pause'
$script:miPlay.Add_Click({ Toggle-Pause })
$script:menu.Items.Add($script:miPlay) | Out-Null

$script:miInfo = New-Object System.Windows.Forms.ToolStripMenuItem 'No GIF loaded'
$script:miInfo.Enabled = $false
$script:menu.Items.Add($script:miInfo) | Out-Null

$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$script:miTop = New-Object System.Windows.Forms.ToolStripMenuItem 'Always on top'
$script:miTop.CheckOnClick = $true
$script:miTop.Add_CheckedChanged({
    if ($script:syncing) { return }
    $script:form.TopMost = $script:miTop.Checked
    Save-Cfg
})
$script:menu.Items.Add($script:miTop) | Out-Null

$script:miStart = New-Object System.Windows.Forms.ToolStripMenuItem 'Start with Windows'
$script:miStart.CheckOnClick = $true
$script:miStart.Add_CheckedChanged({
    if ($script:syncing) { return }
    try { Set-StartWithWindows -Enable $script:miStart.Checked }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'GIF Mini Player') | Out-Null }
})
$script:menu.Items.Add($script:miStart) | Out-Null

$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$script:miHide = New-Object System.Windows.Forms.ToolStripMenuItem 'Hide to tray'
$script:miHide.Add_Click({ Hide-Window })
$script:menu.Items.Add($script:miHide) | Out-Null

$script:miExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
$script:miExit.Add_Click({ Save-Cfg; $script:tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$script:menu.Items.Add($script:miExit) | Out-Null

function Sync-Menu {
    if (-not $script:menu) { return }
    $script:syncing = $true
    try {
        $script:miPlay.Text    = if ($script:Paused) { 'Play' } else { 'Pause' }
        $script:miPlay.Enabled = [bool]$script:gif
        $script:miInfo.Text    = if ($script:GifPath) { Split-Path -Leaf $script:GifPath } else { 'No GIF loaded' }
        $script:miTop.Checked  = [bool]$script:form.TopMost
        $script:miStart.Checked = Test-Path -LiteralPath (Get-StartupLink)
    } finally {
        $script:syncing = $false
    }
}

# --------------------------------------------------------- tray + wiring ----

$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = New-TrayIcon
$script:tray.Text = 'GIF Mini Player'
$script:tray.ContextMenuStrip = $script:menu
$script:tray.Visible = $true
$script:tray.Add_MouseDoubleClick({
    if ($script:form.Visible) { Hide-Window } else { Show-Window }
})
$script:tray.Add_MouseClick({
    param($sender, $e)
    # single left click only when the window is hidden, so it does not fight double-click
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and -not $script:form.Visible) { Show-Window }
})
$script:tray.Add_BalloonTipClicked({ Show-Window })

$script:menu.Add_Opening({ Sync-Menu })

$script:form.ContextMenuStrip = $script:menu
$script:pic.ContextMenuStrip  = $script:menu

# drag to move / wheel to resize / drop a file -- attached to BOTH form and picture box,
# because WinForms mouse and drag-drop events do not bubble from child controls to the parent.
$script:dragging = $false

$onMouseDown = {
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:startCursor = [System.Windows.Forms.Cursor]::Position
        $script:startForm   = $script:form.Location
        $script:dragging    = $true
    }
}

$onMouseMove = {
    param($sender, $e)
    if ($script:dragging) {
        $cur = [System.Windows.Forms.Cursor]::Position
        $dx  = $cur.X - $script:startCursor.X
        $dy  = $cur.Y - $script:startCursor.Y
        $script:form.Location = New-Object System.Drawing.Point (
            $script:startForm.X + $dx), ($script:startForm.Y + $dy)
    }
}

$onMouseUp = { param($sender, $e) $script:dragging = $false }

$onWheel = {
    param($sender, $e)
    if (-not $script:gif) { return }
    $delta = if ($e.Delta -gt 0) { 20 } else { -20 }
    $newW  = [int]$script:form.Width + $delta
    if ($newW -lt 80)  { $newW = 80 }
    if ($newW -gt 900) { $newW = 900 }
    Resize-ToImage -Width $newW
    Save-Cfg
}

$onDragEnter = {
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
}

$onDragDrop = {
    param($sender, $e)
    $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files -and $files.Count -gt 0) { Show-Gif -FilePath $files[0] }
}

foreach ($surface in @($script:form, $script:pic)) {
    $surface.Add_MouseDown($onMouseDown)
    $surface.Add_MouseMove($onMouseMove)
    $surface.Add_MouseUp($onMouseUp)
    $surface.Add_DoubleClick({ Toggle-Pause })
    $surface.Add_MouseWheel($onWheel)
    $surface.AllowDrop = $true
    $surface.Add_DragEnter($onDragEnter)
    $surface.Add_DragDrop($onDragDrop)
}

$script:form.Add_KeyDown({
    param($sender, $e)
    switch ($e.KeyCode) {
        ([System.Windows.Forms.Keys]::Space)  { Toggle-Pause;    $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Escape) { Hide-Window;     $e.Handled = $true }
        ([System.Windows.Forms.Keys]::O)      { if ($e.Control) { Open-GifDialog; $e.Handled = $true } }
    }
})

# --------------------------------------------------------------- startup ----

$cfg = Get-Cfg

$script:form.TopMost = if ($null -ne $cfg.TopMost) { [bool]$cfg.TopMost } else { $true }

$startW = if ($cfg.W) { [int]$cfg.W } else { 320 }
if ($startW -lt 80) { $startW = 320 }
$script:form.Size = New-Object System.Drawing.Size $startW, 320

if ($null -ne $cfg.X -and $null -ne $cfg.Y) {
    $script:form.Location = New-Object System.Drawing.Point ([int]$cfg.X), ([int]$cfg.Y)
} else {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:form.Location = New-Object System.Drawing.Point (
        $screen.Right - $startW - 40), ($screen.Top + 40)
}

$initial = if ($Path) { $Path }
           elseif ($cfg.Path -and (Test-Path -LiteralPath $cfg.Path)) { $cfg.Path }
           else { $null }

if ($initial) {
    Show-Gif -FilePath $initial
} else {
    Open-GifDialog
}

Set-RoundedRegion -Control $script:form -Radius 10
Sync-Menu

$script:form.Show()
$script:form.Activate()

try {
    [System.Windows.Forms.Application]::Run($script:form)
} finally {
    $script:tray.Visible = $false
    $script:tray.Dispose()
}
