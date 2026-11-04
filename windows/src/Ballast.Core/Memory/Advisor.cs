namespace Ballast.Core;

public sealed record AdvisorInput
{
    public required MemorySample Memory { get; init; }
    public DiskSample? Disk { get; init; }
    public IReadOnlyList<AppGroup> Groups { get; init; } = [];
    public GrowthTracker Growth { get; init; } = new();
    public IReadOnlyDictionary<string, DateTime> LastActive { get; init; } = new Dictionary<string, DateTime>();
    public ulong? ReclaimableStorage { get; init; }
}

public static class Advisor
{
    private const ulong Gigabyte = 1_073_741_824;
    private const ulong Megabyte = 1_048_576;

    public static IReadOnlyList<Advice> Advise(AdvisorInput input, Settings settings, DateTime now)
    {
        var advice = new List<Advice>();
        advice.AddRange(SystemAdvice(input, settings));
        advice.AddRange(ProcessAdvice(input, settings, now));

        return advice
            .OrderByDescending(a => a.Severity)
            .ThenByDescending(a => a.IsSystemWide)
            .ThenByDescending(a => a.ReclaimBytes)
            .ToArray();
    }

    private static IEnumerable<Advice> SystemAdvice(AdvisorInput input, Settings settings)
    {
        var memory = input.Memory;
        var pressure = memory.Pressure;

        if (pressure > Pressure.Normal)
        {
            var squeezed = memory.CompressedBytes > 0 ? $"{Fmt.Bytes(memory.CompressedBytes)} squeezed, " : "";
            yield return new Advice
            {
                Id = "pressure",
                Headline = pressure == Pressure.Critical ? "Memory is fully cooked" : "Memory is getting cooked",
                Detail = $"{squeezed}{Fmt.Bytes(memory.AvailableBytes)} left and {Fmt.Percent(memory.CommitFraction)} of commit used. Windows is sweating to keep up.",
                Severity = pressure == Pressure.Critical ? Severity.Critical : Severity.Warning,
                IsSystemWide = true,
            };
        }

        if (input.Disk is { } disk && disk.AvailableBytes <= settings.LowDiskBytes)
        {
            var reclaim = input.ReclaimableStorage;
            yield return new Advice
            {
                Id = "disk",
                Headline = $"Only {Fmt.Bytes(disk.AvailableBytes)} free. Disk is down bad",
                Detail = reclaim is { } r
                    ? $"A scan found {Fmt.Bytes(r)} of caches you can clear."
                    : "Run a storage scan to see what can go.",
                Severity = disk.AvailableBytes <= settings.LowDiskBytes / 2 ? Severity.Critical : Severity.Warning,
                Kind = AdviceKind.OpenStorage,
                ReclaimBytes = reclaim ?? 0,
                IsSystemWide = true,
            };
        }
    }

    private static IEnumerable<Advice> ProcessAdvice(AdvisorInput input, Settings settings, DateTime now)
    {
        var pressure = input.Memory.Pressure;
        var candidates = new List<(AppGroup Group, double Score, List<string> Clauses, bool IsLeak)>();

        foreach (var group in input.Groups)
        {
            if (Grouping.IsEssential(group)) continue;
            if (group.MemoryBytes <= 512 * Megabyte) continue;

            var growth = input.Growth.GrowthRate(group.Id);
            var isLeak = (growth ?? 0) >= settings.GrowthBytesPerSecond;
            var meetsThreshold = group.MemoryBytes >= settings.PerAppThresholdBytes;
            var pressureRelevant = pressure > Pressure.Normal && group.MemoryBytes >= Gigabyte;
            if (!meetsThreshold && !pressureRelevant && !isLeak) continue;

            if (group.IsFrontmost && pressure != Pressure.Critical) continue;

            var score = (double)group.MemoryBytes / Gigabyte;
            var clauses = new List<string>
            {
                $"{Fmt.Bytes(group.MemoryBytes)} across {Fmt.Plural(group.ProcessCount, "process", "processes")}",
            };

            if (group.IsFrontmost)
            {
                score *= 0.5;
                clauses.Add("you're on it rn, so save your work first");
            }
            else if (input.LastActive.TryGetValue(group.Id, out var last))
            {
                var idle = now - last;
                if (idle.TotalMinutes >= settings.IdleMinutes)
                {
                    score *= 1.6;
                    clauses.Add($"you haven't touched it in {Fmt.Duration(idle)}");
                }
            }
            else if (group.IsRunningApp)
            {
                score *= 1.4;
                clauses.Add("you haven't opened it since Ballast started");
            }

            if (group.IsHidden)
            {
                score *= 1.2;
                clauses.Add("it's sitting minimized");
            }

            if (Grouping.Transient.Contains(group.ProcessName))
            {
                score *= 0.3;
                clauses.Add("it usually wraps up on its own");
            }

            if (isLeak && growth is { } rate)
            {
                score *= 1.5;
                clauses.Add($"it grew {Fmt.Rate(rate)} for the last {Fmt.Duration(input.Growth.ObservedSpan(group.Id))}");
            }

            if (group.IsSystemOwned && !group.IsRunningApp) score *= 0.4;

            if (!group.CanQuit)
            {
                clauses.Add("it runs as a Windows service, so stop it from the Services app if you don't need it");
            }

            if (Grouping.HoldsLiveState.Contains(group.ProcessName))
            {
                score *= 0.5;
                clauses.Add("it holds live state, so shut it down from inside instead of force quitting");
            }

            candidates.Add((group, score, clauses, isLeak));
        }

        return candidates
            .OrderByDescending(c => c.Score)
            .Take(3)
            .Select(c => new Advice
            {
                Id = "quit:" + c.Group.Id,
                Headline = c.IsLeak ? $"{c.Group.Name} keeps growing, kinda sus" : $"{c.Group.Name} is hogging RAM",
                Detail = Sentence(c.Clauses) + (c.IsLeak ? ". Restart it and you get that memory back." : "."),
                Severity = c.IsLeak || pressure > Pressure.Normal ? Severity.Warning : Severity.Info,
                Kind = c.Group.CanQuit ? AdviceKind.Quit : AdviceKind.None,
                QuitName = c.Group.Name,
                QuitProcesses = c.Group.Processes,
                ReclaimBytes = c.Group.MemoryBytes,
            })
            .ToArray();
    }

    private static string Sentence(IReadOnlyList<string> clauses) =>
        clauses.Count <= 1
            ? clauses.FirstOrDefault() ?? ""
            : string.Join(", ", clauses.Take(clauses.Count - 1)) + " and " + clauses[^1];
}
