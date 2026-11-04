namespace Ballast.Core;

public interface IStorageProbe
{
    IReadOnlyDictionary<string, string> LiveDirectories();
    ulong? RecycleBinSize();
    bool IsLink(string path);
}

public static class LiveProjects
{
    public static string? Holder(string projectRoot, IReadOnlyDictionary<string, string> live) =>
        live.FirstOrDefault(pair => WinPath.IsSameOrInside(pair.Key, projectRoot)).Value;
}

public static class DirectoryMeasure
{
    private static readonly EnumerationOptions Deep = new()
    {
        RecurseSubdirectories = true,
        IgnoreInaccessible = true,
        AttributesToSkip = FileAttributes.ReparsePoint,
        ReturnSpecialDirectories = false,
    };

    public static readonly EnumerationOptions Shallow = new()
    {
        RecurseSubdirectories = false,
        IgnoreInaccessible = true,
        AttributesToSkip = FileAttributes.ReparsePoint,
        ReturnSpecialDirectories = false,
    };

    public static ulong Size(string path, CancellationToken ct = default)
    {
        ulong total = 0;
        try
        {
            foreach (var file in new DirectoryInfo(path).EnumerateFiles("*", Deep))
            {
                ct.ThrowIfCancellationRequested();
                total += (ulong)Math.Max(file.Length, 0);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
        return total;
    }

    public static DateTime? LastTouched(string path)
    {
        try
        {
            var info = new DirectoryInfo(path);
            if (!info.Exists) return null;
            var newest = info.LastWriteTimeUtc;
            foreach (var entry in info.EnumerateFileSystemInfos("*", Shallow))
            {
                if (entry.LastWriteTimeUtc > newest) newest = entry.LastWriteTimeUtc;
            }
            return newest;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public static IEnumerable<ContentEntry> ContentsOlderThan(string directory, TimeSpan age, DateTime nowUtc, CancellationToken ct = default)
    {
        DirectoryInfo root;
        List<FileSystemInfo> entries;
        try
        {
            root = new DirectoryInfo(directory);
            entries = root.Exists ? root.EnumerateFileSystemInfos("*", Shallow).ToList() : [];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            yield break;
        }

        foreach (var entry in entries)
        {
            ct.ThrowIfCancellationRequested();
            var isDirectory = entry is DirectoryInfo;
            var touched = isDirectory ? LastTouched(entry.FullName) ?? entry.LastWriteTimeUtc : entry.LastWriteTimeUtc;
            if (nowUtc - touched < age) continue;
            var size = entry is FileInfo file ? (ulong)Math.Max(file.Length, 0) : Size(entry.FullName, ct);
            yield return new ContentEntry(entry.FullName, isDirectory, touched, size);
        }
    }
}

public readonly record struct ContentEntry(string Path, bool IsDirectory, DateTime LastTouchedUtc, ulong SizeBytes);

public sealed class StorageScanner(KnownFolders folders, IStorageProbe probe)
{
    private const ulong MinimumSize = 1_048_576;

    /// <summary>
    /// The same guard the cleaner uses. A cache the guard would refuse, such as a
    /// project under Desktop or Documents, is still measured but listed as kept,
    /// so it is never ticked and then refused at clean time.
    /// </summary>
    private readonly DeletionGuard _guard =
        new(folders.Home, CleanupTarget.All(folders, includeDependencies: true), probe.IsLink);

    private static readonly HashSet<string> SkipAtTop = new(StringComparer.OrdinalIgnoreCase)
    {
        "AppData", "Pictures", "Music", "Videos", "Saved Games", "Favorites", "Contacts", "Links",
        "Searches", "Application Data", "Local Settings", "Cookies",
    };

    private static readonly HashSet<string> SkipAnywhere = new(StringComparer.OrdinalIgnoreCase)
    {
        "node_modules", ".git", "$Recycle.Bin", "System Volume Information",
    };

    private sealed record Candidate(string Path, CleanupTarget Target, string? ProjectRoot);

    public async Task ScanAsync(
        bool includeDependencies,
        Action<ScanProgress> onProgress,
        Action<IReadOnlyList<CleanupItem>> onItems,
        CancellationToken ct)
    {
        var targets = CleanupTarget.All(folders, includeDependencies);
        onProgress(new ScanProgress("Hunting for build caches", 0, 1));

        var (live, candidates) = await Task.Run(() =>
        {
            var liveDirectories = probe.LiveDirectories();
            var matches = RunSearch(targets, ct);
            var expanded = targets.SelectMany(t => Expand(t, matches)).ToList();
            return (liveDirectories, Dedupe(expanded));
        }, ct).ConfigureAwait(false);

        var total = candidates.Count;
        var completed = 0;
        onProgress(new ScanProgress("Sizing things up", 0, total));

        var options = new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = ct };
        await Parallel.ForEachAsync(candidates, options, (candidate, token) =>
        {
            var item = Measure(candidate, live, token);
            var done = Interlocked.Increment(ref completed);
            onProgress(new ScanProgress("Sizing things up", done, total));
            if (item is not null) onItems([item]);
            return ValueTask.CompletedTask;
        }).ConfigureAwait(false);

        onProgress(new ScanProgress("Done", total, total));
    }

    private static List<Candidate> Dedupe(IEnumerable<Candidate> candidates)
    {
        var best = new Dictionary<string, Candidate>(StringComparer.OrdinalIgnoreCase);
        foreach (var candidate in candidates)
        {
            if (!best.TryGetValue(candidate.Path, out var existing) || Rank(candidate) > Rank(existing))
            {
                best[candidate.Path] = candidate;
            }
        }
        return best.Values.ToList();
    }

    private static int Rank(Candidate candidate)
    {
        var specificity = candidate.Target.Shape switch
        {
            ShapeKind.Directory or ShapeKind.Contents or ShapeKind.RecycleBin => 3,
            ShapeKind.Search => 2,
            _ => 1,
        };
        return (int)candidate.Target.Risk * 10 + specificity;
    }

    private Dictionary<string, List<string>> RunSearch(IReadOnlyList<CleanupTarget> targets, CancellationToken ct)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var maxDepth = 0;
        foreach (var target in targets.Where(t => t.Shape == ShapeKind.Search))
        {
            names.UnionWith(target.SearchNames);
            maxDepth = Math.Max(maxDepth, target.MaxDepth);
        }

        var found = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        if (names.Count == 0 || !Directory.Exists(folders.Home)) return found;

        var queue = new Queue<(string Path, int Depth)>();
        queue.Enqueue((folders.Home, 0));

        while (queue.Count > 0)
        {
            ct.ThrowIfCancellationRequested();
            var (directory, depth) = queue.Dequeue();

            List<string> children;
            try
            {
                children = Directory.EnumerateDirectories(directory, "*", DirectoryMeasure.Shallow).ToList();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            foreach (var child in children)
            {
                var name = WinPath.Leaf(child);
                if (names.Contains(name))
                {
                    if (!found.TryGetValue(name, out var list))
                    {
                        list = [];
                        found[name] = list;
                    }
                    list.Add(child);
                    continue;
                }
                if (depth == 0 && (SkipAtTop.Contains(name) || name.StartsWith("OneDrive", StringComparison.OrdinalIgnoreCase)))
                    continue;
                if (SkipAnywhere.Contains(name)) continue;
                if (depth + 1 < maxDepth) queue.Enqueue((child, depth + 1));
            }
        }
        return found;
    }

    private IEnumerable<Candidate> Expand(CleanupTarget target, Dictionary<string, List<string>> matches)
    {
        switch (target.Shape)
        {
            case ShapeKind.RecycleBin:
                yield return new Candidate(target.Path, target, null);
                break;

            case ShapeKind.Directory:
            case ShapeKind.Contents:
                if (Directory.Exists(target.Path) && !probe.IsLink(target.Path))
                    yield return new Candidate(target.Path, target, null);
                break;

            case ShapeKind.Children:
                IEnumerable<string> children;
                try
                {
                    children = Directory.Exists(target.Path)
                        ? Directory.EnumerateDirectories(target.Path, "*", DirectoryMeasure.Shallow).ToList()
                        : [];
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    children = [];
                }
                foreach (var child in children) yield return new Candidate(child, target, null);
                break;

            case ShapeKind.Search:
                var rootDepth = WinPath.Components(target.Path).Length;
                foreach (var name in target.SearchNames)
                {
                    if (!matches.TryGetValue(name, out var list)) continue;
                    foreach (var match in list)
                    {
                        if (WinPath.Components(match).Length - rootDepth > target.MaxDepth) continue;
                        var projectRoot = WinPath.Parent(match);
                        if (target.StaleAfterDays is { } days && !IsStale(projectRoot, days)) continue;

                        if (target.SearchSubpaths.Count == 0)
                        {
                            yield return new Candidate(match, target, projectRoot);
                            continue;
                        }
                        foreach (var sub in target.SearchSubpaths)
                        {
                            var path = WinPath.Join(match, sub);
                            if (Directory.Exists(path)) yield return new Candidate(path, target, projectRoot);
                        }
                    }
                }
                break;
        }
    }

    private static bool IsStale(string path, int days)
    {
        try
        {
            return DateTime.UtcNow - Directory.GetLastWriteTimeUtc(path) > TimeSpan.FromDays(days);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private CleanupItem? Measure(Candidate candidate, IReadOnlyDictionary<string, string> live, CancellationToken ct)
    {
        var target = candidate.Target;
        ulong size;
        DateTime? touched;

        switch (target.Shape)
        {
            case ShapeKind.RecycleBin:
                size = probe.RecycleBinSize() ?? 0;
                touched = null;
                break;
            case ShapeKind.Contents:
                var entries = DirectoryMeasure
                    .ContentsOlderThan(candidate.Path, target.MinimumAge ?? TimeSpan.Zero, DateTime.UtcNow, ct)
                    .ToList();
                size = entries.Aggregate(0UL, (sum, e) => sum + e.SizeBytes);
                touched = entries.Count == 0 ? null : entries.Max(e => e.LastTouchedUtc);
                break;
            default:
                size = DirectoryMeasure.Size(candidate.Path, ct);
                touched = DirectoryMeasure.LastTouched(candidate.Path);
                break;
        }

        if (size < MinimumSize) return null;
        var guarded = target.GuardAgainstLiveProjects ? candidate.ProjectRoot : null;

        var risk = target.Risk;
        var reason = target.Reason;
        if (risk.IsSelectable() && target.Shape != ShapeKind.RecycleBin && _guard.Rejection(candidate.Path) is { } refusal)
        {
            risk = Risk.ReportOnly;
            reason = $"Shown so you know it's there, but Ballast won't clear it: {refusal}.";
        }

        return new CleanupItem
        {
            Path = candidate.Path,
            Title = DisplayTitle(candidate),
            Category = target.Category,
            Risk = risk,
            Reason = reason,
            SizeBytes = size,
            HeldBy = guarded is null ? null : LiveProjects.Holder(guarded, live),
            LastTouched = touched,
            ProjectRoot = guarded,
            MinimumAge = target.MinimumAge,
        };
    }

    private string DisplayTitle(Candidate candidate)
    {
        switch (candidate.Target.Shape)
        {
            case ShapeKind.Children:
                return WinPath.Leaf(candidate.Path);
            case ShapeKind.Search:
                var root = candidate.ProjectRoot ?? "";
                var leaf = string.Join("\\", WinPath.RelativeComponents(candidate.Path, root));
                return $"{ProjectLabel(candidate.ProjectRoot)} · {leaf}";
            default:
                return candidate.Target.Title;
        }
    }

    private string ProjectLabel(string? projectRoot)
    {
        if (projectRoot is null) return "project";
        var parts = WinPath.Components(projectRoot);
        if (parts.Length == 0) return "project";
        var last = parts[^1];
        if (parts.Length < 2) return last;
        var parent = parts[^2];
        return parent.Equals(WinPath.Leaf(folders.Home), StringComparison.OrdinalIgnoreCase) ? last : $"{parent}/{last}";
    }
}
