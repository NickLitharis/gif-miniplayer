using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("GIF Mini Player")]
[assembly: AssemblyDescription("Tiny always-on-top GIF mini player with a playlist")]
[assembly: AssemblyProduct("GIF Mini Player")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

// GifMiniPlayer launcher. Compiled with the csc.exe that ships with Windows into a single
// GifMiniPlayer.exe: the PowerShell script and the demo GIFs are embedded resources, so the
// exe needs nothing beside it.
static class Program
{
    static readonly string[] Resources = { "GifMiniPlayer.ps1", "demo-a.gif", "demo-b.gif", "README.md" };

    static string RuntimeDir()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"GifMiniPlayer\run");
    }

    static bool SameAs(Stream embedded, string path)
    {
        try
        {
            var existing = File.ReadAllBytes(path);
            var mem = new MemoryStream();
            embedded.CopyTo(mem);
            var incoming = mem.ToArray();
            if (existing.Length != incoming.Length) return false;
            for (int i = 0; i < existing.Length; i++) if (existing[i] != incoming[i]) return false;
            return true;
        }
        catch { return false; }
    }

    static void ExtractAll(string dir, out string scriptPath)
    {
        Directory.CreateDirectory(dir);
        var asm = Assembly.GetExecutingAssembly();
        scriptPath = Path.Combine(dir, "GifMiniPlayer.ps1");
        foreach (var name in Resources)
        {
            using (var stream = asm.GetManifestResourceStream(name))
            {
                if (stream == null) continue;
                var target = Path.Combine(dir, name);
                if (File.Exists(target) && SameAs(stream, target)) continue;
                try
                {
                    if (File.Exists(target)) File.Delete(target);
                    using (var outStream = File.Create(target)) stream.CopyTo(outStream);
                }
                catch { /* locked copy: keep using what is there */ }
            }
        }
    }

    [STAThread]
    static void Main(string[] args)
    {
        string dir;
        string script;
        try
        {
            dir = RuntimeDir();
            ExtractAll(dir, out script);
        }
        catch (Exception ex)
        {
            System.Windows.Forms.MessageBox.Show(
                "GifMiniPlayer could not unpack itself:\r\n\r\n" + ex.Message,
                "GIF Mini Player");
            return;
        }

        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var powershell = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");

        var quote = "\"";
        var arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " +
                        quote + script + quote;

        // extra GIF paths on the command line are passed straight through to the player
        foreach (var a in args)
        {
            if (string.IsNullOrWhiteSpace(a)) continue;
            arguments += " " + quote + a.Trim('"') + quote;
        }

        try
        {
            var psi = new ProcessStartInfo(powershell, arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = dir
            };
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            System.Windows.Forms.MessageBox.Show(
                "GifMiniPlayer could not start its runtime:\r\n\r\n" + ex.Message,
                "GIF Mini Player");
        }
    }
}
