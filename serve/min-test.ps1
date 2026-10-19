Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Runtime.InteropServices;
public class M1 {
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@
$lines = @()
# a borderless form, exactly like the player
$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle = 'None'
$f.ShowInTaskbar = $false
$f.Size = New-Object System.Drawing.Size 320, 367
$f.StartPosition = 'Manual'
$f.Location = New-Object System.Drawing.Point 200, 200
$f.Show()
[System.Windows.Forms.Application]::DoEvents()
$h = $f.Handle
$lines += "after Show: iconic=$([M1]::IsIconic($h)) visible=$([M1]::IsWindowVisible($h))"

$f.WindowState = 'Minimized'
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 300
[System.Windows.Forms.Application]::DoEvents()
$lines += "after WindowState=Minimized: iconic=$([M1]::IsIconic($h)) visible=$([M1]::IsWindowVisible($h)) state=$($f.WindowState)"

[void][M1]::ShowWindow($h, 6)   # SW_MINIMIZE
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 300
$lines += "after ShowWindow(SW_MINIMIZE): iconic=$([M1]::IsIconic($h)) visible=$([M1]::IsWindowVisible($h))"

[void][M1]::ShowWindow($h, 9)   # SW_RESTORE
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 300
$lines += "after SW_RESTORE: iconic=$([M1]::IsIconic($h)) visible=$([M1]::IsWindowVisible($h))"
$f.Close()
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=min-test.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
