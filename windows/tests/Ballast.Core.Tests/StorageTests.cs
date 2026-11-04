namespace Ballast.Core.Tests;

public class StoragePickTests
{
    private static readonly DateTime Now = new(2033, 5, 18, 3, 33, 20, DateTimeKind.Utc);

    private static CleanupItem Item(Risk risk, double? idleDays, string? heldBy = null, ulong size = 5UL << 30) => new()
    {
        Path = @"C:\Users\me\" + Guid.NewGuid(),
        Title = "x",
        Category = "c",
        Risk = risk,
        Reason = "r",
        SizeBytes = size,
        HeldBy = heldBy,
        LastTouched = idleDays is { } d ? Now.AddDays(-d) : null,
    };

    [Fact]
    public void SafeCachesArePickedByDefaultAndBySmartPick()
    {
        var safe = Item(Risk.Safe, 2);
        Assert.True(safe.IsDefaultPick(Now));
        Assert.True(safe.IsSmartPick(Now));
    }

    [Fact]
    public void RebuildablesNeedAMonthOfIdleForSmartPick()
    {
        Assert.False(Item(Risk.Review, 29).IsSmartPick(Now));
        Assert.True(Item(Risk.Review, 31).IsSmartPick(Now));
        Assert.False(Item(Risk.Review, 31).IsDefaultPick(Now));
        Assert.False(Item(Risk.Review, null).IsSmartPick(Now));
    }

    [Fact]
    public void BusyFoldersAreNeverPicked()
    {
        var busy = Item(Risk.Safe, 2.0 / 1440);
        Assert.True(busy.IsBusy(Now));
        Assert.False(busy.IsDefaultPick(Now));
        Assert.False(busy.IsSmartPick(Now));
    }

    [Fact]
    public void CarefulKeptAndHeldItemsAreNeverPicked()
    {
        Assert.False(Item(Risk.Caution, 400).IsSmartPick(Now));
        Assert.False(Item(Risk.ReportOnly, 400).IsSmartPick(Now));
        Assert.False(Item(Risk.Safe, 40, heldBy: "node").IsSmartPick(Now));
        Assert.False(Item(Risk.Safe, 40, size: 0).IsSmartPick(Now));
    }

