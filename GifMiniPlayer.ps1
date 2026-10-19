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
      right-click              menu (Theme: Hello Kitty / Twin Peaks)
      T                        switch theme
      Esc                      hide to tray
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------- single instance ----
# A second launch focuses the running player instead of stacking another window
# (stacked duplicates are what made an old build appear to keep coming back).
function Focus-ExistingPlayer {
    if (-not ('GmpWindow' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class GmpWindow {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    public static bool Focus() {
        bool found = false;
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            SetForegroundWindow(h);
            found = true; return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@
    }
    return [GmpWindow]::Focus()
}

# Take OWNERSHIP, do not ask whether the name exists: a stale (abandoned) mutex object can
# outlive its owner, and `createdNew` would then report false forever and block every start.
# GMP_INSTANCE lets a second, independent player run beside the normal one (used by the
# pipeline so a stray instance can never block a test). It also namespaces the mutex.
$script:instanceName = if ($env:GMP_INSTANCE) { $env:GMP_INSTANCE } else { 'default' }
$mutexName = 'Local\GifMiniPlayer.' + $script:instanceName
$script:instanceMutex = New-Object System.Threading.Mutex($false, $mutexName)
$script:haveInstance = $false
try {
    $script:haveInstance = $script:instanceMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # previous owner died without releasing it; we own it now
    $script:haveInstance = $true
}
if (-not $script:haveInstance) {
    [void](Focus-ExistingPlayer)   # if it is hidden in the tray, double-click the tray icon
    return
}

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

# bottom control bar height -- must exist before the bar is constructed
$script:barHeight = 44
$script:progHeight = 3

# playlist: every GIF you have opened, and which one is on screen
$script:Playlist = New-Object System.Collections.Generic.List[string]
$script:PlayIndex = -1

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
        Paths   = @($script:Playlist)
        Index   = $script:PlayIndex
        X       = $script:form.Location.X
        Y       = $script:form.Location.Y
        W       = $script:form.Width
        Theme   = $script:theme
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

# One tray icon per theme, built on first use. The bitmap must be kept alive: the
# Icon only wraps its HICON, and a collected bitmap would leave a dead handle.
$script:trayArt = @{}
function Tray-Icon($name) {
    if (-not $script:trayArt.ContainsKey($name)) {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $tint = $script:Themes[$name]
        if (-not $tint.Icon) { $tint.Icon = $tint.Accent }
        $brush = New-Object System.Drawing.SolidBrush $tint.Icon
        $points = [System.Drawing.Point[]]@(
            (New-Object System.Drawing.Point 10, 6),
            (New-Object System.Drawing.Point 10, 26),
            (New-Object System.Drawing.Point 25, 16)
        )
        $g.FillPolygon($brush, $points)
        $g.Dispose()
        $brush.Dispose()
        $script:trayArt[$name] = @{
            Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
            Bmp  = $bmp
        }
    }
    return $script:trayArt[$name].Icon
}

# ------------------------------------------------------------------ form ----

$script:form = New-Object System.Windows.Forms.Form
$script:form.FormBorderStyle = 'None'
$script:form.StartPosition     = 'Manual'
$script:form.ShowInTaskbar     = $true   # changing this at runtime recreates the handle
$script:form.Text              = if ($script:instanceName -eq 'default') { 'GIF Mini Player' } else { "GIF Mini Player [$script:instanceName]" }
$script:form.BackColor         = [System.Drawing.Color]::FromArgb(24, 24, 28)
$script:form.MinimumSize       = New-Object System.Drawing.Size 80, 60
$script:form.AllowDrop         = $true
$script:form.KeyPreview        = $true

$script:pic = New-Object System.Windows.Forms.PictureBox
$script:pic.Dock       = 'None'   # sized explicitly: the bar owns the bottom strip
$script:pic.SizeMode   = 'Zoom'
$script:pic.BackColor  = [System.Drawing.Color]::FromArgb(24, 24, 28)
$script:form.Controls.Add($script:pic)

# ---------------------------------------------------------------- chrome ----
# Spotify-mini-player idiom: near-black card, one slim row, dim grey icons that brighten
# on hover, a green accent, and two quiet lines of type. Everything is laid out explicitly
# (no Dock) so positions cannot be reordered by z-order later.
# Owner-drawn glyphs: kitty is chunky and rounded, peaks is thin and sharp, and the
# colour always comes from the button's role (hover recolours it for free).
function Draw-Glyph($g, $b) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TranslateTransform([single]($b.Width / 2), [single]($b.Height / 2))
    $kitty = ($script:theme -eq 'kitty')
    $brush = New-Object System.Drawing.SolidBrush $b.ForeColor
    $pen   = New-Object System.Drawing.Pen $b.ForeColor, $(if ($kitty) { 2.4 } else { 1.6 })
    $cap   = $(if ($kitty) { [System.Drawing.Drawing2D.LineCap]::Round } else { [System.Drawing.Drawing2D.LineCap]::Flat })
    $pen.StartCap = $cap
    $pen.EndCap   = $cap
    if ($kitty) { $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round }
    function P($x, $y) { [System.Drawing.Point]::new($x, $y) }
    switch ($b.Name) {
        'prev'  {
            if ($kitty) { $g.FillPolygon($brush, [System.Drawing.Point[]]@((P 5 -6), (P 5 6), (P -4 0))) }
            else        { $g.DrawLines($pen, [System.Drawing.Point[]]@((P 3 -6), (P -3 0), (P 3 6))) }
        }
        'next'  {
            if ($kitty) { $g.FillPolygon($brush, [System.Drawing.Point[]]@((P -5 -6), (P -5 6), (P 4 0))) }
            else        { $g.DrawLines($pen, [System.Drawing.Point[]]@((P -3 -6), (P 3 0), (P -3 6))) }
        }
        'play'  {
            if ($kitty) { $g.FillPolygon($brush, [System.Drawing.Point[]]@((P -3 -6), (P -3 6), (P 6 0))) }
            else        { $g.DrawPolygon($pen, [System.Drawing.Point[]]@((P -3 -6), (P -3 6), (P 6 0))) }
        }
        'pause' {
            $pen.Width = $(if ($kitty) { 3.4 } else { 2.4 })
            $g.DrawLine($pen, -3, -6, -3, 6)
            $g.DrawLine($pen,  3, -6,  3, 6)
        }
        'add'   { $g.DrawLine($pen, -5, 0, 5, 0); $g.DrawLine($pen, 0, -5, 0, 5) }
        'min'   { $g.DrawLine($pen, -5, 0, 5, 0) }
        'hide'  { $g.DrawLine($pen, -4, -4, 4, 4); $g.DrawLine($pen, -4, 4, 4, -4) }
        'kitty' {   # the bow
            $g.FillPolygon($brush, [System.Drawing.Point[]]@((P -6 -4), (P -6 4), (P -1 0)))
            $g.FillPolygon($brush, [System.Drawing.Point[]]@((P 6 -4), (P 6 4), (P 1 0)))
            $g.FillEllipse($brush, -2, -2, 4, 4)
        }
        'peaks' {   # the two peaks on the town sign
            $g.DrawLines($pen, [System.Drawing.Point[]]@((P -7 4), (P -3 -5), (P 0 0), (P 3 -4), (P 7 4)))
        }
    }
    $pen.Dispose()
    $brush.Dispose()
}

function New-FlatButton {
    param(
        [string]$Kind, [string]$Tip, [int]$W, [int]$H,
        [scriptblock]$OnClick, [string]$Role
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Name      = $Kind          # Draw-Glyph switches on this
    $b.FlatStyle = 'Flat'
    $b.Size      = New-Object System.Drawing.Size $W, $H
    $b.TabStop   = $false
    $b.BackColor = $script:StyleBar
    $b.ForeColor = Role-Color $Role
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $script:StyleHover
    $b.FlatAppearance.MouseDownBackColor = $script:StylePress
    $b.Add_Click($OnClick)
    $b.Add_Paint({ param($s, $e) Draw-Glyph $e.Graphics $s })
    $b.Add_MouseEnter({ param($s, $e) $s.ForeColor = $script:StyleWhite })
    $b.Add_MouseLeave({ param($s, $e) $s.ForeColor = Role-Color $s.Tag })
    $b.Tag = $Role
    if ($Tip) { $script:tip.SetToolTip($b, $Tip) }
    return $b
}

# ---------------------------------------------------------------- themes ----
# Two palettes with a role per control, so a switch is a repaint, not a rebuild.
# Both share one shape (Radius/BtnRadius) and swap only colour + title font.
# Hello Kitty: her "normal colors" from color-hex palette 1022256 - #d6213b bow,
# #fefefe face, #f2d925 nose, #1f6494 overalls, #000 whiskers.
# Twin Peaks: color-hex palette 37200 (by arkainvom) - #e74f4f #74bdb7 #332f2f
# #47a54e #f9e9e9. See the table for which role each gets.
$script:fontKitty = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:fontPeaks = New-Object System.Drawing.Font('Georgia', 9.5, [System.Drawing.FontStyle]::Bold)
$script:Themes = @{
    kitty = @{
        # color-hex.com/color-palette/1022256 "Hello kitty" by lollysollie1:
        # #d6213b bow #fefefe face #f2d925 nose #1f6494 overalls #000000 whiskers.
        # Face-white card, bow-red type/accent, a bow tint as the bar; the nose yellow
        # is only the hover/press highlight, so it never becomes the primary colour.
        Card      = [System.Drawing.Color]::FromArgb(254, 254, 254)   # the face
        Bar       = [System.Drawing.Color]::FromArgb(253, 237, 240)   # bow tint
        Hover     = [System.Drawing.Color]::FromArgb(242, 217,  37)   # the nose
        Press     = [System.Drawing.Color]::FromArgb(224, 196,  28)
        Text      = [System.Drawing.Color]::FromArgb(  0,   0,   0)   # the whiskers
        Dim       = [System.Drawing.Color]::FromArgb( 31, 100, 148)   # the overalls
        Faint     = [System.Drawing.Color]::FromArgb(107, 107, 107)
        Track     = [System.Drawing.Color]::FromArgb(246, 221, 226)
        Accent    = [System.Drawing.Color]::FromArgb(214,  33,  59)   # the bow
        Icon      = [System.Drawing.Color]::FromArgb(214,  33,  59)
        Radius    = 12
        BtnRadius = 8
        Font      = $script:fontKitty
    }
    peaks = @{
        # color-hex.com/color-palette/37200 "Twin Peaks" by arkainvom:
        # #e74f4f red #74bdb7 teal #332f2f grey #47a54e green #f9e9e9 off-white.
        # All five appear: grey bar, off-white type, red progress/play, teal count,
        # green min/hide. Card and hover states are shades of the grey.
        Card      = [System.Drawing.Color]::FromArgb( 31,  27,  27)
        Bar       = [System.Drawing.Color]::FromArgb( 51,  47,  47)
        Hover     = [System.Drawing.Color]::FromArgb( 63,  57,  57)
        Press     = [System.Drawing.Color]::FromArgb( 75,  68,  68)
        Text      = [System.Drawing.Color]::FromArgb(249, 233, 233)
        Dim       = [System.Drawing.Color]::FromArgb(116, 189, 183)
        Faint     = [System.Drawing.Color]::FromArgb( 71, 165,  78)
        Track     = [System.Drawing.Color]::FromArgb( 30,  27,  27)
        Accent    = [System.Drawing.Color]::FromArgb(231,  79,  79)
        Icon      = [System.Drawing.Color]::FromArgb(231,  79,  79)
        Radius    = 12
        BtnRadius = 8
        Font      = $script:fontPeaks
    }
}
$script:theme = 'kitty'

function Role-Color($role) {
    switch ($role) {
        'accent' { return $script:StyleAccent }
        'faint'  { return $script:StyleFaint }
        # the theme buttons show their own theme's accent only while it is active
        'kitty'  { return $(if ($script:theme -eq 'kitty') { $script:StyleAccent } else { $script:StyleDim }) }
        'peaks'  { return $(if ($script:theme -eq 'peaks') { $script:StyleAccent } else { $script:StyleDim }) }
        default  { return $script:StyleDim }
    }
}

function Set-Theme {
    param([string]$Name, [switch]$NoSave)
    if (-not $script:Themes.Contains($Name)) { $Name = 'kitty' }
    $t = $script:Themes[$Name]
    $script:theme     = $Name
    $script:StyleCard   = $t.Card
    $script:StyleBar    = $t.Bar
    $script:StyleHover  = $t.Hover
    $script:StylePress  = $t.Press
    $script:StyleWhite  = $t.Text
    $script:StyleDim    = $t.Dim
    $script:StyleFaint  = $t.Faint
    $script:StyleTrack  = $t.Track
    $script:StyleAccent = $t.Accent
    $script:radius      = $t.Radius
    $script:btnRadius   = $t.BtnRadius
    if ($script:miKitty) {
        $script:miKitty.Checked = ($Name -eq 'kitty')
        $script:miPeaks.Checked = ($Name -eq 'peaks')
    }
    if (-not $script:bar) { return }   # palette only, before the controls are built
    $script:form.BackColor     = $t.Card
    $script:pic.BackColor      = $t.Card
    $script:bar.BackColor      = $t.Bar
    $script:textBox.BackColor  = $t.Bar
    $script:progTrack.BackColor = $t.Track
    $script:progFill.BackColor  = $t.Accent
    $script:lblTitle.ForeColor = $t.Text
    $script:lblTitle.Font      = $t.Font
    $script:lblSub.ForeColor   = $t.Dim
    foreach ($b in @($script:btnPrev, $script:btnPlay, $script:btnNext, $script:btnAdd, $script:btnMin, $script:btnHide, $script:btnKitty, $script:btnPeaks)) {
        if (-not $b) { continue }
        $b.BackColor = $t.Bar
        $b.ForeColor = Role-Color $b.Tag
        $b.FlatAppearance.MouseOverBackColor = $t.Hover
        $b.FlatAppearance.MouseDownBackColor = $t.Press
        Set-RoundedRegion -Control $b -Radius $script:btnRadius
    }
    Set-RoundedRegion -Control $script:form -Radius $script:radius
    if ($script:tray) { $script:tray.Icon = Tray-Icon $Name }
    if ($script:gif) { Show-Frame $script:frameIdx }   # repaint the letterbox in the new card colour
    if (-not $NoSave) { Save-Cfg }
}

Set-Theme 'kitty' -NoSave      # defaults before any control is built

$script:tip = New-Object System.Windows.Forms.ToolTip

# loop progress line, like a track scrubber
$script:progTrack = New-Object System.Windows.Forms.Panel
$script:progTrack.BackColor = $script:StyleTrack
$script:progFill = New-Object System.Windows.Forms.Panel
$script:progFill.BackColor = $script:StyleAccent
$script:progFill.Height = $script:progHeight
$script:progTrack.Controls.Add($script:progFill)

# control row
$script:bar = New-Object System.Windows.Forms.Panel
$script:bar.BackColor = $script:StyleBar

$script:btnPrev = New-FlatButton -Kind 'prev' -Tip 'Previous GIF  (Left)'  -W 32 -H 28 -Role 'dim' -OnClick { Prev-Gif }
$script:btnPlay = New-FlatButton -Kind 'pause' -Tip 'Pause  (Space)' -W 32 -H 28 -Role 'accent' -OnClick { Toggle-Pause }
$script:btnNext = New-FlatButton -Kind 'next' -Tip 'Next GIF  (Right)'     -W 32 -H 28 -Role 'dim' -OnClick { Next-Gif }
$script:btnAdd  = New-FlatButton -Kind 'add'  -Tip 'Add GIFs  (Ctrl+O)'  -W 24 -H 22 -Role 'dim' -OnClick { Open-GifDialog }
$script:btnMin  = New-FlatButton -Kind 'min'  -Tip 'Minimize to taskbar' -W 20 -H 20 -Role 'faint' -OnClick {
    $script:form.WindowState = 'Minimized'   # restores from the taskbar
}
$script:btnHide = New-FlatButton -Kind 'hide' -Tip 'Hide to tray  (Esc)' -W 20 -H 20 -Role 'faint' -OnClick { Hide-Window }
# theme pickers: a bow for Hello Kitty, the town sign's two peaks for Twin Peaks
$script:btnKitty = New-FlatButton -Kind 'kitty' -Tip 'Hello Kitty theme' -W 16 -H 16 -Role 'kitty' -OnClick { Set-Theme 'kitty' }
$script:btnPeaks = New-FlatButton -Kind 'peaks' -Tip 'Twin Peaks theme  (T)' -W 16 -H 16 -Role 'peaks' -OnClick { Set-Theme 'peaks' }

# two lines of type, Spotify-style: name in white, position in grey
$script:textBox = New-Object System.Windows.Forms.Panel
$script:textBox.BackColor = $script:StyleBar
$script:lblTitle = New-Object System.Windows.Forms.Label
$script:lblTitle.AutoEllipsis = $true
$script:lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:lblTitle.ForeColor = $script:StyleWhite
$script:lblTitle.BackColor = [System.Drawing.Color]::Transparent
$script:lblSub = New-Object System.Windows.Forms.Label
$script:lblSub.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
$script:lblSub.ForeColor = $script:StyleDim
$script:lblSub.BackColor = [System.Drawing.Color]::Transparent
$script:textBox.Controls.Add($script:lblTitle)
$script:textBox.Controls.Add($script:lblSub)

foreach ($c in @($script:progTrack, $script:bar)) { $script:form.Controls.Add($c) }
$script:bar.Controls.Add($script:textBox)
foreach ($c in @($script:btnPrev, $script:btnPlay, $script:btnNext, $script:btnKitty, $script:btnPeaks)) { $script:bar.Controls.Add($c) }
foreach ($c in @($script:btnAdd, $script:btnMin, $script:btnHide)) { $script:bar.Controls.Add($c) }

# Rounded hover backgrounds: the only soft shape WinForms can give a flat button.
foreach ($b in @($script:btnPrev, $script:btnPlay, $script:btnNext, $script:btnAdd, $script:btnMin, $script:btnHide, $script:btnKitty, $script:btnPeaks)) {
    Set-RoundedRegion -Control $b -Radius $script:btnRadius
}

# explicit geometry for every piece; called on load and on resize
function Set-Layout {
    $w = [int]$script:form.ClientSize.Width
    $gifH = [Math]::Max(1, $script:form.ClientSize.Height - $script:progHeight - $script:barHeight)
    $script:pic.SetBounds(0, 0, $w, $gifH)
    $script:progTrack.SetBounds(0, $gifH, $w, $script:progHeight)
    $script:bar.SetBounds(0, $gifH + $script:progHeight, $w, $script:barHeight)

    $by = [int](($script:barHeight - 28) / 2)
    $script:btnPrev.SetBounds(8,  $by, 32, 28)
    $script:btnPlay.SetBounds(42,  $by, 32, 28)
    $script:btnNext.SetBounds(76,  $by, 32, 28)
    $rightY = [int](($script:barHeight - 20) / 2)
    $script:btnHide.SetBounds($w - 26, $rightY, 20, 20)
    $script:btnMin.SetBounds($w - 50, $rightY, 20, 20)
    $script:btnAdd.SetBounds($w - 76, $rightY, 22, 20)
    $themeY = [int](($script:barHeight - 16) / 2)
    $script:btnKitty.SetBounds($w - 120, $themeY, 16, 16)
    $script:btnPeaks.SetBounds($w - 100, $themeY, 16, 16)

    $tx = 118
    $tw = [Math]::Max(20, ($w - 124) - $tx)
    $script:textBox.SetBounds($tx, 0, $tw, $script:barHeight)
    $script:lblTitle.SetBounds(0, 9,  $tw, 16)
    $script:lblSub.SetBounds(0, 25, $tw, 14)

    $script:progTrack.Visible = $true
    $script:progFill.Height = $script:progHeight
    Set-Progress
}

function Set-Progress {
    if (-not $script:progFill) { return }
    $w = [int]$script:progTrack.Width
    $frac = 0
    if ($script:frameCount -gt 1) { $frac = ($script:frameIdx + 1) / $script:frameCount }
    $script:progFill.Width = [int][Math]::Max(0, [Math]::Min($w, [Math]::Round($w * $frac)))
}

$script:form.BackColor = $script:StyleCard
$script:pic.BackColor  = $script:StyleCard
$script:bar.BringToFront()
$script:progTrack.BringToFront()
$script:textBox.BringToFront()

# frame stepping state (own animation clock, so pause is real)
$script:frameDim   = [System.Drawing.Imaging.FrameDimension]::Time
$script:frameCount = 0
$script:frameIdx   = 0
$script:frameBmp   = $null
$script:frameGfx   = $null
$script:listSig    = ''
$script:delays     = @()
$script:animTimer  = New-Object System.Windows.Forms.Timer
$script:animTimer.Interval = 100
$script:animTimer.Add_Tick({ Step-Frame })

$script:form.Add_Resize({
    if ($script:form.WindowState -eq 'Minimized') {
        $script:animTimer.Stop()          # nothing visible: do not burn CPU
        return
    }
    Set-RoundedRegion -Control $script:form -Radius $script:radius
    if ($script:pic -and $script:bar) { Set-Layout }
    if (-not $script:Paused -and $script:gif -and $script:frameCount -gt 1 -and $script:form.Visible) {
        $script:animTimer.Start()
    }
})
$script:form.Add_FormClosing({ Save-Cfg; $script:animTimer.Stop(); Dispose-FrameBuffer })

# Hidden in the tray = nothing to draw: stop the frame clock so it costs literally nothing.
$script:form.Add_VisibleChanged({
    if (-not $script:animTimer) { return }
    if ($script:form.Visible) {
        if (-not $script:Paused -and $script:gif -and $script:frameCount -gt 1) { $script:animTimer.Start() }
    } else {
        $script:animTimer.Stop()
    }
})

# ------------------------------------------------------------- behaviour ----

function Resize-ToImage {
    param([int]$Width = 0)
    if (-not $script:gif) { return }
    $w = if ($Width -gt 0) { $Width } else { [int]$script:form.Width }
    if ($w -lt 80) { $w = 80 }
    $ratio = $script:gif.Width / $script:gif.Height
    $h = [int][Math]::Round($w / $ratio)
    if ($h -lt 60) { $h = 60 }
    $script:form.ClientSize = New-Object System.Drawing.Size $w, ($h + $script:progHeight + $script:barHeight)
    Set-RoundedRegion -Control $script:form -Radius $script:radius
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
    Dispose-FrameBuffer
    if ($script:gif)    { $script:gif.Dispose() }
    if ($script:stream) { $script:stream.Dispose() }

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
#
# One buffer and one Graphics are allocated per GIF and reused for every frame: the naive
# version allocated a Bitmap + Graphics per frame (20+/s of GDI objects, constant GC churn).
function New-FrameBuffer {
    Dispose-FrameBuffer
    $script:frameBmp = New-Object System.Drawing.Bitmap $script:gif.Width, $script:gif.Height
    $script:frameGfx = [System.Drawing.Graphics]::FromImage($script:frameBmp)
    $script:pic.Image = $script:frameBmp
}

function Dispose-FrameBuffer {
    if ($script:frameGfx) { try { $script:frameGfx.Dispose() } catch { }; $script:frameGfx = $null }
    if ($script:pic)      { $script:pic.Image = $null }
    if ($script:frameBmp) { try { $script:frameBmp.Dispose() } catch { }; $script:frameBmp = $null }
}

function Show-Frame {
    param([int]$Index)
    if (-not $script:gif) { return }
    if ($script:frameCount -gt 1) {
        try { $script:gif.SelectActiveFrame($script:frameDim, $Index) | Out-Null } catch { }
    }
    if (-not $script:frameGfx) { New-FrameBuffer }
    $script:frameGfx.Clear($script:pic.BackColor)
    $script:frameGfx.DrawImage($script:gif, 0, 0, $script:frameBmp.Width, $script:frameBmp.Height)
    $script:pic.Invalidate()
    Set-Progress

    $delay = 10
    if ($script:delays.Count -gt $Index) { $delay = $script:delays[$Index] }
    if ($delay -le 0) { $delay = 10 }
    $interval = [int][Math]::Max(20, $delay * 10)
    # setting Interval restarts the timer, so only touch it when the delay actually changed
    if ($script:animTimer.Interval -ne $interval) { $script:animTimer.Interval = $interval }
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
    $dlg.Filter         = 'Animated GIF (*.gif)|*.gif|Images (*.gif;*.png;*.jpg)|*.gif;*.png;*.jpg|All files (*.*)|*.*'
    $dlg.Title          = 'Add GIF(s) to the playlist'
    $dlg.Multiselect    = $true
    if ($dlg.ShowDialog() -eq 'OK') {
        $first = -1
        foreach ($f in $dlg.FileNames) {
            $i = Add-ToPlaylist -FilePath $f
            if ($first -lt 0 -and $i -ge 0) { $first = $i }
        }
        if ($first -ge 0) { Set-Current $first }
    }
    $dlg.Dispose()
}

# ------------------------------------------------------------- playlist ----

function Add-ToPlaylist {
    param([string]$FilePath)
    if (-not $FilePath) { return -1 }
    $full = $null
    try { $full = (Resolve-Path -LiteralPath $FilePath -ErrorAction Stop).Path } catch { return -1 }
    for ($i = 0; $i -lt $script:Playlist.Count; $i++) {
        if ($script:Playlist[$i] -eq $full) { return $i }   # -eq is case-insensitive, right for paths
    }
    $script:Playlist.Add($full) | Out-Null
    return ($script:Playlist.Count - 1)
}

function Set-Current {
    param([int]$Index)
    if ($script:Playlist.Count -eq 0) { return }
    $n = $script:Playlist.Count
    if ($Index -lt 0)  { $Index = $n - 1 }
    if ($Index -ge $n) { $Index = 0 }
    $script:PlayIndex = $Index
    Show-Gif -FilePath $script:Playlist[$Index]
}

function Next-Gif {
    if ($script:Playlist.Count -gt 1) { Set-Current ($script:PlayIndex + 1) }
}

function Prev-Gif {
    if ($script:Playlist.Count -gt 1) { Set-Current ($script:PlayIndex - 1) }
}

function Remove-Current {
    if ($script:Playlist.Count -eq 0) { return }
    $script:Playlist.RemoveAt($script:PlayIndex)
    if ($script:Playlist.Count -eq 0) {
        # nothing left: tear everything down properly. Nulling the fields alone leaked the
        # frame buffer's GDI object, the decoded Image and the MemoryStream.
        $script:PlayIndex  = -1
        $script:frameCount = 0
        $script:frameIdx   = 0
        $script:delays     = @()
        $script:GifPath    = $null
        $script:animTimer.Stop()
        Dispose-FrameBuffer
        if ($script:gif)    { try { $script:gif.Dispose() }    catch { }; $script:gif = $null }
        if ($script:stream) { try { $script:stream.Dispose() } catch { }; $script:stream = $null }
        Save-Cfg
        Sync-Menu
        return
    }
    if ($script:PlayIndex -ge $script:Playlist.Count) { $script:PlayIndex = 0 }
    Set-Current $script:PlayIndex
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

$script:miPrev = New-Object System.Windows.Forms.ToolStripMenuItem 'Previous  (Left)'
$script:miPrev.Add_Click({ Prev-Gif })
$script:menu.Items.Add($script:miPrev) | Out-Null

$script:miNext = New-Object System.Windows.Forms.ToolStripMenuItem 'Next  (Right)'
$script:miNext.Add_Click({ Next-Gif })
$script:menu.Items.Add($script:miNext) | Out-Null

$script:miList = New-Object System.Windows.Forms.ToolStripMenuItem 'Playlist'
$script:menu.Items.Add($script:miList) | Out-Null

$script:miRemove = New-Object System.Windows.Forms.ToolStripMenuItem 'Remove this from playlist'
$script:miRemove.Add_Click({ Remove-Current })
$script:menu.Items.Add($script:miRemove) | Out-Null

$script:miInfo = New-Object System.Windows.Forms.ToolStripMenuItem 'No GIF loaded'
$script:miInfo.Enabled = $false
$script:menu.Items.Add($script:miInfo) | Out-Null

$script:miTheme = New-Object System.Windows.Forms.ToolStripMenuItem 'Theme'
$script:miKitty = New-Object System.Windows.Forms.ToolStripMenuItem 'Hello Kitty'
$script:miKitty.Add_Click({ Set-Theme 'kitty' })
$script:miPeaks = New-Object System.Windows.Forms.ToolStripMenuItem 'Twin Peaks'
$script:miPeaks.Add_Click({ Set-Theme 'peaks' })
$script:miTheme.DropDownItems.Add($script:miKitty) | Out-Null
$script:miTheme.DropDownItems.Add($script:miPeaks) | Out-Null
$script:menu.Items.Add($script:miTheme) | Out-Null

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
        $count = $script:Playlist.Count
        $script:miPlay.Text     = if ($script:Paused) { 'Play' } else { 'Pause' }
        if ($script:btnPlay) {
            $script:btnPlay.Name = if ($script:Paused) { 'play' } else { 'pause' }   # Draw-Glyph switches on Name
            $script:btnPlay.Invalidate()
            $script:btnPlay.Enabled = [bool]$script:gif
        }
        if ($script:lblTitle) {
            $script:lblTitle.Text = if ($script:GifPath) { [System.IO.Path]::GetFileNameWithoutExtension($script:GifPath) } else { 'No GIF loaded' }
        }
        if ($script:lblSub) {
            $script:lblSub.Text = if ($count -gt 0) { "$($script:PlayIndex + 1) of $count" } else { '' }
        }
        if ($script:btnPrev) { $script:btnPrev.Enabled = ($count -gt 1) }
        if ($script:btnNext) { $script:btnNext.Enabled = ($count -gt 1) }
        $script:miPlay.Enabled  = [bool]$script:gif
        $script:miPrev.Enabled  = ($count -gt 1)
        $script:miNext.Enabled  = ($count -gt 1)
        $script:miRemove.Enabled = ($count -gt 0)
        $script:miTop.Checked   = [bool]$script:form.TopMost
        $script:miStart.Checked = Test-Path -LiteralPath (Get-StartupLink)

        $name = if ($script:GifPath) { Split-Path -Leaf $script:GifPath } else { 'No GIF loaded' }
        $script:miInfo.Text = if ($count -gt 1) { "$($script:PlayIndex + 1) of $count - $name" } else { $name }

        # rebuild the playlist submenu only when the playlist or selection actually changed
        $sig = ($script:Playlist -join '|') + "#$($script:PlayIndex)"
        if ($sig -ne $script:listSig) {
            $script:listSig = $sig
            while ($script:miList.DropDownItems.Count -gt 0) {
                $old = $script:miList.DropDownItems[0]
                $script:miList.DropDownItems.RemoveAt(0)
                $old.Dispose()
            }
            if ($count -eq 0) {
                $empty = New-Object System.Windows.Forms.ToolStripMenuItem '(empty - use Open GIF)'
                $empty.Enabled = $false
                $script:miList.DropDownItems.Add($empty) | Out-Null
            } else {
                for ($i = 0; $i -lt $count; $i++) {
                    $entry = New-Object System.Windows.Forms.ToolStripMenuItem (Split-Path -Leaf $script:Playlist[$i])
                    $entry.Checked = ($i -eq $script:PlayIndex)
                    $entry.Tag = $i
                    $entry.ToolTipText = $script:Playlist[$i]
                    $entry.Add_Click({ param($s, $e) Set-Current ([int]$s.Tag) })
                    $script:miList.DropDownItems.Add($entry) | Out-Null
                }
            }
        }

        if ($script:tray) {
            $tip = if ($script:GifPath) { "GIF Mini Player - $name" } else { 'GIF Mini Player' }
            if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
            $script:tray.Text = $tip
        }
    } finally {
        $script:syncing = $false
    }
}

# --------------------------------------------------------- tray + wiring ----

$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = Tray-Icon $script:theme
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
    if (-not $files -or $files.Count -eq 0) { return }
    $first = -1
    foreach ($f in $files) {
        $i = Add-ToPlaylist -FilePath $f
        if ($first -lt 0 -and $i -ge 0) { $first = $i }
    }
    if ($first -ge 0) { Set-Current $first }
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
        ([System.Windows.Forms.Keys]::Space)     { Toggle-Pause; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Escape)    { Hide-Window;  $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Right)     { Next-Gif;     $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Down)      { Next-Gif;     $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Next)      { Next-Gif;     $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Left)      { Prev-Gif;     $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Up)        { Prev-Gif;     $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Prior)     { Prev-Gif;     $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Delete)    { Remove-Current; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::T)         { Set-Theme $(if ($script:theme -eq 'kitty') { 'peaks' } else { 'kitty' }); $e.Handled = $true }
        ([System.Windows.Forms.Keys]::O)         { if ($e.Control) { Open-GifDialog; $e.Handled = $true } }
    }
})

