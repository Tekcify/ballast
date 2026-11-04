using System.Text.Json.Serialization;

namespace Ballast.Core;

public enum Risk
{
    Safe = 0,
    Review = 1,
    Caution = 2,
    ReportOnly = 3,
}

public static class RiskInfo
{
    public static string Label(this Risk risk) => risk switch
    {
        Risk.Safe => "Safe",
        Risk.Review => "Rebuilds",
        Risk.Caution => "Careful",
        _ => "Kept",
    };

    public static bool IsSelectable(this Risk risk) => risk != Risk.ReportOnly;
    public static bool DefaultsOn(this Risk risk) => risk == Risk.Safe;
    public static bool UsesRecycleBin(this Risk risk) => risk is Risk.Review or Risk.Caution;
}

public sealed record CleanupItem
{
    public static readonly TimeSpan BusyWindow = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan DormantAfter = TimeSpan.FromDays(30);
    public const string RecycleBinPath = "::RecycleBin";

    public required string Path { get; init; }
    public required string Title { get; init; }
    public required string Category { get; init; }
    public Risk Risk { get; init; }
    public required string Reason { get; init; }
    public ulong SizeBytes { get; init; }
    public string? HeldBy { get; init; }
    public DateTime? LastTouched { get; init; }
    public string? ProjectRoot { get; init; }
    public TimeSpan? MinimumAge { get; init; }

    [JsonIgnore] public string Id => Path;
    [JsonIgnore] public bool IsProtected => HeldBy is not null;
    [JsonIgnore] public bool IsSelectable => Risk.IsSelectable() && !IsProtected && SizeBytes > 0;
    [JsonIgnore] public bool IsRecycleBin => Path == RecycleBinPath;

    public TimeSpan? Idle(DateTime now) => LastTouched is { } touched ? now - touched : null;

    public bool IsBusy(DateTime now) => (Idle(now) ?? TimeSpan.MaxValue) < BusyWindow;

    public bool IsDormant(DateTime now) => (Idle(now) ?? TimeSpan.Zero) >= DormantAfter;

    public bool IsDefaultPick(DateTime now) => IsSelectable && Risk.DefaultsOn() && !IsBusy(now);

    public bool IsSmartPick(DateTime now)
    {
        if (!IsSelectable || IsBusy(now)) return false;
        return Risk switch
        {
            Risk.Safe => true,
            Risk.Review => IsDormant(now),
            _ => false,
        };
    }
}

public readonly record struct ScanProgress(string Stage, int Completed, int Total);
