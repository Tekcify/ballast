using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace Ballast.UI;

public sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon _icon;
    private readonly MonitorViewModel _monitor;
    private (int Percent, Pressure Pressure, bool Light) _drawn = (-1, Pressure.Normal, false);

    public TrayIcon(MonitorViewModel monitor)
    {
        _monitor = monitor;
        _icon = new Forms.NotifyIcon { Text = "Ballast", Visible = true };

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open Ballast", null, (_, _) => OpenRequested?.Invoke(Pane.Memory));
        menu.Items.Add("Storage", null, (_, _) => OpenRequested?.Invoke(Pane.Storage));
        menu.Items.Add("Settings", null, (_, _) => OpenRequested?.Invoke(Pane.Settings));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Ballast", null, (_, _) => QuitRequested?.Invoke());
        _icon.ContextMenuStrip = menu;

        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) ToggleRequested?.Invoke();
        };

        Update();
    }

    public event Action? ToggleRequested;
    public event Action<Pane>? OpenRequested;
    public event Action? QuitRequested;

    public void Update()
    {
        var tip = _monitor.Tooltip;
        _icon.Text = tip.Length > 127 ? tip[..127] : tip;

        var state = ((int)Math.Round(_monitor.UsedFraction * 100), _monitor.Pressure, Theme.TaskbarIsLight);
        if (state == _drawn) return;
        _drawn = state;

        var size = Forms.SystemInformation.SmallIconSize.Width;
        using var bitmap = Draw(Math.Max(size, 16), _monitor.UsedFraction, _monitor.Pressure, state.Item3);
        var handle = bitmap.GetHicon();
        var previous = _icon.Icon;
        using (var icon = Icon.FromHandle(handle))
        {
            _icon.Icon = (Icon)icon.Clone();
        }
        previous?.Dispose();
        DestroyIcon(handle);
    }

    private static Bitmap Draw(int size, double fraction, Pressure pressure, bool lightTaskbar)
    {
        var bitmap = new Bitmap(size, size);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);

        var ink = lightTaskbar ? Color.FromArgb(255, 28, 28, 30) : Color.FromArgb(255, 245, 245, 247);
        var fill = pressure switch
        {
            Pressure.Critical => Color.FromArgb(255, 226, 92, 80),
            Pressure.Warning => Color.FromArgb(255, 232, 145, 60),
            _ => ink,
        };

        var unit = size / 16f;
        var body = new RectangleF(3.5f * unit, 1.5f * unit, 9f * unit, 13f * unit);
        using (var path = Rounded(body, 2.6f * unit))
        using (var pen = new Pen(ink, 1.4f * unit))
        {
            g.DrawPath(pen, path);
        }

        var inner = RectangleF.Inflate(body, -2.1f * unit, -2.1f * unit);
        var level = (float)Math.Clamp(fraction, 0.08, 1);
        var filled = new RectangleF(inner.X, inner.Bottom - inner.Height * level, inner.Width, inner.Height * level);
        using (var path = Rounded(filled, 1.1f * unit))
        using (var brush = new SolidBrush(fill))
        {
            g.FillPath(brush, path);
        }
        return bitmap;
    }

    private static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        var d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0.5f)
        {
            path.AddRectangle(r);
            return path;
        }
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint handle);
}