# --------------------------------------------------------------- startup ----

$cfg = Get-Cfg
$savedTheme = if ($cfg.Theme) { [string]$cfg.Theme } else { 'kitty' }
Set-Theme $savedTheme -NoSave

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

$wanted = @()
if ($Path -and $Path.Count -gt 0) {
    $wanted = @($Path)
} elseif ($cfg.Paths) {
    $wanted = @($cfg.Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
} elseif ($cfg.Path -and (Test-Path -LiteralPath $cfg.Path)) {
    $wanted = @($cfg.Path)
}

foreach ($p in $wanted) { Add-ToPlaylist -FilePath $p | Out-Null }

if ($script:Playlist.Count -gt 0) {
    # GIFs named on the command line always start at the first one; only a remembered
    # playlist (no arguments) resumes where you left off.
    $startIndex = 0
    if (-not ($Path -and $Path.Count -gt 0) -and $null -ne $cfg.Index) { $startIndex = [int]$cfg.Index }
    Set-Current $startIndex
} else {
    Open-GifDialog
}

Set-RoundedRegion -Control $script:form -Radius $script:radius
Set-Layout
Sync-Menu

$script:form.Show()
$script:form.Activate()

# Publish pid + hwnd for this instance (used by the test pipeline; harmless otherwise).
try {
    $instanceFile = Join-Path $script:CfgDir ("instance-{0}.json" -f $script:instanceName)
    [ordered]@{ pid = $PID; hwnd = [int64]$script:form.Handle; title = $script:form.Text; when = (Get-Date -Format s) } |
        ConvertTo-Json | Set-Content -LiteralPath $instanceFile -Encoding UTF8
} catch { }

try {
    [System.Windows.Forms.Application]::Run($script:form)
} finally {
    $script:tray.Visible = $false
    $script:tray.Dispose()
    try {
        $instanceFile = Join-Path $script:CfgDir ("instance-{0}.json" -f $script:instanceName)
        if (Test-Path -LiteralPath $instanceFile) { Remove-Item -LiteralPath $instanceFile -Force }
    } catch { }
    if ($script:instanceMutex) {
        if ($script:haveInstance) { try { $script:instanceMutex.ReleaseMutex() } catch { } }
        $script:instanceMutex.Dispose()
    }
}
