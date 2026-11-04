using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Ballast.Platform;

internal sealed class ProcessSampler
{
    private readonly Dictionary<(int Pid, long Created), long> _cpu = [];
    private readonly Dictionary<(int Pid, long Created), string?> _paths = [];
    private readonly Dictionary<string, string?> _descriptions = new(StringComparer.OrdinalIgnoreCase);
    private long _lastSampleTicks;

    public ulong CompressedBytes { get; private set; }

    public string? Describe(string path)
    {
        lock (_descriptions)
        {
            if (_descriptions.TryGetValue(path, out var cached)) return cached;
            string? name = null;
            try
            {
                var info = FileVersionInfo.GetVersionInfo(path);
                name = string.IsNullOrWhiteSpace(info.FileDescription) ? info.ProductName : info.FileDescription;
                if (string.IsNullOrWhiteSpace(name)) name = null;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
            {
            }
            _descriptions[path] = name?.Trim();
            return _descriptions[path];
        }
    }

    public unsafe List<RawProcess> Sample()
    {
        var size = 1 << 20;
        byte[] buffer;
        while (true)
        {
            buffer = new byte[size];
            int status, needed;
            fixed (byte* p = buffer)
            {
                status = Native.NtQuerySystemInformation(Native.SystemProcessInformation, p, size, out needed);
            }
            if (status == Native.StatusInfoLengthMismatch)
            {
                size = Math.Max(size * 2, needed + (64 << 10));
                continue;
            }
            if (status != 0) return [];
            break;
        }

        var now = Stopwatch.GetTimestamp();
        var elapsed100ns = _lastSampleTicks == 0
            ? 0
            : (now - _lastSampleTicks) * 10_000_000.0 / Stopwatch.Frequency;
        _lastSampleTicks = now;
        var cores = Math.Max(Environment.ProcessorCount, 1);

        var result = new List<RawProcess>(512);
        var seen = new HashSet<(int, long)>();
        ulong compressed = 0;

        fixed (byte* start = buffer)
        {
            var offset = 0;
            while (true)
            {
                var info = (Native.SystemProcessInfo*)(start + offset);
                var pid = (int)info->UniqueProcessId;
                var name = info->ImageName.Buffer == 0
                    ? (pid == 0 ? "Idle" : "System")
                    : new string((char*)info->ImageName.Buffer, 0, info->ImageName.Length / 2);

                if (pid != 0)
                {
                    var key = (pid, info->CreateTime);
                    seen.Add(key);
                    var cpuTime = info->UserTime + info->KernelTime;
                    double cpu = 0;
                    if (elapsed100ns > 0 && _cpu.TryGetValue(key, out var previous))
                    {
                        cpu = Math.Clamp((cpuTime - previous) / (elapsed100ns * cores) * 100, 0, 100);
                    }
                    _cpu[key] = cpuTime;

                    var privateBytes = info->WorkingSetPrivateSize > 0 ? (ulong)info->WorkingSetPrivateSize : 0;
                    var approximate = privateBytes == 0;
                    var memory = approximate ? (ulong)info->WorkingSetSize : privateBytes;

                    if (name.Equals("Memory Compression", StringComparison.OrdinalIgnoreCase))
                    {
                        compressed = (ulong)info->WorkingSetSize;
                    }

                    result.Add(new RawProcess
                    {
                        Pid = pid,
                        ParentPid = (int)info->InheritedFromUniqueProcessId,
                        ImageName = name,
                        ExecutablePath = PathFor(key),
                        MemoryBytes = memory,
                        MemoryIsApproximate = approximate,
                        CpuPercent = cpu,
                        SessionId = (int)info->SessionId,
                        StartedAt = info->CreateTime > 0 ? DateTime.FromFileTimeUtc(info->CreateTime) : DateTime.UtcNow,
                    });
                }

                if (info->NextEntryOffset == 0) break;
                offset += (int)info->NextEntryOffset;
            }
        }

        foreach (var stale in _cpu.Keys.Where(k => !seen.Contains(k)).ToArray()) _cpu.Remove(stale);
        foreach (var stale in _paths.Keys.Where(k => !seen.Contains(k)).ToArray()) _paths.Remove(stale);
        CompressedBytes = compressed;
        return result;
    }

    private unsafe string? PathFor((int Pid, long Created) key)
    {
        if (_paths.TryGetValue(key, out var cached)) return cached;
        string? path = null;
        if (key.Pid > 4)
        {
            var handle = Native.OpenProcess(Native.ProcessQueryLimitedInformation, false, key.Pid);
            if (handle != 0)
            {
                try
                {
                    var chars = stackalloc char[1024];
                    var length = 1024;
                    if (Native.QueryFullProcessImageName(handle, 0, chars, ref length))
                    {
                        path = new string(chars, 0, length);
                    }
                }
                finally
                {
                    Native.CloseHandle(handle);
                }
            }
        }
        _paths[key] = path;
        return path;
    }
}