    [Fact]
    public void ScanCacheRoundTripsAndDropsVanishedPaths()
    {
        var folder = Path.Combine(Path.GetTempPath(), "ballast-tests-" + Guid.NewGuid());
        Directory.CreateDirectory(folder);
        try
        {
            var present = Item(Risk.Review, 40) with { ProjectRoot = @"C:\Users\me\web" };
            var gone = Item(Risk.Safe, 1);
            var file = Path.Combine(folder, "last-scan.json");

            ScanCache.Save([present, gone], file);
            var loaded = ScanCache.Load(file, p => p == present.Path);

            var only = Assert.Single(loaded);
            Assert.Equal(present.Path, only.Path);
            Assert.Equal(Risk.Review, only.Risk);
            Assert.Equal(present.ProjectRoot, only.ProjectRoot);
            Assert.Equal(present.SizeBytes, only.SizeBytes);
            Assert.Equal(present.LastTouched, only.LastTouched);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}

public class DeletionGuardTests
{
    private const string Home = @"C:\Users\me";
    private static readonly KnownFolders Folders = KnownFolders.ForHome(Home);

    private static DeletionGuard Guard(Func<string, bool>? isLink = null) =>
        new(Home, CleanupTarget.All(Folders, includeDependencies: true), isLink ?? (_ => false));

    [Theory]
    [InlineData(@"C:\Users\me\AppData\Local\npm-cache\_cacache")]
    [InlineData(@"C:\Users\me\.gradle\caches")]
    [InlineData(@"C:\Users\me\code\web\.next\cache")]
    [InlineData(@"C:\Users\me\code\web\.next\dev\cache")]
    [InlineData(@"C:\Users\me\source\repos\shop\.turbo")]
    [InlineData(@"C:\Users\me\AppData\Local\Temp\installer-123")]
    [InlineData(@"c:/users/ME/appdata/local/npm-cache/_cacache")]
    public void AllowsKnownTargets(string path) => Assert.Null(Guard().Rejection(path));

    [Theory]
    [InlineData(@"C:\Users\me", "the home folder itself")]
    [InlineData(@"C:\Users\other\.gradle\caches", "outside the home folder")]
    [InlineData(@"D:\.gradle\caches", "outside the home folder")]
    [InlineData(@"C:\Users\me\.gradle", "too close to the top of the home folder")]
    [InlineData(@"C:\Users\me\code", "too close to the top of the home folder")]
    [InlineData(@"C:\Users\me\Documents\web\.next\cache", "inside Documents, which Ballast never deletes from")]
    [InlineData(@"C:\Users\me\OneDrive - Work\web\.turbo", "inside OneDrive - Work, which Ballast never deletes from")]
    [InlineData(@"C:\Users\me\AppData\Roaming\Code", "inside AppData, which Ballast never deletes from")]
    [InlineData(@"C:\Users\me\code\.git\.turbo", "inside .git, which Ballast never deletes from")]
    [InlineData(@"C:\Users\me\code\.claude\.turbo", "inside .claude, which Ballast never deletes from")]
    [InlineData(@"C:\Users\me\Downloads\big", "not a path Ballast knows how to clean")]
    [InlineData(@"C:\Users\me\code\..\.gradle\caches", "contains a parent reference")]
    [InlineData(@"\\server\share\.turbo", "network or device paths are never cleaned")]
    [InlineData(@".gradle\caches", "not an absolute path")]
    [InlineData(@"C:\Users\me\code\web\.turbo:stream", "contains a stream or drive marker")]
    public void RefusesEverythingElse(string path, string reason) => Assert.Equal(reason, Guard().Rejection(path));

    [Fact]
    public void RefusesPathsThatPassThroughALink()
    {
        var guard = Guard(p => WinPath.SameAs(p, @"C:\Users\me\code"));
        Assert.Equal("passes through a link or junction", guard.Rejection(@"C:\Users\me\code\web\.turbo"));
        Assert.Null(guard.Rejection(@"C:\Users\me\work\web\.turbo"));
    }

    [Fact]
    public void ReportOnlyTargetsAreNeverAllowed()
    {
        Assert.Equal("not a path Ballast knows how to clean", Guard().Rejection(@"C:\Users\me\Downloads\x"));
    }
}

public class CleanerTests
{
    private const string Home = @"C:\Users\me";
    private static readonly KnownFolders Folders = KnownFolders.ForHome(Home);
    private static readonly DateTime Now = new(2026, 6, 1, 0, 0, 0, DateTimeKind.Utc);

    private sealed class FakeOps : ICleanupFileOps
    {
        public List<string> Deleted { get; } = [];
        public List<string> Recycled { get; } = [];
        public bool BinEmptied { get; private set; }
        public Dictionary<string, string> Live { get; } = [];
        public List<ContentEntry> Contents { get; } = [];
        public HashSet<string> Locked { get; } = [];

        public void DeleteDirectory(string path)
        {
            if (Locked.Contains(path)) throw new IOException("in use");
            Deleted.Add(path);
        }

        public void DeleteFile(string path) => DeleteDirectory(path);
        public void Recycle(string path) => Recycled.Add(path);
        public void EmptyRecycleBin() => BinEmptied = true;
        public bool IsLink(string path) => false;
        public IEnumerable<ContentEntry> ContentsOlderThan(string directory, TimeSpan age) => Contents;
        public DiskSample? Disk() => new(100, 10);
        public IReadOnlyDictionary<string, string> LiveDirectories() => Live;
    }

    private static CleanupItem Item(string path, Risk risk, ulong size = 10_000_000, string? projectRoot = null,
        TimeSpan? minimumAge = null) => new()
    {
        Path = path, Title = WinPath.Leaf(path), Category = "c", Risk = risk, Reason = "r",
        SizeBytes = size, ProjectRoot = projectRoot, MinimumAge = minimumAge,
    };

    private static (CleanReport Report, FakeOps Ops) Run(Action<FakeOps> setup, params CleanupItem[] items)
    {
        var ops = new FakeOps();
        setup(ops);
        var log = Path.Combine(Path.GetTempPath(), "ballast-log-" + Guid.NewGuid() + ".jsonl");
        try
        {
            var report = new Cleaner(Folders, ops, log).Clean(items, _ => { }, CancellationToken.None, Now);
            return (report, ops);
        }
        finally
        {
            File.Delete(log);
        }
    }

    [Fact]
    public void SafeItemsAreDeletedAndRebuildablesGoToTheRecycleBin()
    {
        var (report, ops) = Run(_ => { },
            Item(@"C:\Users\me\AppData\Local\npm-cache\_cacache", Risk.Safe),
            Item(@"C:\Users\me\.gradle\caches", Risk.Review));

        Assert.Equal([@"C:\Users\me\AppData\Local\npm-cache\_cacache"], ops.Deleted);
        Assert.Equal([@"C:\Users\me\.gradle\caches"], ops.Recycled);
        Assert.Equal(1, report.Removed);
        Assert.Equal(1, report.Recycled);
        Assert.Empty(report.Failures);
    }

    [Fact]
    public void GuardRefusalsAreNeverDeleted()
    {
        var (report, ops) = Run(_ => { }, Item(@"C:\Users\me\Documents\thesis", Risk.Safe));
        Assert.Empty(ops.Deleted);
        Assert.Equal("inside Documents, which Ballast never deletes from", Assert.Single(report.Failures).Reason);
    }

    [Fact]
    public void ProjectsWithALiveProcessAreCheckedAgainRightBeforeDeleting()
    {
        var (report, ops) = Run(o => o.Live[@"C:\Users\me\code\web\src"] = "node",
            Item(@"C:\Users\me\code\web\.next\cache", Risk.Safe, projectRoot: @"C:\Users\me\code\web"));
        Assert.Empty(ops.Deleted);
        Assert.Equal("in use by node", Assert.Single(report.Failures).Reason);
    }

    [Fact]
    public void ReportOnlyItemsAreSkipped()
    {
        var (report, ops) = Run(_ => { }, Item(@"C:\Users\me\Downloads", Risk.ReportOnly));
        Assert.Empty(ops.Deleted);
        Assert.Equal("report only", Assert.Single(report.Failures).Reason);
    }

    [Fact]
    public void TempIsEmptiedEntryByEntryAndLockedFilesAreLeftAlone()
    {
        var temp = Folders.Temp;
        var (report, ops) = Run(o =>
        {
            o.Contents.Add(new(temp + @"\old.log", false, Now.AddDays(-3), 4_000_000));
            o.Contents.Add(new(temp + @"\setup", true, Now.AddDays(-9), 6_000_000));
            o.Contents.Add(new(temp + @"\busy.tmp", false, Now.AddDays(-2), 1_000_000));
            o.Locked.Add(temp + @"\busy.tmp");
        }, Item(temp, Risk.Safe, size: 11_000_000, minimumAge: TimeSpan.FromDays(1)));

        Assert.Equal([temp + @"\old.log", temp + @"\setup"], ops.Deleted);
        Assert.Equal(10_000_000UL, report.FreedBytes);
        Assert.Empty(report.Failures);
    }

    [Fact]
    public void RecycleBinIsEmptiedThroughTheShell()
    {
        var (report, ops) = Run(_ => { }, Item(CleanupItem.RecycleBinPath, Risk.Caution));
        Assert.True(ops.BinEmptied);
        Assert.Equal(1, report.Removed);
    }

    [Fact]
    public void SummaryDoesNotCountRecycledBytesAsFreed()
    {
        var report = new CleanReport { FreedBytes = 3UL << 30, Recycled = 1, RecycledBytes = 1UL << 30, Removed = 2 };
        Assert.Equal("Freed 2.0 GB · 2 deleted, 1 in the Recycle Bin", report.Summary);
    }
}

public class ScannerTests
{
    private sealed class Probe : IStorageProbe
    {
        public IReadOnlyDictionary<string, string> LiveDirectories() => new Dictionary<string, string>();
        public ulong? RecycleBinSize() => 0;
        public bool IsLink(string path) => false;
    }

    [Fact]
    public async Task FindsProjectCachesAndMeasuresThem()
    {
        if (!OperatingSystem.IsWindows()) return;

        var home = Path.Combine(Path.GetTempPath(), "ballast-home-" + Guid.NewGuid());
        var cache = Path.Combine(home, "code", "web", ".next", "cache");
        Directory.CreateDirectory(cache);
        await File.WriteAllBytesAsync(Path.Combine(cache, "blob"), new byte[2_000_000]);
        try
        {
            var found = new List<CleanupItem>();
            await new StorageScanner(KnownFolders.ForHome(home), new Probe())
                .ScanAsync(false, _ => { }, items => { lock (found) found.AddRange(items); }, CancellationToken.None);

            var item = Assert.Single(found, i => i.Category == "Project builds");
            Assert.Equal("code/web · .next\\cache", item.Title);
            Assert.Equal(2_000_000UL, item.SizeBytes);
            Assert.Equal(Risk.Safe, item.Risk);
            Assert.True(WinPath.SameAs(Path.Combine(home, "code", "web"), item.ProjectRoot!));
        }
        finally
        {
            Directory.Delete(home, recursive: true);
        }
    }

    [Fact]
    public async Task CachesTheGuardWouldRefuseAreShownButNeverOffered()
    {
        if (!OperatingSystem.IsWindows()) return;

        var home = Path.Combine(Path.GetTempPath(), "ballast-home-" + Guid.NewGuid());
        var cache = Path.Combine(home, "Desktop", "web", ".next", "cache");
        Directory.CreateDirectory(cache);
        await File.WriteAllBytesAsync(Path.Combine(cache, "blob"), new byte[2_000_000]);
        try
        {
            var found = new List<CleanupItem>();
            await new StorageScanner(KnownFolders.ForHome(home), new Probe())
                .ScanAsync(false, _ => { }, items => { lock (found) found.AddRange(items); }, CancellationToken.None);

            var item = Assert.Single(found, i => i.Category == "Project builds");
            Assert.Equal(Risk.ReportOnly, item.Risk);
            Assert.False(item.IsSelectable);
            Assert.False(item.IsSmartPick(DateTime.UtcNow.AddDays(60)));
            Assert.Contains("inside Desktop, which Ballast never deletes from", item.Reason);
        }
        finally
        {
            Directory.Delete(home, recursive: true);
        }
    }
}
