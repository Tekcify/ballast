using System.Text;
using System.Windows;
using Ballast.Platform;
using Ballast.UI;

namespace Ballast;

internal static class Diagnostics
{
    public static async Task<int> RunAsync(string mode, Application app)
    {
        Native.AttachConsole(-1);
        var output = new StringBuilder();
        var code = 0;

        try
        {
            switch (mode)
            {
                case "snapshot":
                    await Snapshot(output);
                    break;
                case "scan":
                    await Scan(output);
                    break;
                case "headsup":
                    await HeadsUp(output);
                    break;
                default:
                    output.AppendLine($"Unknown mode '{mode}'. Use snapshot, scan or headsup.");
                    code = 2;
                    break;
            }
        }
        catch (Exception ex)
        {
            output.AppendLine("Failed: " + ex);
            code = 1;
        }

        Console.Out.Write(output.ToString());
        Console.Out.Flush();
        var report = Environment.GetEnvironmentVariable("BALLAST_DIAGNOSTIC_OUT");
        if (!string.IsNullOrEmpty(report)) await File.WriteAllTextAsync(report, output.ToString());
        return code;
    }

    private static async Task Snapshot(StringBuilder o)
    {
        var monitor = new MonitorViewModel(new Settings());
        await monitor.SampleAsync();
        await Task.Delay(1500);
        await monitor.SampleAsync();

        var m = monitor.Memory ?? throw new InvalidOperationException("no memory sample");
        o.AppendLine($"Memory   {Fmt.Bytes(m.UsedBytes)} of {Fmt.Bytes(m.TotalBytes)} in use ({Fmt.Percent(m.UsedFraction)}), pressure {m.Pressure.Label()}");
        o.AppendLine($"         apps {Fmt.Bytes(m.AppBytes)}, kernel {Fmt.Bytes(m.KernelBytes)}, compressed {Fmt.Bytes(m.CompressedBytes)}, cached {Fmt.Bytes(m.CachedBytes)}");
        o.AppendLine($"Commit   {Fmt.Bytes(m.CommitBytes)} of {Fmt.Bytes(m.CommitLimitBytes)} ({Fmt.Percent(m.CommitFraction)}), low memory signal {(m.LowMemorySignaled ? "on" : "off")}");
        if (monitor.Disk is { } d) o.AppendLine($"Disk     {Fmt.Bytes(d.AvailableBytes)} free of {Fmt.Bytes(d.TotalBytes)}");
        o.AppendLine();
        o.AppendLine("Top apps");
        foreach (var g in monitor.AllGroups.Take(12))
        {
            var flags = new List<string>();
            if (g.IsRunningApp) flags.Add("window");
            if (g.IsFrontmost) flags.Add("front");
            if (g.IsHidden) flags.Add("minimized");
            if (Grouping.IsEssential(g)) flags.Add("system");
            o.AppendLine($"  {Fmt.Bytes(g.MemoryBytes),8}  {g.CpuPercent,5:0.0}%  {g.Name} ({g.ProcessCount}) {string.Join(",", flags)}");
        }
        o.AppendLine();
        o.AppendLine("Advice");
        if (monitor.Advice.Count == 0) o.AppendLine("  nothing, you're chillin");
        foreach (var a in monitor.Advice) o.AppendLine($"  {a.Headline}: {a.Detail}");
    }

    private static async Task Scan(StringBuilder o)
    {
        var system = new StorageSystem();
        var deep = Environment.GetEnvironmentVariable("BALLAST_DEEP") == "1";
        var items = new List<CleanupItem>();
        var started = DateTime.UtcNow;
        await new StorageScanner(Probes.Folders, system).ScanAsync(
            deep, _ => { }, found => { lock (items) items.AddRange(found); }, CancellationToken.None);

        var guard = new DeletionGuard(Probes.Folders.Home, CleanupTarget.All(Probes.Folders, true), system.IsLink);
        var now = DateTime.UtcNow;
        o.AppendLine($"Scanned in {Fmt.Duration(now - started)}. Dry run, nothing was deleted.");
        foreach (var item in items.OrderByDescending(i => i.SizeBytes))
        {
            var pick = item.IsSmartPick(now) ? "pick" : "    ";
            var guardNote = item.IsRecycleBin || !item.Risk.IsSelectable() ? "" : guard.Rejection(item.Path) is { } r ? $" [guard: {r}]" : "";
            var held = item.HeldBy is { } h ? $" [held by {h}]" : "";
            o.AppendLine($"  {pick} {Fmt.Bytes(item.SizeBytes),8}  {item.Risk.Label(),-8} {item.Title}  {item.Path}{held}{guardNote}");
        }
        var picked = items.Where(i => i.IsSmartPick(now)).Aggregate(0UL, (s, i) => s + i.SizeBytes);
        o.AppendLine($"Smart pick would clear {Fmt.Bytes(picked)} of {Fmt.Bytes(items.Aggregate(0UL, (s, i) => s + i.SizeBytes))} found.");
    }

    private static async Task HeadsUp(StringBuilder o)
    {
        var monitor = new MonitorViewModel(new Settings());
        monitor.FakePressure(Pressure.Warning);
        await monitor.SampleAsync();
        var window = new HeadsUpWindow(monitor);
        window.ShowFor(TimeSpan.FromSeconds(12));
        o.AppendLine($"Heads-up shown with faked pressure: {window.IsAlertVisible}");
        await Task.Delay(TimeSpan.FromSeconds(12));
        window.Close(dismissed: false);
    }
}
