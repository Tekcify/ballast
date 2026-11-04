namespace Ballast.Core.Tests;

public class PressureTests
{
    private const ulong GB = 1UL << 30;

    private static MemorySample Sample(double availableGB, double commitGB, bool lowSignal = false) => new()
    {
        TotalBytes = 16 * GB,
        AvailableBytes = (ulong)(availableGB * GB),
        CommitBytes = (ulong)(commitGB * GB),
        CommitLimitBytes = 32 * GB,
        LowMemorySignaled = lowSignal,
    };

    [Fact]
    public void PlentyFreeIsChill() => Assert.Equal(Pressure.Normal, Sample(6, 14).Pressure);

    [Fact]
    public void LowFreeMemoryWarns() => Assert.Equal(Pressure.Warning, Sample(1.5, 14).Pressure);

    [Fact]
    public void HighCommitWarnsEvenWithFreeMemory() => Assert.Equal(Pressure.Warning, Sample(6, 28).Pressure);

    [Fact]
    public void NearlyOutIsCritical()
    {
        Assert.Equal(Pressure.Critical, Sample(0.5, 14).Pressure);
        Assert.Equal(Pressure.Critical, Sample(6, 31).Pressure);
        Assert.Equal(Pressure.Critical, Sample(6, 14, lowSignal: true).Pressure);
    }

    [Fact]
    public void AppMemoryExcludesKernelAndCompressed()
    {
        var sample = Sample(6, 14) with { KernelBytes = GB, CompressedBytes = 2 * GB };
        Assert.Equal(10 * GB, sample.UsedBytes);
        Assert.Equal(7 * GB, sample.AppBytes);
    }
}

public class FormatTests
{
    [Theory]
    [InlineData(20UL << 30, "20 GB")]
    [InlineData(5UL << 29, "2.5 GB")]
    [InlineData(300UL << 20, "300 MB")]
    [InlineData(512UL, "1 KB")]
    public void Bytes(ulong value, string expected) => Assert.Equal(expected, Fmt.Bytes(value));

    [Theory]
    [InlineData(45, "45s")]
    [InlineData(600, "10m")]
    [InlineData(7200, "2h")]
    [InlineData(3 * 86400, "3d")]
    public void Durations(int seconds, string expected) => Assert.Equal(expected, Fmt.Duration(TimeSpan.FromSeconds(seconds)));
}

public class GroupingTests
{
    private static readonly DateTime Now = new(2026, 6, 1, 12, 0, 0, DateTimeKind.Utc);

    private static RawProcess Proc(int pid, string image, string? path, ulong mb, int session = 1) => new()
    {
        Pid = pid, ImageName = image, ExecutablePath = path, MemoryBytes = mb << 20, SessionId = session,
        StartedAt = Now.AddMinutes(-pid),
    };

    [Fact]
    public void HelpersLandWithTheAppThatOwnsThem()
    {
        const string chrome = @"C:\Program Files\Google\Chrome\Application\chrome.exe";
        var groups = Grouping.Build(
            [
                Proc(10, "chrome.exe", chrome, 800),
                Proc(11, "chrome.exe", chrome, 400),
                Proc(12, "chrome.exe", chrome, 300),
                Proc(20, "Code.exe", @"C:\Users\me\AppData\Local\Programs\Microsoft VS Code\Code.exe", 600),
                Proc(4, "svchost.exe", @"C:\Windows\System32\svchost.exe", 200, session: 0),
            ],
            new Dictionary<int, WindowPresence> { [10] = new(true, true) },
            foregroundPid: 20,
            describe: p => p.EndsWith("chrome.exe") ? "Google Chrome" : null,
            Now);

        Assert.Equal(["Google Chrome", "Code", "svchost"], groups.Select(g => g.Name));
        var browser = groups[0];
        Assert.Equal(1500UL << 20, browser.MemoryBytes);
        Assert.Equal(3, browser.ProcessCount);
        Assert.True(browser.IsRunningApp);
        Assert.True(browser.IsHidden);
        Assert.True(groups[1].IsFrontmost);
        Assert.True(Grouping.IsEssential(groups[2]));
        Assert.False(groups[2].CanQuit);
    }
}

