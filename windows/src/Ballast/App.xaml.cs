using System.Windows;
using Ballast.Platform;
using Ballast.UI;
using Microsoft.Win32;

namespace Ballast;

public partial class App : Application
{
    private const string MutexName = @"Local\Tekcify.Ballast";
    private const string OpenEventName = @"Local\Tekcify.Ballast.Open";

    private Mutex? _single;
    private EventWaitHandle? _openSignal;
    private MonitorViewModel? _monitor;
    private PanelWindow? _panel;
    private HeadsUpWindow? _headsUp;
    private TrayIcon? _tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var args = e.Args;

        // A short-lived copy started by Quitter to send Ctrl+C to a console app.
        if (args.Contains(ConsoleInterrupt.Flag))
        {
            Shutdown(ConsoleInterrupt.RunHelper(args));
            return;
        }

        var diagnostic = Array.IndexOf(args, "--diagnostic");
        if (diagnostic >= 0)
        {
            var mode = diagnostic + 1 < args.Length ? args[diagnostic + 1] : "snapshot";
            Theme.Apply(this);
            _ = RunDiagnosticAsync(mode);
            return;
        }

        _single = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            if (EventWaitHandle.TryOpenExisting(OpenEventName, out var existing))
            {
                existing.Set();
                existing.Dispose();
            }
            Shutdown();
            return;
        }

        Theme.Apply(this);
        SystemEvents.UserPreferenceChanged += (_, _) => Dispatcher.BeginInvoke(() =>
        {
            Theme.Apply(this);
            _tray?.Update();
        });

        Directory.CreateDirectory(Probes.DataFolder);
        var settings = Settings.Load(SettingsViewModel.SettingsPath);
        _monitor = new MonitorViewModel(settings);
        _panel = new PanelWindow(_monitor);
        _headsUp = new HeadsUpWindow(_monitor);
        _tray = new TrayIcon(_monitor);

        _monitor.IsHeadsUpVisible = () => _headsUp.IsAlertVisible;
        _monitor.Sampled += () => _tray.Update();
        _monitor.OpenPaneRequested += pane => _panel.Open(pane);
        _monitor.HeadsUpRequested += decision =>
        {
            if (decision == HeadsUpDecision.Present && !_panel.IsVisible) _headsUp.Present();
            else if (decision == HeadsUpDecision.Recover) _headsUp.Recover();
        };
        _headsUp.OpenRequested += pane => _panel.Open(pane);
        _panel.QuitRequested += Quit;
        _tray.QuitRequested += Quit;
        _tray.ToggleRequested += () => _panel.Toggle();
        _tray.OpenRequested += pane => _panel.Open(pane);

        _openSignal = new EventWaitHandle(false, EventResetMode.AutoReset, OpenEventName);
        var signal = _openSignal;
        ThreadPool.RegisterWaitForSingleObject(signal, (_, _) => Dispatcher.BeginInvoke(() => _panel.Open()), null, -1, false);

        if (!settings.StartAtLoginDecided && StartupItem.IsInstalledCopy)
        {
            try
            {
                StartupItem.SetEnabled(true);
            }
            catch (Exception ex) when (ex is UnauthorizedAccessException or IOException or System.Security.SecurityException)
            {
            }
            settings.StartAtLoginDecided = true;
            settings.Save(SettingsViewModel.SettingsPath);
        }

        _monitor.Start();
        if (!args.Contains("--background"))
        {
            Dispatcher.BeginInvoke(async () =>
            {
                await _monitor.SampleAsync();
                _panel.Open();
            });
        }

        var autoScan = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        autoScan.Tick += (_, _) =>
        {
            autoScan.Interval = TimeSpan.FromHours(1);
            _monitor.Storage.MaybeAutoScan();
        };
        autoScan.Start();
    }

    private void Quit()
    {
        _tray?.Dispose();
        _tray = null;
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _openSignal?.Dispose();
        _single?.Dispose();
        base.OnExit(e);
    }

    private async Task RunDiagnosticAsync(string mode)
    {
        var code = await Diagnostics.RunAsync(mode, this);
        Shutdown(code);
    }
}
