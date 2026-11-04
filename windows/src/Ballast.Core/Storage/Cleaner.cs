using System.Text.Json;

namespace Ballast.Core;

public interface ICleanupFileOps
{
    void DeleteDirectory(string path);
    void DeleteFile(string path);
    void Recycle(string path);
    void EmptyRecycleBin();
    bool IsLink(string path);
    IEnumerable<ContentEntry> ContentsOlderThan(string directory, TimeSpan age);
    DiskSample? Disk();
    IReadOnlyDictionary<string, string> LiveDirectories();
}

public sealed record CleanFailure(string Path, string Reason);

public sealed record CleanReport
{
    public ulong FreedBytes { get; init; }
    public int Removed { get; init; }
    public int Recycled { get; init; }
    public ulong RecycledBytes { get; init; }
    public IReadOnlyList<CleanFailure> Failures { get; init; } = [];
    public DiskSample? Before { get; init; }
    public DiskSample? After { get; init; }

    public string Summary
    {
        get
        {
            var parts = new List<string>();
            if (Removed > 0) parts.Add($"{Removed} deleted");
            if (Recycled > 0) parts.Add($"{Recycled} in the Recycle Bin");
            if (Failures.Count > 0) parts.Add($"{Failures.Count} skipped");
            if (parts.Count == 0) return "Nothing to clear, you're good";
            var freed = FreedBytes - Math.Min(RecycledBytes, FreedBytes);
            return $"Freed {Fmt.Bytes(freed)} · {string.Join(", ", parts)}";
        }
    }
}

public sealed class Cleaner
{
    private readonly KnownFolders _folders;
    private readonly ICleanupFileOps _ops;
    private readonly string _logPath;
    private readonly DeletionGuard _guard;

    public Cleaner(KnownFolders folders, ICleanupFileOps ops, string logPath)
    {
        _folders = folders;
        _ops = ops;
        _logPath = logPath;
        _guard = new DeletionGuard(folders.Home, CleanupTarget.All(folders, includeDependencies: true), ops.IsLink);
    }

    public CleanReport Clean(IReadOnlyList<CleanupItem> items, Action<ScanProgress> onProgress, CancellationToken ct, DateTime nowUtc)
    {
        var before = _ops.Disk();
        ulong freed = 0, recycledBytes = 0;
        int removed = 0, recycled = 0;
        var failures = new List<CleanFailure>();
        var log = new List<object>();
        var live = items.Any(i => i.ProjectRoot is not null)
            ? _ops.LiveDirectories()
            : new Dictionary<string, string>();

        for (var index = 0; index < items.Count; index++)
        {
            if (ct.IsCancellationRequested) break;
            var item = items[index];
            onProgress(new ScanProgress(item.Title, index, items.Count));

            if (!item.Risk.IsSelectable())
            {
                failures.Add(new(item.Path, "report only"));
                continue;
            }
            if (item.IsProtected)
            {
                failures.Add(new(item.Path, $"in use by {item.HeldBy}"));
                continue;
            }
            if (item.ProjectRoot is { } root && LiveProjects.Holder(root, live) is { } holder)
            {
                failures.Add(new(item.Path, $"in use by {holder}"));
                continue;
            }

            try
            {
                string method;
                ulong bytes;
                if (item.IsRecycleBin)
                {
                    _ops.EmptyRecycleBin();
                    method = "emptied";
                    bytes = item.SizeBytes;
                    removed++;
                }
                else if (_guard.Rejection(item.Path) is { } reason)
                {
                    failures.Add(new(item.Path, reason));
                    continue;
                }
                else if (item.MinimumAge is { } age)
                {
                    bytes = 0;
                    var skipped = 0;
                    foreach (var entry in _ops.ContentsOlderThan(item.Path, age))
                    {
                        if (ct.IsCancellationRequested) break;
                        if (_guard.Rejection(entry.Path) is not null)
                        {
                            skipped++;
                            continue;
                        }
                        try
                        {
                            if (entry.IsDirectory) _ops.DeleteDirectory(entry.Path);
                            else _ops.DeleteFile(entry.Path);
                            bytes += entry.SizeBytes;
                        }
                        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                        {
                            skipped++;
                        }
                    }
                    method = skipped > 0 ? $"emptied, {skipped} in use" : "emptied";
                    removed++;
                }
                else if (item.Risk.UsesRecycleBin())
                {
                    _ops.Recycle(item.Path);
                    method = "recycled";
                    bytes = item.SizeBytes;
                    recycled++;
                    recycledBytes += bytes;
                }
                else
                {
                    _ops.DeleteDirectory(item.Path);
                    method = "deleted";
                    bytes = item.SizeBytes;
                    removed++;
                }

                freed += bytes;
                log.Add(new
                {
                    at = nowUtc.ToString("o"),
                    path = item.Path,
                    bytes,
                    method,
                    risk = item.Risk.Label(),
                    category = item.Category,
                });
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                failures.Add(new(item.Path, ex.Message));
            }
        }

        AppendLog(log);
        onProgress(new ScanProgress("Done", items.Count, items.Count));

        return new CleanReport
        {
            FreedBytes = freed,
            Removed = removed,
            Recycled = recycled,
            RecycledBytes = recycledBytes,
            Failures = failures,
            Before = before,
            After = _ops.Disk(),
        };
    }

    private void AppendLog(List<object> entries)
    {
        if (entries.Count == 0) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_logPath)!);
            File.AppendAllLines(_logPath, entries.Select(e => JsonSerializer.Serialize(e)));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}

public static class ScanCache
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = false };

    public static void Save(IEnumerable<CleanupItem> items, string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(items.Where(i => !i.IsRecycleBin).ToList(), Json));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    public static IReadOnlyList<CleanupItem> Load(string path, Func<string, bool> exists)
    {
        try
        {
            if (!File.Exists(path)) return [];
            var items = JsonSerializer.Deserialize<List<CleanupItem>>(File.ReadAllText(path), Json) ?? [];
            return items.Where(i => !i.IsRecycleBin && exists(i.Path)).ToList();
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return [];
        }
    }
}
