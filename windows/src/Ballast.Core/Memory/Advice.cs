namespace Ballast.Core;

public enum Severity
{
    Info = 0,
    Warning = 1,
    Critical = 2,
}

public enum AdviceKind
{
    None,
    Quit,
    OpenStorage,
}

public sealed record Advice
{
    public required string Id { get; init; }
    public required string Headline { get; init; }
    public required string Detail { get; init; }
    public Severity Severity { get; init; }
    public AdviceKind Kind { get; init; }
    public string? QuitName { get; init; }
    public IReadOnlyList<ProcessRef> QuitProcesses { get; init; } = [];
    public ulong ReclaimBytes { get; init; }
    public bool IsSystemWide { get; init; }
}

public sealed class GrowthTracker
{
    private const int Window = 16;
    private readonly Dictionary<string, List<(DateTime At, ulong Bytes)>> _samples = [];

    public void Record(IEnumerable<AppGroup> groups, DateTime now)
    {
        var live = new HashSet<string>();
        foreach (var group in groups)
        {
            live.Add(group.Id);
            if (!_samples.TryGetValue(group.Id, out var series))
            {
                series = [];
                _samples[group.Id] = series;
            }
            series.Add((now, group.MemoryBytes));
            if (series.Count > Window) series.RemoveRange(0, series.Count - Window);
        }
        foreach (var gone in _samples.Keys.Where(k => !live.Contains(k)).ToArray())
        {
            _samples.Remove(gone);
        }
    }

    public double? GrowthRate(string groupId)
    {
        if (!_samples.TryGetValue(groupId, out var series) || series.Count < 6) return null;
        var span = (series[^1].At - series[0].At).TotalSeconds;
        if (span <= 60) return null;
        for (var i = 1; i < series.Count; i++)
        {
            if (series[i].Bytes < series[i - 1].Bytes) return null;
        }
        var delta = (double)series[^1].Bytes - series[0].Bytes;
        return delta > 0 ? delta / span : null;
    }

    public TimeSpan ObservedSpan(string groupId) =>
        _samples.TryGetValue(groupId, out var series) && series.Count >= 2
            ? series[^1].At - series[0].At
            : TimeSpan.Zero;
}
