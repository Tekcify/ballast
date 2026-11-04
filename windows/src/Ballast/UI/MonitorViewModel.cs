using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Ballast.Platform;

namespace Ballast.UI;

public enum Pane
{
    Memory,
    Storage,
    Settings,
}

public sealed record LegendItem(Brush Brush, string Label, string Value);

public sealed class AdviceItem : Observable
{
    private Advice _advice = null!;

    public AdviceItem(Advice advice, Action<Advice> act)
    {
        Act = new Command(() => act(_advice));
        Update(advice);
    }

    public string Id => _advice.Id;
    public string Headline => _advice.Headline;
    public string Detail => _advice.Detail;
    public Brush SeverityBrush => Palette.Severity(_advice.Severity);
    public bool HasAction => _advice.Kind != AdviceKind.None;
    public string ActionText => _advice.Kind == AdviceKind.OpenStorage ? "Storage" : "Quit";
    public Brush ActionBrush => _advice.Kind == AdviceKind.OpenStorage ? Palette.AppMemory : Palette.Critical;
    public Brush ActionFill => Palette.Tint((SolidColorBrush)ActionBrush, 0x24);
    public Command Act { get; }

    public void Update(Advice advice)
    {
        _advice = advice;
        Raise(string.Empty);
    }
}

public sealed class GroupItem : Observable
{
    private AppGroup _group = null!;

    public GroupItem(AppGroup group, Action<AppGroup> quit)
    {
        Quit = new Command(() => quit(_group));
        Update(group);
    }

    public string Id => _group.Id;
    public string Name => _group.Name;
    public ImageSource? Icon => IconCache.For(_group.ExecutablePath);
    public bool CanQuit => _group.CanQuit;
    public bool IsSystem => Grouping.IsEssential(_group);
    public string MemoryText => Fmt.Bytes(_group.MemoryBytes);
    public bool ShowCpu => _group.CpuPercent >= 15;
    public string CpuText => $"{_group.CpuPercent:0}% CPU";
    public Brush CpuBrush => _group.CpuPercent >= 90 ? Palette.Warning : Palette.Neutral;
    public Command Quit { get; }

    public string? Subtitle
    {
        get
        {
            var parts = new List<string>();
            if (_group.ProcessCount > 1) parts.Add(Fmt.Plural(_group.ProcessCount, "process", "processes"));
            if (_group.IsApproximate) parts.Add("working set");
            return parts.Count == 0 ? null : string.Join(" · ", parts);
        }
    }

    public void Update(AppGroup group)
    {
        _group = group;
        Raise(string.Empty);
    }
}

public static class IconCache
{
    private static readonly Dictionary<string, ImageSource?> Cache = new(StringComparer.OrdinalIgnoreCase);

    public static ImageSource? For(string? path)
    {
        if (path is null) return null;
        if (Cache.TryGetValue(path, out var cached)) return cached;
        ImageSource? image = null;
        try
        {
            using var icon = System.Drawing.Icon.ExtractAssociatedIcon(path);
            if (icon is not null)
            {
                var source = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                source.Freeze();
                image = source;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or System.ComponentModel.Win32Exception)
        {
        }
        Cache[path] = image;
        return image;
    }
}

public sealed class MonitorViewModel : Observable
{
    private const ulong ListFloor = 50UL << 20;

    private readonly ProcessSampler _sampler = new();
    private readonly GrowthTracker _growth = new();
    private readonly Dictionary<string, DateTime> _lastActive = [];
    private readonly HeadsUpPolicy _policy = new();
    private readonly DispatcherTimer _timer;
    private bool _sampling;

    private MemorySample? _memory;
    private DiskSample? _disk;
    private IReadOnlyList<AppGroup> _groups = [];
    private IReadOnlyList<MeterSegment> _segments = [];
    private IReadOnlyList<LegendItem> _legend = [];
    private string _lastSampledText = "";
    private string? _quitStatus;
    private Pressure? _pressureOverride;

