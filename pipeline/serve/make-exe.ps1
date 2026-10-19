# make-exe.ps1 -- build GifMiniPlayer.exe inside the VM with the csc that ships with Windows.
$ErrorActionPreference = 'Stop'
$H   = 'http://192.168.103.1:8001'
$out = Join-Path $env:USERPROFILE 'Desktop\GifMiniPlayer'
function Post($n, $t) { try { (New-Object Net.WebClient).UploadString("$H/upload?name=$n", 'POST', $t) | Out-Null } catch { } }

$build = Join-Path $env:USERPROFILE 'gmp-build'
if (Test-Path $build) { Remove-Item $build -Recurse -Force }
New-Item -ItemType Directory -Force -Path $build | Out-Null
Set-Location $build

$wc = New-Object Net.WebClient
$wc.DownloadFile("$H/gif-miniplayer.zip", "$build\bundle.zip")
Expand-Archive "$build\bundle.zip" -DestinationPath $build -Force
foreach ($n in @('Launcher.cs', 'app.ico')) { $wc.DownloadFile("$H/$n", "$build\$n") }
Get-ChildItem $build -File | Unblock-File -ErrorAction SilentlyContinue
Write-Host "sources: $((Get-ChildItem $build | ForEach-Object Name) -join ', ')"

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
Write-Host "compiler: $csc"
if (-not (Test-Path $csc)) { Post 'exe-result.txt' 'NO csc.exe FOUND'; return }

$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    "/out:$build\GifMiniPlayer.exe",
    '/win32icon:app.ico',
    '/resource:GifMiniPlayer.ps1',
    '/resource:demo-a.gif',
    '/resource:demo-b.gif',
    '/resource:README.md',
    '/reference:System.dll',
    '/reference:System.Windows.Forms.dll',
    'Launcher.cs'
)
$compile = & $csc $cscArgs 2>&1 | Out-String
Write-Host "csc output: $compile"
$exe = Join-Path $build 'GifMiniPlayer.exe'
if (-not (Test-Path $exe)) { Post 'exe-result.txt' "COMPILE FAILED: $compile"; return }
$size = (Get-Item $exe).Length

# publish to the Desktop as a single file
New-Item -ItemType Directory -Force -Path $out | Out-Null
Copy-Item $exe (Join-Path $out 'GifMiniPlayer.exe') -Force
Write-Host "built $out\GifMiniPlayer.exe ($([math]::Round($size/1KB,1)) KB)"

# prove it runs: launch the exe, wait, find its window
Get-Process -Name GifMiniPlayer -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
    if ($p.CommandLine -and $p.CommandLine -match 'GifMiniPlayer\.ps1') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Seconds 2
$demoArgs = @(Get-ChildItem $out -Filter 'demo-*.gif' | Sort-Object Name | ForEach-Object FullName)
Start-Process (Join-Path $out 'GifMiniPlayer.exe') -ArgumentList $demoArgs -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 10

Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class E1 {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public static string Find() {
        string found = "";
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 100) return true;
            found = string.Format("{0}x{1} at {2},{3}", r.Right-r.Left, r.Bottom-r.Top, r.Left, r.Top);
            return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@
$win = [E1]::Find()
$proc = Get-Process -Name GifMiniPlayer -ErrorAction SilentlyContinue | Select-Object -First 1
$summary = "exe=$([math]::Round($size/1KB,1))KB exe_running=$([bool]$proc) window=$win"
Write-Host "RESULT: $summary"
Post 'exe-result.txt' $summary
