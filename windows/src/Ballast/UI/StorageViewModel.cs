using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using Ballast.Platform;

namespace Ballast.UI;

public sealed class StorageRow : Observable
{
    private readonly StorageViewModel _owner;
    private bool _isPicked;

    public StorageRow(StorageViewModel owner, CleanupItem item, bool picked, ulong largest)
    {
        _owner = owner;
        Item = item;
        _isPicked = picked;
        Fraction = largest == 0 ? 0 : (double)item.SizeBytes / largest;
    }

    public CleanupItem Item { get; }
    public string Id => Item.Path;
    public string Title => Item.Title;
    public string RiskLabel => Item.Risk.Label();
    public Brush RiskBrush => Palette.Risk(Item.Risk);
    public Brush RiskFill => Palette.Tint(Palette.Risk(Item.Risk), 0x26);
    public string SizeText => Fmt.Bytes(Item.SizeBytes);
    public double Fraction { get; }
    public IReadOnlyList<MeterSegment> Bar => [new(RiskBrush, Fraction)];
    public bool IsSelectable => Item.IsSelectable;
    public string Reason => Item.HeldBy is { } holder ? $"{holder} is using this rn, so hands off." : Item.Reason;
    public Brush? ReasonBrush => Item.IsProtected ? Palette.Warning : null;
    public bool IsHeld => Item.IsProtected;
    public string Path => Item.IsRecycleBin ? "Recycle Bin on every drive" : Item.Path;

    public string Meta
    {
        get
        {
            var now = DateTime.UtcNow;
            var parts = new List<string> { Item.Category };
            if (Item.IsBusy(now)) parts.Add("busy rn, skipped by smart pick");
            else if (Item.Idle(now) is { } idle && idle >= TimeSpan.FromDays(1)) parts.Add($"untouched for {Fmt.Duration(idle)}");
            return string.Join(" · ", parts);
        }
    }

    public bool IsPicked
    {
        get => _isPicked;
        set
        {
            if (!IsSelectable) value = false;
            if (Set(ref _isPicked, value)) _owner.PickChanged(this);
        }
    }
}

public sealed class StorageViewModel : Observable
{
    private readonly MonitorViewModel _monitor;
    private readonly StorageSystem _system = new();
    private readonly List<CleanupItem> _items = [];
    private readonly HashSet<string> _picked = new(StringComparer.OrdinalIgnoreCase);
    private CancellationTokenSource? _cts;
    private bool _isScanning;
    private bool _isCleaning;
    private bool _confirming;
    private string _progressText = "";
    private string? _resultText;
    private DateTime? _scanStartedAt;
    private TimeSpan? _lastScanTook;
    private bool _fromCache;

    public StorageViewModel(MonitorViewModel monitor)
    {
        _monitor = monitor;
        Scan = new Command(() => { if (IsScanning) StopScan(); else _ = ScanAsync(); });
        SmartPick = new Command(ApplySmartPick, _ => !IsBusy && _items.Count > 0);
        ClearPicks = new Command(() => { _picked.Clear(); Refresh(); }, _ => !IsBusy && _picked.Count > 0);
        Clean = new Command(() => Confirming = true, _ => !IsBusy && PickedBytes > 0);
        Confirm = new Command(() => _ = CleanAsync(), _ => !IsBusy && PickedBytes > 0);
        Cancel = new Command(() => Confirming = false);
        OpenLog = new Command(() =>
        {
            if (File.Exists(LogPath)) Process.Start(new ProcessStartInfo(LogPath) { UseShellExecute = true });
        });

        var cached = ScanCache.Load(CachePath, Directory.Exists);
        if (cached.Count > 0)
        {
            _items.AddRange(cached);
            _fromCache = true;
            foreach (var item in cached.Where(i => i.IsDefaultPick(DateTime.UtcNow))) _picked.Add(item.Path);
        }
        Refresh();
    }

    public static string CachePath => System.IO.Path.Combine(Probes.DataFolder, "last-scan.json");
    public static string LogPath => System.IO.Path.Combine(Probes.DataFolder, "cleanup-log.jsonl");

    public ObservableCollection<StorageRow> Rows { get; } = [];

    public Command Scan { get; }
    public Command SmartPick { get; }
    public Command ClearPicks { get; }
    public Command Clean { get; }
    public Command Confirm { get; }
    public Command Cancel { get; }
    public Command OpenLog { get; }

    public bool IsScanning
    {
        get => _isScanning;
        private set { if (Set(ref _isScanning, value)) Raise(string.Empty); }
    }

    public bool IsCleaning
    {
        get => _isCleaning;
        private set { if (Set(ref _isCleaning, value)) Raise(string.Empty); }
    }

    public bool IsBusy => IsScanning || IsCleaning;

    public bool Confirming
    {
        get => _confirming;
        set { if (Set(ref _confirming, value)) Raise(string.Empty); }
    }

    public string ProgressText
    {
        get => _progressText;
        private set => Set(ref _progressText, value);
    }

