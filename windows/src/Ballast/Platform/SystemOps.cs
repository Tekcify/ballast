using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Ballast.Platform;

internal sealed record QuitOutcome(string Name, int Requested, int StillRunning, bool Forced, bool WaitingOnYou)
{
    public string Summary
    {
        get
        {
            if (WaitingOnYou) return $"{Name} is still open. It might be asking you something.";
            if (StillRunning == 0) return Forced ? $"{Name} got force quit." : $"{Name} has left the chat.";
            return $"{Name} won't leave. {Fmt.Plural(StillRunning, "process", "processes")} still running.";
        }
    }
}

internal static class Quitter
{
    public static async Task<QuitOutcome> QuitAsync(string name, IReadOnlyList<int> pids, TimeSpan grace)
    {
        var windows = Probes.AppWindows(pids);
        foreach (var hwnd in windows) Native.PostMessage(hwnd, Native.WmClose, 0, 0);

        if (windows.Count > 0) await Task.Delay(grace);

        var remaining = pids.Where(IsAlive).ToList();
        if (remaining.Count == 0) return new QuitOutcome(name, pids.Count, 0, false, false);

        if (Probes.AppWindows(remaining).Count > 0)
            return new QuitOutcome(name, pids.Count, remaining.Count, false, true);

        foreach (var pid in remaining)
        {
            try
            {
                using var process = Process.GetProcessById(pid);
                process.Kill();
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or Win32Exception or NotSupportedException)
            {
            }
        }
        await Task.Delay(TimeSpan.FromSeconds(1));
        remaining = remaining.Where(IsAlive).ToList();
        return new QuitOutcome(name, pids.Count, remaining.Count, true, false);
    }

    private static bool IsAlive(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (Exception ex) when (ex is InvalidOperationException or Win32Exception)
        {
            return true;
        }
    }
}

internal static class StartupItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Ballast";

    public static string ExecutablePath => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Ballast.exe");

    public static string InstallFolder => Path.Combine(Probes.Folders.LocalAppData, "Programs", "Ballast");

    public static bool IsInstalledCopy => WinPath.IsInside(ExecutablePath, InstallFolder);

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string value && value.Contains(ExecutablePath, StringComparison.OrdinalIgnoreCase);
        }
    }

    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        if (enabled) key.SetValue(ValueName, $"\"{ExecutablePath}\" --background");
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}

internal sealed class StorageSystem : IStorageProbe, ICleanupFileOps
{
    private readonly ProcessSampler _sampler = new();

    public IReadOnlyDictionary<string, string> LiveDirectories()
    {
        lock (_sampler) return Probes.LiveDirectories(_sampler.Sample());
    }

    public ulong? RecycleBinSize() => Probes.RecycleBinSize();

    public bool IsLink(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return (attributes & FileAttributes.ReparsePoint) != 0;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    public void DeleteDirectory(string path) => Directory.Delete(path, recursive: true);

    public void DeleteFile(string path) => File.Delete(path);

    public void Recycle(string path)
    {
        var operation = new Native.ShFileOpStruct
        {
            Func = Native.FoDelete,
            From = path + "\0\0",
            Flags = (ushort)(Native.FofAllowUndo | Native.FofNoConfirmation | Native.FofSilent | Native.FofNoErrorUi | Native.FofWantNukeWarning),
        };
        var result = Native.SHFileOperation(ref operation);
        if (result != 0) throw new IOException($"Windows couldn't move it to the Recycle Bin (code {result}).");
        if (operation.AnyOperationsAborted != 0) throw new IOException("You kept it, so it stayed put.");
    }

    public void EmptyRecycleBin()
    {
        var result = Native.SHEmptyRecycleBin(0, null, Native.SherbNoConfirmation | Native.SherbNoProgressUi | Native.SherbNoSound);
        if (result != 0 && result != unchecked((int)0x8000FFFF)) throw new IOException($"Windows couldn't empty the Recycle Bin (code {result}).");
    }

    public IEnumerable<ContentEntry> ContentsOlderThan(string directory, TimeSpan age) =>
        DirectoryMeasure.ContentsOlderThan(directory, age, DateTime.UtcNow).ToList();

    public DiskSample? Disk() => Probes.Disk();

    IReadOnlyDictionary<string, string> ICleanupFileOps.LiveDirectories() => LiveDirectories();
}