    public MonitorViewModel(Settings settings)
    {
        Settings = settings;
        Grouping.WindowsDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        Storage = new StorageViewModel(this);
        Preferences = new SettingsViewModel(this);
        _policy.Cooldown = TimeSpan.FromMinutes(settings.CooldownMinutes);
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Math.Max(settings.RefreshSeconds, 1)) };
        _timer.Tick += async (_, _) => await SampleAsync();
    }

    public Settings Settings { get; }
    public StorageViewModel Storage { get; }
    public SettingsViewModel Preferences { get; }

    public ObservableCollection<AdviceItem> Advice { get; } = [];
    public ObservableCollection<GroupItem> Groups { get; } = [];

    public event Action<Pane>? OpenPaneRequested;
    public event Action<HeadsUpDecision>? HeadsUpRequested;
    public event Action? Sampled;

    public Func<bool> IsHeadsUpVisible { get; set; } = () => false;

    public MemorySample? Memory => _memory;
    public DiskSample? Disk => _disk;
    public IReadOnlyList<AppGroup> AllGroups => _groups;
    public Pressure Pressure => _pressureOverride ?? _memory?.Pressure ?? Pressure.Normal;
    public string PressureLabel => Pressure.Label();
    public Brush PressureBrush => Palette.Pressure(Pressure);
    public bool IsStrained => Pressure > Pressure.Normal;
    public bool HasMemory => _memory is not null;
    public string UsedText => _memory is null ? "" : Fmt.Bytes(_memory.UsedBytes);
    public string OfText => _memory is null ? "" : $"of {Fmt.Bytes(_memory.TotalBytes)} in use";
    public string CommitText => _memory is null ? "" : $"Committed {Fmt.Bytes(_memory.CommitBytes)} of {Fmt.Bytes(_memory.CommitLimitBytes)}";
    public IReadOnlyList<MeterSegment> Segments => _segments;
    public IReadOnlyList<LegendItem> Legend => _legend;
    public bool HasAdvice => Advice.Count > 0;
    public string ListedText => $"{Groups.Count} over 50 MB";
    public string LastSampledText => _lastSampledText;
    public double UsedFraction => _memory?.UsedFraction ?? 0;

    public string? QuitStatus
    {
        get => _quitStatus;
        private set => Set(ref _quitStatus, value);
    }

    public string Tooltip => _memory is null
        ? "Ballast"
        : $"Ballast · {Fmt.Percent(_memory.UsedFraction)} memory in use · {PressureLabel}";

    public void Start()
    {
        _timer.Start();
        _ = SampleAsync();
    }

    public void ApplyRefreshInterval() => _timer.Interval = TimeSpan.FromSeconds(Math.Max(Settings.RefreshSeconds, 1));

    public void FakePressure(Pressure? pressure)
    {
        _pressureOverride = pressure;
        Raise(string.Empty);
    }

    public void RequestPane(Pane pane) => OpenPaneRequested?.Invoke(pane);

    public void Snooze(TimeSpan duration) => _policy.Snooze(duration, DateTime.UtcNow);

    public void HeadsUpDismissed() => _policy.Dismissed(Pressure, DateTime.UtcNow);

    public async Task SampleAsync()
    {
        if (_sampling) return;
        _sampling = true;
        try
        {
            var snapshot = await Task.Run(() =>
            {
                var now = DateTime.UtcNow;
                var processes = _sampler.Sample();
                var windows = Probes.Windows(out var foreground);
                var groups = Grouping.Build(processes, windows, foreground, _sampler.Describe, now);
                return (Memory: Probes.Memory(_sampler.CompressedBytes), Disk: Probes.Disk(), Groups: groups, At: now);
            });
            Apply(snapshot.Memory, snapshot.Disk, snapshot.Groups, snapshot.At);
        }
        finally
        {
            _sampling = false;
        }
    }

    private void Apply(MemorySample? memory, DiskSample? disk, IReadOnlyList<AppGroup> groups, DateTime now)
    {
        _memory = memory;
        _disk = disk;
        _groups = groups;
        _growth.Record(groups, now);

        var front = groups.FirstOrDefault(g => g.IsFrontmost && g.ProcessName != "Ballast");
        if (front is not null) _lastActive[front.Id] = now;

        if (memory is not null)
        {
            var total = (double)Math.Max(memory.TotalBytes, 1);
            _segments =
            [
                new(Palette.AppMemory, memory.AppBytes / total),
                new(Palette.Wired, memory.KernelBytes / total),
                new(Palette.Compressed, memory.CompressedBytes / total),
                new(Palette.Cached, memory.VisibleCachedBytes / total),
            ];
            _legend =
            [
                new(Palette.AppMemory, "Apps", Fmt.Bytes(memory.AppBytes)),
                new(Palette.Wired, "Kernel", Fmt.Bytes(memory.KernelBytes)),
                new(Palette.Compressed, "Compressed", Fmt.Bytes(memory.CompressedBytes)),
                new(Palette.Cached, "Cached", Fmt.Bytes(memory.VisibleCachedBytes)),
            ];

            var effective = _pressureOverride is { } forced
                ? memory with { AvailableBytes = forced == Pressure.Critical ? memory.TotalBytes / 50 : memory.TotalBytes / 10 }
                : memory;

            var advice = Advisor.Advise(new AdvisorInput
            {
                Memory = effective,
                Disk = disk,
                Groups = groups,
                Growth = _growth,
                LastActive = _lastActive,
                ReclaimableStorage = Storage.Reclaimable,
            }, Settings, now);

            CollectionSync.Sync(Advice, advice, a => a.Id, vm => vm.Id, a => new AdviceItem(a, Act), (vm, a) => vm.Update(a));
        }

        var listed = groups.Where(g => g.MemoryBytes >= ListFloor).Take(40).ToList();
        CollectionSync.Sync(Groups, listed, g => g.Id, vm => vm.Id, g => new GroupItem(g, QuitGroup), (vm, g) => vm.Update(g));

        _lastSampledText = DateTime.Now.ToShortTimeString();
        Raise(string.Empty);
        Sampled?.Invoke();

        if (Settings.HeadsUpEnabled && memory is not null)
        {
            var decision = _policy.Observe(Pressure, IsHeadsUpVisible(), now);
            if (decision != HeadsUpDecision.None) HeadsUpRequested?.Invoke(decision);
        }
    }

    private void Act(Advice advice)
    {
        switch (advice.Kind)
        {
            case AdviceKind.Quit:
                _ = QuitAsync(advice.QuitName ?? "That app", advice.QuitPids);
                break;
            case AdviceKind.OpenStorage:
                RequestPane(Pane.Storage);
                break;
        }
    }

    private void QuitGroup(AppGroup group) => _ = QuitAsync(group.Name, group.Pids);

    public async Task QuitAsync(string name, IReadOnlyList<int> pids)
    {
        QuitStatus = $"Asking {name} to quit…";
        var outcome = await Quitter.QuitAsync(name, pids, TimeSpan.FromSeconds(6));
        QuitStatus = outcome.Summary;
        await SampleAsync();
    }
}
