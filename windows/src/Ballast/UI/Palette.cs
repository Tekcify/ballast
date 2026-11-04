using System.Windows.Media;

namespace Ballast.UI;

public static class Palette
{
    public static readonly SolidColorBrush AppMemory = Make(0x5B, 0x6C, 0xD6);
    public static readonly SolidColorBrush Wired = Make(0x8A, 0x90, 0x9B);
    public static readonly SolidColorBrush Compressed = Make(0xD4, 0x86, 0x3F);
    public static readonly SolidColorBrush Cached = Make(0x6B, 0x9B, 0x8F, 0x73);
    public static readonly SolidColorBrush Warning = Make(0xC6, 0x7A, 0x2E);
    public static readonly SolidColorBrush Critical = Make(0xD0, 0x55, 0x4B);
    public static readonly SolidColorBrush Positive = Make(0x53, 0x8E, 0x65);
    public static readonly SolidColorBrush Neutral = Make(0x8E, 0x8E, 0x93);
    public static readonly SolidColorBrush DiskUsed = Make(0x8A, 0x90, 0x9B, 0xB0);

    public static SolidColorBrush Severity(Core.Severity severity) => severity switch
    {
        Core.Severity.Critical => Critical,
        Core.Severity.Warning => Warning,
        _ => Neutral,
    };

    public static SolidColorBrush Pressure(Core.Pressure pressure) => pressure switch
    {
        Core.Pressure.Critical => Critical,
        Core.Pressure.Warning => Warning,
        _ => Positive,
    };

    public static SolidColorBrush Risk(Core.Risk risk) => risk switch
    {
        Core.Risk.Safe => Positive,
        Core.Risk.Review => AppMemory,
        Core.Risk.Caution => Warning,
        _ => Neutral,
    };

    public static SolidColorBrush Tint(SolidColorBrush brush, byte alpha)
    {
        var tinted = new SolidColorBrush(Color.FromArgb(alpha, brush.Color.R, brush.Color.G, brush.Color.B));
        tinted.Freeze();
        return tinted;
    }

    private static SolidColorBrush Make(byte r, byte g, byte b, byte a = 0xFF)
    {
        var brush = new SolidColorBrush(Color.FromArgb(a, r, g, b));
        brush.Freeze();
        return brush;
    }
}
