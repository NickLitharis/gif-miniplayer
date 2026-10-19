Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Runtime.InteropServices; using System.Text;
public class T1 {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  public static string Titles() {
    var sb = new StringBuilder();
    EnumWindows((h, p) => {
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      if (!c.ToString().StartsWith("WindowsForms")) return true;
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      sb.AppendFormat("class={0} title=[{1}]\r\n", c, t);
      return true;
    }, IntPtr.Zero);
    return sb.ToString();
  }
}
'@
$lines = @("env GMP_INSTANCE in this shell: '$env:GMP_INSTANCE'")
$lines += "--- existing WinForms windows ---"
$lines += [T1]::Titles()
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=titlecheck.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