    public string? ResultText
    {
        get => _resultText;
        private set => Set(ref _resultText, value);
    }

    public bool IncludeDependencies
    {
        get => _monitor.Settings.IncludeDependencyFolders;
        set
        {
            if (_monitor.Settings.IncludeDependencyFolders == value) return;
            _monitor.Settings.IncludeDependencyFolders = value;
            _monitor.Preferences.Save();
            Raise();
        }
    }

    public bool SortBySize
    {
        get => _monitor.Settings.RankStorageBySize;
        set
        {
            if (_monitor.Settings.RankStorageBySize == value) return;
            _monitor.Settings.RankStorageBySize = value;
            _monitor.Preferences.Save();
            Refresh();
        }
    }

    public string ScanButtonText => IsScanning ? "Stop" : (_items.Count == 0 ? "Scan" : "Rescan");
    public ulong FoundBytes => _items.Where(i => i.Risk.IsSelectable()).Aggregate(0UL, (s, i) => s + i.SizeBytes);
    public ulong PickedBytes => _items.Where(i => _picked.Contains(i.Path) && i.IsSelectable).Aggregate(0UL, (s, i) => s + i.SizeBytes);
    public ulong? Reclaimable => _items.Count == 0 ? null : _items.Where(i => i.IsSmartPick(DateTime.UtcNow)).Aggregate(0UL, (s, i) => s + i.SizeBytes);
    public string PickedText => Fmt.Bytes(PickedBytes);
    public string FoundText => $"picked · {Fmt.Bytes(FoundBytes)} found";
    public bool HasItems => _items.Count > 0;
    public string PickCountText => $"{Rows.Count(r => r.IsPicked)} of {Rows.Count(r => r.IsSelectable)} picked";
    public string CleanButtonText => PickedBytes == 0 ? "Pick something" : $"Clear {Fmt.Bytes(PickedBytes)}";
    public string ConfirmText => ConfirmSentence();
    public bool HasRecycleBound => _items.Any(i => _picked.Contains(i.Path) && i.Risk.UsesRecycleBin() && !i.IsRecycleBin);

    public IReadOnlyList<MeterSegment> DiskSegments
    {
        get
        {
            if (_monitor.Disk is not { } disk || disk.TotalBytes == 0) return [];
            var total = (double)disk.TotalBytes;
            var picked = Math.Min(PickedBytes, disk.UsedBytes);
            return
            [
                new(Palette.DiskUsed, (disk.UsedBytes - picked) / total),
                new(Palette.AppMemory, picked / total),
            ];
        }
    }

    public string DiskText => _monitor.Disk is { } disk
        ? $"{Fmt.Bytes(disk.AvailableBytes)} free of {Fmt.Bytes(disk.TotalBytes)}"
        : "";

    public string StatusText
    {
        get
        {
            if (IsScanning) return ProgressText;
            if (IsCleaning) return ProgressText;
            if (_items.Count == 0) return "Nothing measured yet. Scan to see what's taking space.";
            var order = SortBySize ? "Biggest ones up top." : "Grouped by type.";
            if (_fromCache) return $"From your last scan. {order}";
            var took = _lastScanTook is { } t ? $" in {Fmt.Duration(t)}" : "";
            return $"Found {Fmt.Plural(_items.Count, "spot")}{took}. {order}";
        }
    }

    public string? LeftAloneText
    {
        get
        {
            var held = _items.Count(i => i.IsProtected);
            return held == 0 ? null : $"Left {Fmt.Plural(held, "spot")} alone since something's running in there.";
        }
    }

    private string ConfirmSentence()
    {
        var picked = _items.Where(i => _picked.Contains(i.Path) && i.IsSelectable).ToList();
        var recycled = picked.Where(i => i.Risk.UsesRecycleBin() && !i.IsRecycleBin).Aggregate(0UL, (s, i) => s + i.SizeBytes);
        var deleted = PickedBytes - recycled;
        if (recycled == 0) return $"Delete {Fmt.Bytes(deleted)}? This can't be undone.";
        if (deleted == 0) return $"Move {Fmt.Bytes(recycled)} to the Recycle Bin?";
        return $"Delete {Fmt.Bytes(deleted)} and move {Fmt.Bytes(recycled)} to the Recycle Bin?";
    }

    public void PickChanged(StorageRow row)
    {
        if (row.IsPicked) _picked.Add(row.Id);
        else _picked.Remove(row.Id);
        Confirming = false;
        RaiseTotals();
    }

    public void MaybeAutoScan()
    {
        var settings = _monitor.Settings;
        if (!settings.AutoScanEnabled || IsBusy) return;
        if (settings.LastScanAt is { } last && DateTime.UtcNow - last < TimeSpan.FromHours(settings.AutoScanHours)) return;
        _ = ScanAsync();
    }

