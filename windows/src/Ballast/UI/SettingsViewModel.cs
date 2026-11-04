using System.Diagnostics;
using System.Reflection;
using Ballast.Platform;

namespace Ballast.UI;

public sealed class SettingsViewModel : Observable
{
    private readonly MonitorViewModel _monitor;
    private string? _loginNote;

    public SettingsViewModel(MonitorViewModel monitor)
    {
        _monitor = monitor;
        OpenData = new Command(() =>
        {
            Directory.CreateDirectory(Probes.DataFolder);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Probes.DataFolder}\"") { UseShellExecute = true });
        });
    }

    public static string SettingsPath => Path.Combine(Probes.DataFolder, "settings.json");

    private Settings S => _monitor.Settings;

    public Command OpenData { get; }

    public string Version => "Version " + (Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.0.0");

    public string? LoginNote
    {
        get => _loginNote;
        private set => Set(ref _loginNote, value);
    }

    public bool StartAtLogin
    {
        get => StartupItem.IsEnabled;
        set
        {
            try
            {
                StartupItem.SetEnabled(value);
                S.StartAtLoginDecided = true;
                Save();
                LoginNote = null;
            }
            catch (Exception ex) when (ex is UnauthorizedAccessException or IOException or System.Security.SecurityException)
            {
                LoginNote = "Windows said no. Check Startup apps in Settings.";
            }
            Raise();
        }
    }

    public bool HeadsUpEnabled
    {
        get => S.HeadsUpEnabled;
        set { S.HeadsUpEnabled = value; Save(); Raise(); }
    }

    public double RefreshSeconds
    {
        get => S.RefreshSeconds;
        set { S.RefreshSeconds = value; Save(); _monitor.ApplyRefreshInterval(); Raise(); }
    }

    public double PerAppThresholdGB
    {
        get => S.PerAppThresholdGB;
        set { S.PerAppThresholdGB = value; Save(); Raise(); }
    }

    public double LowDiskGB
    {
        get => S.LowDiskGB;
        set { S.LowDiskGB = value; Save(); Raise(); }
    }

    public double IdleMinutes
    {
        get => S.IdleMinutes;
        set { S.IdleMinutes = value; Save(); Raise(); }
    }

    public bool AutoScanEnabled
    {
        get => S.AutoScanEnabled;
        set { S.AutoScanEnabled = value; Save(); Raise(); }
    }

    public void Save() => S.Save(SettingsPath);
}
