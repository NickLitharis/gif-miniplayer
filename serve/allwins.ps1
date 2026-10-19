Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Runtime.InteropServices; using System.Text;
public class A1 {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static string All() {
    var sb = new StringBuilder();
    EnumWindows((h, p) => {
      var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
      if (t.ToString().IndexOf("GIF Mini", StringComparison.OrdinalIgnoreCase) < 0) return true;
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      RECT r; GetWindowRect(h, out r);
      uint pid; GetWindowThreadProcessId(h, out pid);
      sb.AppendFormat("pid={0} vis={1} {2}x{3} class={4} title='{5}'\r\n", pid, IsWindowVisible(h), r.Right-r.Left, r.Bottom-r.Top, c, t);
      return true;
    }, IntPtr.Zero);
    return sb.Length == 0 ? "no GIF Mini windows" : sb.ToString();
  }
}
'@
$lines = @([A1]::All())
$lines += "--- player processes ---"
foreach ($p in (Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'GifMiniPlayer|powershell' })) {
    $lines += "pid=$($p.ProcessId) name=$($p.Name) cmd=$(if ($p.CommandLine) { $p.CommandLine.Substring(0, [Math]::Min(150, $p.CommandLine.Length)) } else { '<unreadable>' })"
}
$lines | ForEach-Object { Write-Host $_ }
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=allwins.txt','POST',($lines -join "`r`n")) | Out-Null } catch {}
