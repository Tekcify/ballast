using System.Text.Json;

namespace Ballast.Core;

public sealed class Settings
{
    public double RefreshSeconds { get; set; } = 5;
    public double PerAppThresholdGB { get; set; } = 6;
    public double GrowthMBPerMinute { get; set; } = 120;
    public double LowDiskGB { get; set; } = 20;
    public double IdleMinutes { get; set; } = 20;
    public double CooldownMinutes { get; set; } = 15;
    public bool HeadsUpEnabled { get; set; } = true;
    public bool IncludeDependencyFolders { get; set; }
    public bool AutoScanEnabled { get; set; } = true;
    public double AutoScanHours { get; set; } = 24;
    public bool RankStorageBySize { get; set; } = true;
    public bool StartAtLoginDecided { get; set; }
    public DateTime? LastScanAt { get; set; }

    public ulong PerAppThresholdBytes => (ulong)(PerAppThresholdGB * 1_073_741_824);
    public ulong LowDiskBytes => (ulong)(LowDiskGB * 1_073_741_824);
    public double GrowthBytesPerSecond => GrowthMBPerMinute * 1_048_576 / 60;

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static Settings Load(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Json) ?? new Settings();
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
        }
        return new Settings();
    }

    public void Save(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}