public class AdvisorTests
{
    private const ulong GB = 1UL << 30;
    private static readonly DateTime Now = new(2026, 6, 1, 12, 0, 0, DateTimeKind.Utc);

    private static AppGroup Group(string name, double gb, bool frontmost = false, bool app = true) => new()
    {
        Id = name.ToLowerInvariant(),
        Name = name,
        ProcessName = name,
        ExecutablePath = $@"C:\Program Files\{name}\{name}.exe",
        Pids = [1, 2, 3],
        MemoryBytes = (ulong)(gb * GB),
        IsRunningApp = app,
        IsFrontmost = frontmost,
    };

    private static MemorySample Memory(double availableGB) => new()
    {
        TotalBytes = 16 * GB,
        AvailableBytes = (ulong)(availableGB * GB),
        CommitBytes = 12 * GB,
        CommitLimitBytes = 32 * GB,
    };

    [Fact]
    public void UnderPressureNamesTheBiggestIdleAppsAndExplainsWhy()
    {
        var input = new AdvisorInput
        {
            Memory = Memory(1),
            Groups = [Group("Chrome", 4.8), Group("Docker Desktop", 3.1), Group("Figma", 1.7), Group("Notepad", 0.2)],
            LastActive = new Dictionary<string, DateTime> { ["chrome"] = Now.AddHours(-2) },
        };

        var advice = Advisor.Advise(input, new Settings(), Now);

        Assert.Equal("pressure", advice[0].Id);
        Assert.Equal(Severity.Warning, advice[0].Severity);
        Assert.Equal(["quit:chrome", "quit:docker desktop", "quit:figma"], advice.Skip(1).Select(a => a.Id));
        Assert.Equal("4.8 GB across 3 processes and you haven't touched it in 2h.", advice[1].Detail);
        Assert.Contains("holds live state", advice[2].Detail);
    }

    [Fact]
    public void NeverTellsYouToQuitWhatYouAreUsingUnlessCritical()
    {
        var groups = new[] { Group("Chrome", 8, frontmost: true) };
        var warning = Advisor.Advise(new AdvisorInput { Memory = Memory(1.5), Groups = groups }, new Settings(), Now);
        Assert.DoesNotContain(warning, a => a.Id == "quit:chrome");

        var critical = Advisor.Advise(new AdvisorInput { Memory = Memory(0.4), Groups = groups }, new Settings(), Now);
        Assert.Contains(critical, a => a.Id == "quit:chrome" && a.Detail.Contains("save your work first"));
    }

    [Fact]
    public void CalmMachineOnlyFlagsAppsOverTheThreshold()
    {
        var input = new AdvisorInput { Memory = Memory(8), Groups = [Group("Chrome", 3), Group("Android Studio", 7)] };
        var advice = Advisor.Advise(input, new Settings(), Now);
        var only = Assert.Single(advice);
        Assert.Equal("quit:android studio", only.Id);
        Assert.Equal(Severity.Info, only.Severity);
    }

    [Fact]
    public void LowDiskPointsAtStorage()
    {
        var input = new AdvisorInput { Memory = Memory(8), Disk = new DiskSample(500 * GB, 8 * GB), ReclaimableStorage = 30 * GB };
        var advice = Assert.Single(Advisor.Advise(input, new Settings(), Now));
        Assert.Equal(AdviceKind.OpenStorage, advice.Kind);
        Assert.Equal(Severity.Critical, advice.Severity);
        Assert.Equal("A scan found 30 GB of caches you can clear.", advice.Detail);
    }

    [Fact]
    public void SteadyGrowthIsCalledOut()
    {
        var growth = new GrowthTracker();
        for (var i = 0; i < 8; i++)
        {
            growth.Record([Group("node", 1 + i * 0.4, app: false)], Now.AddSeconds(i * 20));
        }
        var input = new AdvisorInput { Memory = Memory(8), Groups = [Group("node", 3.8, app: false)], Growth = growth };
        var advice = Assert.Single(Advisor.Advise(input, new Settings(), Now.AddSeconds(160)));
        Assert.Equal("node keeps growing, kinda sus", advice.Headline);
        Assert.EndsWith("Restart it and you get that memory back.", advice.Detail);
    }
}
