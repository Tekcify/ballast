using System.Globalization;

namespace Ballast.Core;

public static class Fmt
{
    private const double Gigabyte = 1_073_741_824;
    private const double Megabyte = 1_048_576;
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

    public static string Bytes(ulong value) => Bytes((double)value);

    public static string Bytes(double value)
    {
        var gb = value / Gigabyte;
        if (gb >= 10) return gb.ToString("0", Invariant) + " GB";
        if (gb >= 1) return gb.ToString("0.0", Invariant) + " GB";
        var mb = value / Megabyte;
        if (mb >= 1) return mb.ToString("0", Invariant) + " MB";
        return Math.Max(value / 1024, 0).ToString("0", Invariant) + " KB";
    }

    public static string Rate(double bytesPerSecond) => Bytes(bytesPerSecond * 60) + "/min";

    public static string Percent(double fraction) =>
        Math.Round(fraction * 100).ToString("0", Invariant) + "%";

    public static string Duration(TimeSpan span)
    {
        var s = (long)Math.Max(span.TotalSeconds, 0);
        if (s < 90) return $"{s}s";
        var m = s / 60;
        if (m < 90) return $"{m}m";
        var h = m / 60;
        if (h < 48) return $"{h}h";
        return $"{h / 24}d";
    }

    public static string Plural(int count, string noun, string? plural = null) =>
        $"{count} {(count == 1 ? noun : plural ?? noun + "s")}";
}
