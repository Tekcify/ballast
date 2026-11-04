using System.Runtime.InteropServices;

namespace Ballast.Platform;

internal static class Probes
{
    private static readonly nint LowMemoryHandle =
        Native.CreateMemoryResourceNotification(Native.MemoryResourceNotificationType.Low);

    public static string Home { get; } = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public static KnownFolders Folders { get; } = new(
        Home,
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        WinPath.Normalize(Path.GetTempPath()));

    public static string DataFolder { get; } = Path.Combine(Folders.LocalAppData, "Ballast");

    public static MemorySample? Memory(ulong compressedBytes)
    {
        var status = new Native.MemoryStatusEx { Length = (uint)Marshal.SizeOf<Native.MemoryStatusEx>() };
        if (!Native.GlobalMemoryStatusEx(ref status)) return null;

        ulong commit = 0, limit = 0, cache = 0, kernel = 0;
        if (Native.GetPerformanceInfo(out var perf, (uint)Marshal.SizeOf<Native.PerformanceInformation>()))
        {
            var page = (ulong)perf.PageSize;
            commit = (ulong)perf.CommitTotal * page;
            limit = (ulong)perf.CommitLimit * page;
            cache = (ulong)perf.SystemCache * page;
            kernel = (ulong)perf.KernelNonpaged * page;
        }

        var low = LowMemoryHandle != 0 && Native.QueryMemoryResourceNotification(LowMemoryHandle, out var state) && state != 0;

        return new MemorySample
        {
            TotalBytes = status.TotalPhys,
            AvailableBytes = status.AvailPhys,
            CommitBytes = commit,
            CommitLimitBytes = limit,
            CachedBytes = cache,
            KernelBytes = kernel,
            CompressedBytes = compressedBytes,
            LowMemorySignaled = low,
        };
    }

    public static DiskSample? Disk()
    {
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Home) ?? "C:\\");
            return new DiskSample((ulong)drive.TotalSize, (ulong)drive.AvailableFreeSpace);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }

    public static Dictionary<int, WindowPresence> Windows(out int? foregroundPid)
    {
        var map = new Dictionary<int, WindowPresence>();
        Native.EnumWindowsProc callback = (hwnd, _) =>
        {
            if (!IsAppWindow(hwnd)) return true;
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            var minimized = Native.IsIconic(hwnd);
            map[pid] = map.TryGetValue(pid, out var existing)
                ? new WindowPresence(true, existing.AllMinimized && minimized)
                : new WindowPresence(true, minimized);
            return true;
        };
        Native.EnumWindows(callback, 0);
        GC.KeepAlive(callback);

        var foreground = Native.GetForegroundWindow();
        foregroundPid = null;
        if (foreground != 0 && Native.GetWindowThreadProcessId(foreground, out var fg) != 0) foregroundPid = fg;
        return map;
    }

    public static List<nint> AppWindows(IReadOnlyCollection<int> pids)
    {
        var set = pids.ToHashSet();
        var windows = new List<nint>();
        Native.EnumWindowsProc callback = (hwnd, _) =>
        {
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            if (set.Contains(pid) && IsAppWindow(hwnd)) windows.Add(hwnd);
            return true;
        };
        Native.EnumWindows(callback, 0);
        GC.KeepAlive(callback);
        return windows;
    }

    private static bool IsAppWindow(nint hwnd)
    {
        if (!Native.IsWindowVisible(hwnd)) return false;
        if (Native.GetWindow(hwnd, Native.GwOwner) != 0) return false;
        var exStyle = (long)Native.GetWindowLongPtr(hwnd, Native.GwlExStyle);
        if ((exStyle & Native.WsExToolWindow) != 0 && (exStyle & Native.WsExAppWindow) == 0) return false;
        if (Native.DwmGetWindowAttribute(hwnd, Native.DwmwaCloaked, out var cloaked, sizeof(int)) == 0 && cloaked != 0)
            return false;
        return Native.GetWindowTextLength(hwnd) > 0;
    }

    public static ulong? RecycleBinSize()
    {
        var info = new Native.ShQueryRbInfo { Size = (uint)Marshal.SizeOf<Native.ShQueryRbInfo>() };
        return Native.SHQueryRecycleBin(null, ref info) == 0 ? (ulong)Math.Max(info.SizeBytes, 0) : null;
    }

    public static unsafe Dictionary<string, string> LiveDirectories(IEnumerable<RawProcess> processes)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var session = System.Diagnostics.Process.GetCurrentProcess().SessionId;
        var self = Environment.ProcessId;

        foreach (var process in processes)
        {
            if (process.SessionId != session || process.Pid == self || process.Pid <= 4) continue;
            var cwd = WorkingDirectory(process.Pid);
            if (cwd is null || !WinPath.IsInside(cwd, Home)) continue;
            map[WinPath.Normalize(cwd)] = Grouping.StemOf(process.ImageName);
        }
        return map;
    }

    private static unsafe string? WorkingDirectory(int pid)
    {
        var handle = Native.OpenProcess(Native.ProcessQueryInformation | Native.ProcessVmRead, false, pid);
        if (handle == 0) return null;
        try
        {
            if (Native.NtQueryInformationProcess(handle, 0, out var basic, Marshal.SizeOf<Native.ProcessBasicInformation>(), out _) != 0)
                return null;
            if (basic.PebBaseAddress == 0) return null;

            nint parameters;
            if (!Native.ReadProcessMemory(handle, basic.PebBaseAddress + 0x20, &parameters, IntPtr.Size, out _) || parameters == 0)
                return null;

            Native.UnicodeString dosPath;
            if (!Native.ReadProcessMemory(handle, parameters + 0x38, &dosPath, sizeof(Native.UnicodeString), out _))
                return null;
            if (dosPath.Length == 0 || dosPath.Length > 32_000 || dosPath.Buffer == 0) return null;

            var chars = new char[dosPath.Length / 2];
            fixed (char* buffer = chars)
            {
                if (!Native.ReadProcessMemory(handle, dosPath.Buffer, buffer, dosPath.Length, out _)) return null;
            }
            return WinPath.Normalize(new string(chars));
        }
        finally
        {
            Native.CloseHandle(handle);
        }
    }
}
