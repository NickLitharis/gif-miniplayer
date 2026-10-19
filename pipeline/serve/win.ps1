# win.ps1 -- the window helpers shared by build.ps1 and userflow.ps1.
# Dot-source it after downloading it from the guest's file server; the class is compiled once
# per test process. Keeping one copy is what stops the two tests from drifting apart
# (a duplicate DllImport in a second copy once broke every assertion in build.ps1).
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class BT {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);

    public static string WantTitle = "GIF Mini Player";

    static string Title(IntPtr h) { var t = new StringBuilder(256); GetWindowTextW(h, t, 256); return t.ToString(); }

    // The player publishes a distinctive title, and the test knows which instance it launched.
    public static IntPtr FindApp(out uint pidOut, out RECT rect, out bool vis) {
        IntPtr found = IntPtr.Zero; uint fp = 0; RECT fr = new RECT(); bool fv = false;
        EnumWindows((h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith("WindowsForms")) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (!t.ToString().StartsWith(WantTitle)) return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 100) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            found = h; fp = pid; fr = r; fv = IsWindowVisible(h); return false;
        }, IntPtr.Zero);
        pidOut = fp; rect = fr; vis = fv;
        return found;
    }
    public static IntPtr Find(string titlePrefix) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            if (!Title(h).StartsWith(titlePrefix)) return true;
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }
    public static IntPtr[] FindAll(string titlePrefix) {
        var list = new List<IntPtr>();
        EnumWindows((h, p) => { if (Title(h).StartsWith(titlePrefix)) list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    // hwnd \t class \t text \t WxH \t X,Y -- every caller parses it by these positions.
    public static string[] Children(IntPtr parent) {
        var list = new List<string>();
        EnumChildWindows(parent, (h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            RECT r; GetWindowRect(h, out r);
            list.Add(string.Format("{0}\t{1}\t{2}\t{3}x{4}\t{5},{6}", h.ToInt64(), c, t, r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top));
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    // Fill the picker's file-name box and press its Open button. Driven through the controls
    // themselves, so it does not matter which window owns the keyboard at that moment.
    public static bool PickFile(IntPtr dialog, string file) {
        IntPtr edit = IntPtr.Zero, open = IntPtr.Zero;
        EnumChildWindows(dialog, (h, p) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            if (c.ToString() == "Edit" && edit == IntPtr.Zero) edit = h;
            if (c.ToString() == "Button" && t.ToString().Replace("&", "") == "Open") open = h;
            return true;
        }, IntPtr.Zero);
        if (edit == IntPtr.Zero || open == IntPtr.Zero) return false;
        SendMessage(edit, 0x000C, IntPtr.Zero, file);   // WM_SETTEXT
        System.Threading.Thread.Sleep(150);
        SendMessage(open, 0x00F5, IntPtr.Zero, null);   // BM_CLICK
        return true;
    }
    public static bool Focus(IntPtr target) {
        IntPtr fg = GetForegroundWindow();
        uint fgT = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero);
        uint myT = GetCurrentThreadId();
        bool att = false;
        if (fgT != 0 && fgT != myT) att = AttachThreadInput(myT, fgT, true);
        BringWindowToTop(target); SetForegroundWindow(target); SetFocus(target);
        if (att) AttachThreadInput(myT, fgT, false);
        return GetForegroundWindow() == target;
    }
    public static bool Capture(IntPtr hwnd, string path, int w, int h) {
        using (var bmp = new System.Drawing.Bitmap(w, h))
        using (var g = System.Drawing.Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            bool ok = PrintWindow(hwnd, hdc, 2);
            g.ReleaseHdc(hdc);
            if (!ok) return false;
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            return true;
        }
    }
    static bool MostlyBlack(System.Drawing.Bitmap b) {
        int dark = 0, n = 0;
        for (int y = 4; y < b.Height - 4; y += 13)
            for (int x = 4; x < b.Width - 4; x += 13) {
                var p = b.GetPixel(x, y); n++;
                if (p.R < 12 && p.G < 12 && p.B < 12) dark++;
            }
        return n > 0 && dark > n * 9 / 10;
    }
    // DirectUI dialogs often come back empty from PrintWindow; if so, copy the screen pixels
    // after raising the dialog, because the VM may have another window in front of it.
    public static bool Grab(IntPtr hwnd, string path) {
        RECT r; GetWindowRect(hwnd, out r);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w < 2 || h < 2) return false;
        using (var bmp = new System.Drawing.Bitmap(w, h)) {
            using (var g = System.Drawing.Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                PrintWindow(hwnd, hdc, 0);
                g.ReleaseHdc(hdc);
            }
            if (!MostlyBlack(bmp)) { bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png); return true; }
            SetWindowPos(hwnd, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002);   // TOPMOST
            BringWindowToTop(hwnd);
            System.Threading.Thread.Sleep(500);
            using (var g = System.Drawing.Graphics.FromImage(bmp)) { g.CopyFromScreen(r.Left, r.Top, 0, 0, bmp.Size); }
            SetWindowPos(hwnd, new IntPtr(-2), 0, 0, 0, 0, 0x0001 | 0x0002);   // NOTOPMOST
            if (MostlyBlack(bmp)) return false;
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            return true;
        }
    }
    public static void ClickControl(IntPtr h) {
        if (h == IntPtr.Zero) return;
        PostMessage(h, 0x00F5, IntPtr.Zero, IntPtr.Zero);   // BM_CLICK, never blocks
        System.Threading.Thread.Sleep(150);
    }
    // WM_MOUSEWHEEL goes to the window with focus in the OS, but carrying the cursor
    // position lets us deliver it to the player directly and keep the test deterministic.
    public static void Wheel(IntPtr h, int x, int y, int delta) {
        if (h == IntPtr.Zero) return;   // SendMessage to 0 would broadcast and can hang
        int wp = (delta & 0xFFFF) << 16;
        int lp = ((y & 0xFFFF) << 16) | (x & 0xFFFF);
        PostMessage(h, 0x020A, new IntPtr(wp), new IntPtr(lp));
    }
}
'@
