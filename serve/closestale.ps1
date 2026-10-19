Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Runtime.InteropServices; using System.Text;
public class C1 {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static string CloseAll() {
    var log = new StringBuilder();
    EnumWindows((h, p) => {
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      if (!c.ToString().StartsWith("WindowsForms")) return true;
      var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
      if (t.ToString() != "GIF Mini Player") return true;
      RECT r; GetWindowRect(h, out r);
      if ((r.Right - r.Left) < 100) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      bool ok = PostMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero);   // WM_CLOSE
      log.AppendFormat("WM_CLOSE -> hwnd=0x{0:X} pid={1} ok={2}\r\n", (long)h, pid, ok);
      return true;
    }, IntPtr.Zero);
    return log.Length == 0 ? "no player windows found" : log.ToString();
  }
}
'@
$r = [C1]::CloseAll()
Start-Sleep -Seconds 3
$r2 = [C1]::CloseAll()
Write-Host $r
Write-Host "--- after ---"
Write-Host $r2
try { (New-Object Net.WebClient).UploadString('http://192.168.103.1:8001/upload?name=closestale.txt','POST',($r + "--- after ---`r`n" + $r2)) | Out-Null } catch {}
