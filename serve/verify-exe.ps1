# verify-exe.ps1 -- prove GifMiniPlayer.exe works as a single file in an empty folder.
$ErrorActionPreference = 'Continue'
$H = 'http://192.168.103.1:8001'
function Post($n,$t){ try { (New-Object Net.WebClient).UploadString("$H/upload?name=$n",'POST',$t) | Out-Null } catch {} }
$lines = @()

$built = Join-Path $env:USERPROFILE 'Desktop\GifMiniPlayer\GifMiniPlayer.exe'
$solo  = Join-Path $env:USERPROFILE 'Desktop\gmp-solo'
if (Test-Path $solo) { Remove-Item $solo -Recurse -Force }
New-Item -ItemType Directory -Force -Path $solo | Out-Null
Copy-Item $built $solo -Force
$lines += "solo folder contains: $((Get-ChildItem $solo | ForEach-Object Name) -join ', ')"
$lines += "exe size: $([math]::Round((Get-Item (Join-Path $solo 'GifMiniPlayer.exe')).Length/1KB,1)) KB"
$lines += "exe version info: $((Get-Item (Join-Path $solo 'GifMiniPlayer.exe')).VersionInfo.FileDescription)"

# kill anything already running
Get-Process -Name GifMiniPlayer -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
    if ($p.CommandLine -and $p.CommandLine -match 'GifMiniPlayer\.ps1') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Seconds 2

# run it from the empty folder, with NO arguments
Start-Process (Join-Path $solo 'GifMiniPlayer.exe') -WorkingDirectory $solo | Out-Null
Start-Sleep -Seconds 12

Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class E2 {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    public static string Report(out int buttons) {
        string found = ""; int nb = 0;
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (t.ToString() != "GIF Mini Player") return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 100) return true;
            found = string.Format("{0}x{1} at {2},{3}", r.Right-r.Left, r.Bottom-r.Top, r.Left, r.Top);
            EnumChildWindows(h, (ch, cp) => {
                var cc = new StringBuilder(256); GetClassNameW(ch, cc, 256);
                if (cc.ToString().Contains("BUTTON")) nb++;
                return true;
            }, IntPtr.Zero);
            return false;
        }, IntPtr.Zero);
        buttons = nb; return found;
    }
}
'@
$nb = 0
$win = [E2]::Report([ref]$nb)
$runtime = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'GifMiniPlayer\.ps1' }
$lines += "window: $win"
$lines += "buttons found: $nb"
$lines += "runtime processes: $(@($runtime).Count)"
$lines += "runtime script path: $((@($runtime)[0].CommandLine -split '-File ')[-1])"
$verdict = if ($win -and $nb -eq 5) { 'EXE OK' } else { 'EXE FAILED' }
$lines += "VERDICT: $verdict"
$lines | ForEach-Object { Write-Host $_ }
Post 'exe-verify.txt' ($lines -join "`r`n")
