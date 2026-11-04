namespace Ballast.Core;

public sealed record RawProcess
{
    public int Pid { get; init; }
    public int ParentPid { get; init; }
    public required string ImageName { get; init; }
    public string? ExecutablePath { get; init; }
    public ulong MemoryBytes { get; init; }
    public bool MemoryIsApproximate { get; init; }
    public double CpuPercent { get; init; }
    public int SessionId { get; init; }
    public DateTime StartedAt { get; init; }
}

public readonly record struct WindowPresence(bool HasWindow, bool AllMinimized);

public sealed record AppGroup
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string ProcessName { get; init; }
    public string? ExecutablePath { get; init; }
    public IReadOnlyList<int> Pids { get; init; } = [];
    public ulong MemoryBytes { get; init; }
    public double CpuPercent { get; init; }
    public bool IsApproximate { get; init; }
    public bool IsSystemOwned { get; init; }
    public bool IsRunningApp { get; init; }
    public bool IsFrontmost { get; init; }
    public bool IsHidden { get; init; }
    public DateTime StartedAt { get; init; }

    public int ProcessCount => Pids.Count;

    public bool CanQuit => ExecutablePath is not null && !Grouping.IsEssential(this);
}

public static class Grouping
{
    private static readonly StringComparer NameComparer = StringComparer.OrdinalIgnoreCase;

    public static readonly IReadOnlySet<string> Essential = new HashSet<string>(NameComparer)
    {
        "System", "Idle", "Registry", "Secure System", "Memory Compression", "smss", "csrss",
        "wininit", "winlogon", "services", "lsass", "LsaIso", "svchost", "fontdrvhost", "dwm",
        "explorer", "sihost", "ctfmon", "taskhostw", "RuntimeBroker", "SearchHost", "SearchIndexer",
        "StartMenuExperienceHost", "ShellExperienceHost", "ShellHost", "TextInputHost", "MsMpEng",
        "NisSrv", "SecurityHealthService", "SecurityHealthSystray", "spoolsv", "audiodg", "conhost",
        "dllhost", "WmiPrvSE", "WUDFHost", "SgrmBroker", "LockApp", "Widgets", "WidgetService",
        "smartscreen", "UserOOBEBroker", "ApplicationFrameHost", "SystemSettings", "Ballast",
    };

    public static readonly IReadOnlySet<string> HoldsLiveState = new HashSet<string>(NameComparer)
    {
        "vmmem", "vmmemWSL", "vmwp", "vmware-vmx", "VirtualBoxVM", "VBoxHeadless", "qemu-system-x86_64",
        "qemu-system-aarch64", "Docker Desktop", "com.docker.backend", "com.docker.build", "wslservice",
    };

    public static readonly IReadOnlySet<string> Transient = new HashSet<string>(NameComparer)
    {
        "SearchProtocolHost", "SearchFilterHost", "TiWorker", "TrustedInstaller", "MoUsoCoreWorker",
        "CompatTelRunner", "msiexec", "clangd", "cl", "link", "MSBuild", "VBCSCompiler",
    };

    public static string WindowsDirectory { get; set; } = @"C:\Windows";

    public static bool IsEssential(AppGroup group) =>
        Essential.Contains(group.ProcessName) || IsUnderWindows(group.ExecutablePath);

    public static bool IsUnderWindows(string? path) =>
        path is not null && WinPath.IsInside(path, WindowsDirectory);

    public static string StemOf(string imageName) =>
        imageName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? imageName[..^4] : imageName;

    public static IReadOnlyList<AppGroup> Build(
        IEnumerable<RawProcess> processes,
        IReadOnlyDictionary<int, WindowPresence> windows,
        int? foregroundPid,
        Func<string, string?> describe,
        DateTime now)
    {
        var buckets = new Dictionary<string, Bucket>(StringComparer.OrdinalIgnoreCase);

        foreach (var process in processes)
        {
            if (process.MemoryBytes == 0) continue;
            var key = process.ExecutablePath ?? process.ImageName;
            if (!buckets.TryGetValue(key, out var bucket))
            {
                bucket = new Bucket(StemOf(process.ImageName), process.ExecutablePath);
                buckets[key] = bucket;
            }

            bucket.Pids.Add(process.Pid);
            bucket.Memory += process.MemoryBytes;
            bucket.Cpu += process.CpuPercent;
            bucket.Approximate |= process.MemoryIsApproximate;
            bucket.SystemOwned |= process.SessionId == 0 || process.ExecutablePath is null
                || IsUnderWindows(process.ExecutablePath);
            if (process.StartedAt < bucket.Started) bucket.Started = process.StartedAt;

            if (windows.TryGetValue(process.Pid, out var presence) && presence.HasWindow)
            {
                bucket.HasWindow = true;
                bucket.AllMinimized &= presence.AllMinimized;
            }
            if (foregroundPid == process.Pid) bucket.Frontmost = true;
        }

        return buckets
            .Select(pair =>
            {
                var b = pair.Value;
                var described = b.Path is null ? null : describe(b.Path);
                return new AppGroup
                {
                    Id = pair.Key.ToLowerInvariant(),
                    Name = string.IsNullOrWhiteSpace(described) ? b.Stem : described!,
                    ProcessName = b.Stem,
                    ExecutablePath = b.Path,
                    Pids = b.Pids.OrderBy(p => p).ToArray(),
                    MemoryBytes = b.Memory,
                    CpuPercent = b.Cpu,
                    IsApproximate = b.Approximate,
                    IsSystemOwned = b.SystemOwned,
                    IsRunningApp = b.HasWindow,
                    IsFrontmost = b.Frontmost,
                    IsHidden = b.HasWindow && b.AllMinimized,
                    StartedAt = b.Started == DateTime.MaxValue ? now : b.Started,
                };
            })
            .OrderByDescending(g => g.MemoryBytes)
            .ToArray();
    }

    private sealed class Bucket(string stem, string? path)
    {
        public string Stem { get; } = stem;
        public string? Path { get; } = path;
        public List<int> Pids { get; } = [];
        public ulong Memory;
        public double Cpu;
        public bool Approximate;
        public bool SystemOwned;
        public bool HasWindow;
        public bool AllMinimized = true;
        public bool Frontmost;
        public DateTime Started = DateTime.MaxValue;
    }
}
