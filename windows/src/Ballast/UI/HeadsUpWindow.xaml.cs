using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace Ballast.UI;

public sealed record Suggestion(string Name, string Size, Command Quit);

public sealed class HeadsUpViewModel : Observable
{
    private bool _isAlert = true;
    private string _headline = "";
    private string _detail = "";
    private Pressure _pressure = Pressure.Warning;
    private IReadOnlyList<Suggestion> _suggestions = [];

    public bool IsAlert { get => _isAlert; set => Set(ref _isAlert, value); }
    public string Headline { get => _headline; set => Set(ref _headline, value); }
    public string Detail { get => _detail; set => Set(ref _detail, value); }

    public Pressure Pressure
    {
        get => _pressure;
        set
        {
            if (Set(ref _pressure, value)) Raise(string.Empty);
        }
    }

    public IReadOnlyList<Suggestion> Suggestions
    {
        get => _suggestions;
        set
        {
            if (Set(ref _suggestions, value)) Raise(nameof(HasSuggestions));
        }
    }

    public bool HasSuggestions => Suggestions.Count > 0;
    public string Glyph => IsAlert ? "" : "";
    public Brush Accent => IsAlert ? Palette.Pressure(Pressure) : Palette.Positive;
    public Brush AccentFill => Palette.Tint((SolidColorBrush)Accent, 0x2E);

    public void Refresh(MonitorViewModel monitor)
    {
        Pressure = monitor.Pressure;
        var pressure = monitor.Advice.FirstOrDefault(a => a.Id == "pressure");
        Headline = pressure?.Headline ?? (monitor.Pressure == Pressure.Critical ? "Memory is fully cooked" : "Memory is getting cooked");
        Detail = pressure?.Detail ?? $"{Fmt.Percent(monitor.UsedFraction)} of memory in use.";
        Suggestions = monitor.Advice
            .Where(a => a.Id.StartsWith("quit:", StringComparison.Ordinal) && a.HasAction)
            .Take(2)
            .Select(a =>
            {
                var group = monitor.AllGroups.FirstOrDefault(g => "quit:" + g.Id == a.Id);
                return new Suggestion(group?.Name ?? a.Headline, group is null ? "" : Fmt.Bytes(group.MemoryBytes), a.Act);
            })
            .ToList();
        Raise(string.Empty);
    }
}

public partial class HeadsUpWindow : Window
{
    private readonly MonitorViewModel _monitor;
    private readonly HeadsUpViewModel _model = new();
    private readonly DispatcherTimer _autoClose = new();

    public HeadsUpWindow(MonitorViewModel monitor)
    {
        InitializeComponent();
        _monitor = monitor;
        DataContext = _model;
        SourceInitialized += (_, _) => WindowStyling.Apply(this, noActivate: true);
        SizeChanged += (_, _) => { if (IsVisible) Place(); };
        _autoClose.Tick += (_, _) =>
        {
            _autoClose.Stop();
            Close(dismissed: false);
        };
        _monitor.Sampled += () =>
        {
            if (IsVisible && _model.IsAlert) _model.Refresh(_monitor);
        };
    }

    public event Action<Pane>? OpenRequested;

    public bool IsAlertVisible => IsVisible && _model.IsAlert;

    public void Present()
    {
        _autoClose.Stop();
        _model.IsAlert = true;
        _model.Refresh(_monitor);
        Appear();
    }

    public void Recover()
    {
        if (!IsVisible) return;
        _model.IsAlert = false;
        _model.Headline = "Memory's chill again";
        _model.Detail = "Pressure eased off. Ballast is going back to lurking.";
        _model.Suggestions = [];
        _autoClose.Interval = TimeSpan.FromSeconds(4);
        _autoClose.Start();
    }

    public void ShowFor(TimeSpan duration)
    {
        Present();
        _autoClose.Interval = duration;
        _autoClose.Start();
    }

    private void Appear()
    {
        if (!IsVisible)
        {
            Opacity = SystemParameters.ClientAreaAnimation ? 0 : 1;
            Show();
        }
        Place();
        if (SystemParameters.ClientAreaAnimation)
        {
            BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(180))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            });
        }
    }

    private void Place()
    {
        var area = WindowStyling.WorkAreaInDips(this);
        Left = area.Right - ActualWidth - 12;
        Top = area.Bottom - ActualHeight - 12;
    }

    public void Close(bool dismissed)
    {
        _autoClose.Stop();
        if (!IsVisible) return;
        if (dismissed) _monitor.HeadsUpDismissed();
        BeginAnimation(OpacityProperty, null);
        Hide();
    }

    private void OnDismiss(object sender, RoutedEventArgs e) => Close(dismissed: true);

    private void OnOpen(object sender, RoutedEventArgs e)
    {
        Close(dismissed: true);
        OpenRequested?.Invoke(Pane.Memory);
    }

    private void OnStorage(object sender, RoutedEventArgs e)
    {
        Close(dismissed: true);
        OpenRequested?.Invoke(Pane.Storage);
    }

    private void OnSnooze(object sender, RoutedEventArgs e)
    {
        _monitor.Snooze(TimeSpan.FromHours(1));
        Close(dismissed: true);
    }
}