    public async Task ScanAsync()
    {
        if (IsBusy) return;
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        var found = new List<CleanupItem>();
        var dispatcher = Application.Current.Dispatcher;

        ResultText = null;
        Confirming = false;
        _scanStartedAt = DateTime.UtcNow;
        ProgressText = "Hunting for build caches";
        IsScanning = true;

        try
        {
            var scanner = new StorageScanner(Probes.Folders, _system);
            await scanner.ScanAsync(
                IncludeDependencies,
                progress => dispatcher.BeginInvoke(() =>
                {
                    ProgressText = progress.Total > 1 ? $"{progress.Stage} · {progress.Completed} of {progress.Total}" : progress.Stage;
                    Raise(nameof(StatusText));
                }),
                items => dispatcher.BeginInvoke(() =>
                {
                    found.AddRange(items);
                    Merge(found, final: false);
                }),
                token);

            await dispatcher.InvokeAsync(() => { });
            Merge(found, final: true);
            _lastScanTook = DateTime.UtcNow - _scanStartedAt;
            _monitor.Settings.LastScanAt = DateTime.UtcNow;
            _monitor.Preferences.Save();
            ScanCache.Save(_items, CachePath);
        }
        catch (OperationCanceledException)
        {
            ResultText = "Scan stopped. What it measured so far is below.";
        }
        finally
        {
            IsScanning = false;
            _cts.Dispose();
            _cts = null;
            Refresh();
        }
    }

    public void StopScan() => _cts?.Cancel();

    private void Merge(List<CleanupItem> found, bool final)
    {
        var now = DateTime.UtcNow;
        if (_fromCache || final)
        {
            var keep = _picked.ToHashSet(StringComparer.OrdinalIgnoreCase);
            _items.Clear();
            _picked.Clear();
            _fromCache = false;
            foreach (var item in found)
            {
                if (keep.Contains(item.Path) ? item.IsSelectable && !item.IsBusy(now) : item.IsDefaultPick(now))
                    _picked.Add(item.Path);
            }
            _items.AddRange(found);
        }
        else
        {
            foreach (var item in found.Where(f => !_items.Any(i => string.Equals(i.Path, f.Path, StringComparison.OrdinalIgnoreCase))))
            {
                _items.Add(item);
                if (item.IsDefaultPick(now)) _picked.Add(item.Path);
            }
        }
        Refresh();
    }

    private void ApplySmartPick()
    {
        var now = DateTime.UtcNow;
        _picked.Clear();
        foreach (var item in _items.Where(i => i.IsSmartPick(now))) _picked.Add(item.Path);
        Refresh();
    }

    private async Task CleanAsync()
    {
        var chosen = _items.Where(i => _picked.Contains(i.Path) && i.IsSelectable).ToList();
        if (chosen.Count == 0) return;
        var dispatcher = Application.Current.Dispatcher;
        Confirming = false;
        ResultText = null;
        IsCleaning = true;
        ProgressText = "Clearing";

        try
        {
            var report = await Task.Run(() => new Cleaner(Probes.Folders, _system, LogPath).Clean(
                chosen,
                p => dispatcher.BeginInvoke(() =>
                {
                    ProgressText = p.Stage == "Done" ? "Done" : $"Clearing {p.Stage} · {p.Completed + 1} of {p.Total}";
                    Raise(nameof(StatusText));
                }),
                CancellationToken.None,
                DateTime.UtcNow));

            var failed = report.Failures.Select(f => f.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
            _items.RemoveAll(i => chosen.Contains(i) && !failed.Contains(i.Path));
            _picked.RemoveWhere(p => !failed.Contains(p));
            var note = report.Failures.Count > 0 ? $" Skipped: {report.Failures[0].Reason}." : "";
            ResultText = report.Summary + "." + note;
            ScanCache.Save(_items, CachePath);
        }
        finally
        {
            IsCleaning = false;
            Refresh();
            await _monitor.SampleAsync();
        }
    }

    private void Refresh()
    {
        var largest = _items.Count == 0 ? 0 : _items.Max(i => i.SizeBytes);
        var ordered = SortBySize
            ? _items.OrderByDescending(i => i.SizeBytes)
            : _items.OrderBy(i => CategoryOrder(i.Category)).ThenByDescending(i => i.SizeBytes);

        Rows.Clear();
        foreach (var item in ordered)
        {
            Rows.Add(new StorageRow(this, item, _picked.Contains(item.Path), largest));
        }
        Raise(string.Empty);
        System.Windows.Input.CommandManager.InvalidateRequerySuggested();
    }

    private void RaiseTotals()
    {
        Raise(nameof(PickedText));
        Raise(nameof(PickCountText));
        Raise(nameof(CleanButtonText));
        Raise(nameof(ConfirmText));
        Raise(nameof(DiskSegments));
        Raise(nameof(Confirming));
        System.Windows.Input.CommandManager.InvalidateRequerySuggested();
    }

    public void DiskChanged()
    {
        Raise(nameof(DiskSegments));
        Raise(nameof(DiskText));
    }

    private static int CategoryOrder(string category) => category switch
    {
        "Package managers" => 0,
        "Project builds" => 1,
        "App caches" => 2,
        _ => 3,
    };
}
