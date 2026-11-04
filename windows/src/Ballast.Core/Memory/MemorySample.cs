namespace Ballast.Core;

public enum Pressure
{
    Normal = 1,
    Warning = 2,
    Critical = 4,
}

public static class PressureText
{
    public static string Label(this Pressure pressure) => pressure switch
    {
        Pressure.Critical => "Fully cooked",
        Pressure.Warning => "Getting cooked",
        _ => "Chillin",
    };
}

public sealed record MemorySample
{
    public ulong TotalBytes { get; init; }
    public ulong AvailableBytes { get; init; }
    public ulong CommitBytes { get; init; }
    public ulong CommitLimitBytes { get; init; }
    public ulong CachedBytes { get; init; }
    public ulong KernelBytes { get; init; }
    public ulong CompressedBytes { get; init; }
    public bool LowMemorySignaled { get; init; }

    public ulong UsedBytes => TotalBytes > AvailableBytes ? TotalBytes - AvailableBytes : 0;

    public ulong AppBytes
    {
        get
        {
            var other = KernelBytes + CompressedBytes;
            return UsedBytes > other ? UsedBytes - other : 0;
        }
    }

    public ulong VisibleCachedBytes => Math.Min(CachedBytes, AvailableBytes);

    public double UsedFraction => TotalBytes == 0 ? 0 : (double)UsedBytes / TotalBytes;

    public double CommitFraction => CommitLimitBytes == 0 ? 0 : (double)CommitBytes / CommitLimitBytes;

    public double AvailableFraction => TotalBytes == 0 ? 1 : (double)AvailableBytes / TotalBytes;

    public const double WarningAvailable = 0.12;
    public const double CriticalAvailable = 0.05;
    public const double WarningCommit = 0.85;
    public const double CriticalCommit = 0.95;

    public Pressure Pressure
    {
        get
        {
            if (TotalBytes == 0) return Pressure.Normal;
            if (LowMemorySignaled || AvailableFraction < CriticalAvailable || CommitFraction >= CriticalCommit)
                return Pressure.Critical;
            if (AvailableFraction < WarningAvailable || CommitFraction >= WarningCommit)
                return Pressure.Warning;
            return Pressure.Normal;
        }
    }
}

public sealed record DiskSample(ulong TotalBytes, ulong AvailableBytes)
{
    public ulong UsedBytes => TotalBytes > AvailableBytes ? TotalBytes - AvailableBytes : 0;
}
