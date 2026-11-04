using System.Windows;
using System.Windows.Media;

namespace Ballast.UI;

public sealed record MeterSegment(Brush Brush, double Fraction);

public sealed class MeterBar : FrameworkElement
{
    public static readonly DependencyProperty SegmentsProperty = DependencyProperty.Register(
        nameof(Segments), typeof(IReadOnlyList<MeterSegment>), typeof(MeterBar),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty TrackProperty = DependencyProperty.Register(
        nameof(Track), typeof(Brush), typeof(MeterBar),
        new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));

    public IReadOnlyList<MeterSegment>? Segments
    {
        get => (IReadOnlyList<MeterSegment>?)GetValue(SegmentsProperty);
        set => SetValue(SegmentsProperty, value);
    }

    public Brush Track
    {
        get => (Brush)GetValue(TrackProperty);
        set => SetValue(TrackProperty, value);
    }

    protected override Size MeasureOverride(Size availableSize) =>
        new(double.IsInfinity(availableSize.Width) ? 100 : availableSize.Width, double.IsNaN(Height) ? 8 : Height);

    protected override void OnRender(DrawingContext dc)
    {
        var width = ActualWidth;
        var height = ActualHeight;
        if (width <= 0 || height <= 0) return;

        var radius = height / 2;
        var clip = new RectangleGeometry(new Rect(0, 0, width, height), radius, radius);
        dc.PushClip(clip);
        dc.DrawRectangle(Track, null, new Rect(0, 0, width, height));

        var x = 0.0;
        var gap = 2.0;
        var segments = (Segments ?? []).Where(s => s.Fraction > 0.001).ToList();
        for (var i = 0; i < segments.Count; i++)
        {
            var w = Math.Max(Math.Min(segments[i].Fraction, 1) * width, 2);
            if (x + w > width) w = width - x;
            if (w <= 0) break;
            var drawn = i < segments.Count - 1 ? Math.Max(w - gap, 1) : w;
            dc.DrawRectangle(segments[i].Brush, null, new Rect(x, 0, drawn, height));
            x += w;
        }
        dc.Pop();
    }
}
