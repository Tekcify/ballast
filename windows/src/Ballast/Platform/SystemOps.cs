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

/// <summary>
/// Quits an app the way Windows itself asks: close its windows so it can save,
/// send Ctrl+C to console tools that have no window, and only after the grace
/// period end what is still running. Every process is checked by pid and start
/// time first, so a pid Windows has since handed to another process is never
/// touched.
/// </summary>
internal static class Quitter
{
    public static async Task<QuitOutcome> QuitAsync(string name, IReadOnlyList<ProcessRef> processes, TimeSpan grace)
    {
        var states = processes.Select(p => (Process: p, State: ProcessIdentity.Check(p))).ToList();
        var live = states.Where(s => s.State != ProcessState.Gone).Select(s => s.Process).ToList();
        var ours = states.Where(s => s.State == ProcessState.Running).Select(s => s.Process).ToList();
        if (live.Count == 0) return new QuitOutcome(name, processes.Count, 0, false, false);

        var pids = ours.Select(p => p.Pid).ToList();
        var windows = Probes.AppWindows(pids);
        foreach (var hwnd in windows) Native.PostMessage(hwnd, Native.WmClose, 0, 0);

        var windowed = Probes.WindowOwners(windows);
        var interrupted = 0;
        foreach (var process in ours.Where(p => !windowed.Contains(p.Pid)))
        {
            if (await ConsoleInterrupt.SendAsync(process.Pid)) interrupted++;
        }

        if (windows.Count > 0 || interrupted > 0) await WaitForExitAsync(live, grace);

        var remaining = live.Where(p => ProcessIdentity.Check(p) != ProcessState.Gone).ToList();
        if (remaining.Count == 0) return new QuitOutcome(name, processes.Count, 0, false, false);

        // Still showing a window usually means a "save changes?" prompt.
        if (Probes.AppWindows(remaining.Select(p => p.Pid).ToList()).Count > 0)
            return new QuitOutcome(name, processes.Count, remaining.Count, false, true);

        var forced = false;
        foreach (var process in remaining) forced |= ProcessIdentity.Terminate(process);
        if (forced) await Task.Delay(TimeSpan.FromSeconds(1));

        remaining = remaining.Where(p => ProcessIdentity.Check(p) != ProcessState.Gone).ToList();
        return new QuitOutcome(name, processes.Count, remaining.Count, forced, false);
    }

    /// <summary>Waits out the grace period, or less if everything has already exited.</summary>
    private static async Task WaitForExitAsync(IReadOnlyList<ProcessRef> processes, TimeSpan grace)
    {
        var deadline = DateTime.UtcNow + grace;
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(250);
            if (processes.All(p => ProcessIdentity.Check(p) == ProcessState.Gone)) return;
        }
    }
}

internal enum ProcessState
{
    /// <summary>Exited, or its pid now belongs to a different process.</summary>
    Gone,
    /// <summary>The same process, and Ballast may act on it.</summary>
    Running,
    /// <summary>Running, but Windows will not let Ballast open it.</summary>
    Untouchable,
}

internal static class ProcessIdentity
{
    /// <summary>The identity of a running process, for callers that only have a pid.</summary>
    public static ProcessRef? Of(int pid)
    {
        var handle = Native.OpenProcess(Native.ProcessQueryLimitedInformation, false, pid);
        if (handle == 0) return null;
        try
        {
            return IsRunning(handle) && Native.GetProcessTimes(handle, out var created, out _, out _, out _)
                ? new ProcessRef(pid, DateTime.FromFileTimeUtc(created))
                : null;
        }
        finally
        {
            Native.CloseHandle(handle);
        }
    }

    public static ProcessState Check(ProcessRef process)
    {
        var handle = Native.OpenProcess(Native.ProcessQueryLimitedInformation, false, process.Pid);
        if (handle == 0)
        {
            return Marshal.GetLastWin32Error() == Native.ErrorInvalidParameter
                ? ProcessState.Gone
                : ProcessState.Untouchable;
        }
        try
        {
            return Matches(handle, process) ? ProcessState.Running : ProcessState.Gone;
        }
        finally
        {
            Native.CloseHandle(handle);
        }
    }

    /// <summary>
    /// Ends the process, re-checking its identity through the same handle that
    /// terminates it, so the pid cannot change hands in between.
    /// </summary>
    public static bool Terminate(ProcessRef process)
    {
        var handle = Native.OpenProcess(Native.ProcessTerminate | Native.ProcessQueryLimitedInformation, false, process.Pid);
        if (handle == 0) return false;
        try
        {
            return Matches(handle, process) && Native.TerminateProcess(handle, 1);
        }
        finally
        {
            Native.CloseHandle(handle);
        }
    }

    private static bool Matches(nint handle, ProcessRef process) =>
        IsRunning(handle)
        && Native.GetProcessTimes(handle, out var created, out _, out _, out _)
        && DateTime.FromFileTimeUtc(created) == process.StartedAtUtc;

    private static bool IsRunning(nint handle) =>
        Native.GetExitCodeProcess(handle, out var code) && code == Native.StillActive;
}

/// <summary>
/// Sends Ctrl+C to the console a process runs in, the same as pressing it in
/// that terminal, so tools like dev servers can shut down cleanly. A process
/// can only signal a console it is attached to, so a short-lived copy of
/// Ballast attaches and sends it, which keeps this process's own console
/// untouched. Everything attached to that console receives it.
/// </summary>
internal static class ConsoleInterrupt
{
    public const string Flag = "--interrupt";

    public static async Task<bool> SendAsync(int pid)
    {
        try
        {
            var start = new ProcessStartInfo(StartupItem.ExecutablePath, $"{Flag} {pid}")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var helper = Process.Start(start);
            if (helper is null) return false;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await helper.WaitForExitAsync(timeout.Token);
            return helper.ExitCode == 0;
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or OperationCanceledException)
        {
            return false;
        }
    }

    /// <summary>Runs in the helper copy. Exit code 0 means Ctrl+C was sent.</summary>
    public static int RunHelper(string[] args)
    {
        var index = Array.IndexOf(args, Flag);
        if (index < 0 || index + 1 >= args.Length || !int.TryParse(args[index + 1], out var pid)) return 2;

        Native.FreeConsole();
        if (!Native.AttachConsole(pid)) return 1;
        // Ignore the Ctrl+C ourselves, then send it to everything on that console.
        Native.SetConsoleCtrlHandler(0, true);
        var sent = Native.GenerateConsoleCtrlEvent(Native.CtrlCEvent, 0);
        Native.FreeConsole();
        return sent ? 0 : 1;
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
