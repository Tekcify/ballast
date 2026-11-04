using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace Ballast.UI;

public partial class PanelWindow : Window
{
    private readonly MemoryView _memory;
    private readonly StorageView _storage;
    private readonly SettingsView _settings;
    private DateTime _hiddenAt = DateTime.MinValue;
    private bool _placed;

    public PanelWindow(MonitorViewModel monitor)
    {
        InitializeComponent();
        DataContext = monitor;
        _memory = new MemoryView { DataContext = monitor };
        _storage = new StorageView { DataContext = monitor.Storage };
        _settings = new SettingsView { DataContext = monitor.Preferences };
        ShowPane(Pane.Memory);

        SourceInitialized += (_, _) => WindowStyling.Apply(this, noActivate: false);
        Deactivated += (_, _) => HideNow();
        SizeChanged += (_, _) => { if (IsVisible) Place(); };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                HideNow();
                e.Handled = true;
            }
        };
    }

    public event Action? QuitRequested;

    public Pane CurrentPane { get; private set; }

    public bool JustHidden => DateTime.UtcNow - _hiddenAt < TimeSpan.FromMilliseconds(350);

    public void ShowPane(Pane pane)
    {
        CurrentPane = pane;
        Host.Content = pane switch
        {
            Pane.Storage => _storage,
            Pane.Settings => _settings,
            _ => _memory,
        };
        var tab = pane switch
        {
            Pane.Storage => StorageTab,
            Pane.Settings => SettingsTab,
            _ => MemoryTab,
        };
        if (tab.IsChecked != true) tab.IsChecked = true;
        Scroller.ScrollToTop();
    }

    public void Open(Pane? pane = null)
    {
        if (pane is { } p) ShowPane(p);
        if (!IsVisible) Show();
        Place();
        Activate();
        Focus();
    }

    public void Toggle()
    {
        if (IsVisible) HideNow();
        else if (!JustHidden) Open();
    }

    public void HideNow()
    {
        if (!IsVisible) return;
        _hiddenAt = DateTime.UtcNow;
        Hide();
    }

    private void Place()
    {
        var area = WindowStyling.WorkAreaInDips(this);
        Left = area.Right - ActualWidth - 12;
        Top = area.Bottom - ActualHeight - 12;
        _placed = true;
    }

    private void OnTab(object sender, RoutedEventArgs e)
    {
        if (sender == StorageTab) ShowPane(Pane.Storage);
        else if (sender == SettingsTab) ShowPane(Pane.Settings);
        else ShowPane(Pane.Memory);
    }

    private void OnQuit(object sender, RoutedEventArgs e) => QuitRequested?.Invoke();

    public bool HasBeenPlaced => _placed;
}

internal static class WindowStyling
{
    public static void Apply(Window window, bool noActivate)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == 0) return;

        var round = Platform.Native.DwmwcpRound;
        Platform.Native.DwmSetWindowAttribute(hwnd, Platform.Native.DwmwaWindowCornerPreference, ref round, sizeof(int));

        var dark = Theme.IsDark ? 1 : 0;
        Platform.Native.DwmSetWindowAttribute(hwnd, Platform.Native.DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));

        var stroke = (window.TryFindResource("Stroke") as SolidColorBrush)?.Color ?? Colors.Gray;
        var colorRef = stroke.R | (stroke.G << 8) | (stroke.B << 16);
        Platform.Native.DwmSetWindowAttribute(hwnd, Platform.Native.DwmwaBorderColor, ref colorRef, sizeof(int));

        var style = (long)Platform.Native.GetWindowLongPtr(hwnd, Platform.Native.GwlExStyle);
        style |= Platform.Native.WsExToolWindow;
        if (noActivate) style |= Platform.Native.WsExNoActivate;
        Platform.Native.SetWindowLongPtr(hwnd, Platform.Native.GwlExStyle, (nint)style);
    }

    public static Rect WorkAreaInDips(Window window)
    {
        var cursor = System.Windows.Forms.Cursor.Position;
        var screen = System.Windows.Forms.Screen.FromPoint(cursor);
        var area = screen.WorkingArea;
        var dpi = VisualTreeHelper.GetDpi(window);
        return new Rect(area.Left / dpi.DpiScaleX, area.Top / dpi.DpiScaleY, area.Width / dpi.DpiScaleX, area.Height / dpi.DpiScaleY);
    }
}
