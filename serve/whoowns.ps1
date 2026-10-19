Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Runtime.InteropServices; using System.Text;
public class O1 {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static string All() {
    var sb = new StringBuilder();
    EnumWindows((h, p) => {
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      if (!c.ToString().StartsWith("WindowsForms")) return true;
      var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
      if (t.ToString() != "GIF Mini Player") return true;
      RECT r; GetWindowRect(h, out r);
      uint pid; GetWindowThreadProcessId(h, out pid);
      sb.AppendFormat("hwnd=0x{0:X} pid={1} visible={2} alive={3} size={4}x{5}\r\n",
        (long)h, pid, IsWindowVisible(h), IsWindow(h), r.Right-r.Left, r.Bottom-r.Top);
      return true;
    }, IntPtr.Zero);
    return sb.Length == 0 ? "none" : sb.ToString();
  }
}
'@
$lines = @([O1]::All())
$lines += "--- processes named like the player ---"
foreach ($p in (Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'GifMiniPlayer|powershell' })) {
    $lines += "pid=$($p.ProcessId) name=$($p.Name) started=$($p.CreationDate)"
}
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=whoowns.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
