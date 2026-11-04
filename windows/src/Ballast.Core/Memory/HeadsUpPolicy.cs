namespace Ballast.Core;

public enum HeadsUpDecision
{
    None,
    Present,
    Recover,
}

public sealed class HeadsUpPolicy
{
    private int _strainedSamples;
    private int _calmSamples;
    private DateTime? _lastShownAt;
    private Pressure _lastShownLevel = Pressure.Normal;

    public TimeSpan Cooldown { get; set; } = TimeSpan.FromMinutes(15);
    public DateTime? SnoozedUntil { get; private set; }

    public HeadsUpDecision Observe(Pressure pressure, bool isVisible, DateTime now)
    {
        if (pressure <= Pressure.Normal)
        {
            _strainedSamples = 0;
            _calmSamples++;
            return isVisible && _calmSamples >= 2 ? HeadsUpDecision.Recover : HeadsUpDecision.None;
        }

        _calmSamples = 0;
        _strainedSamples++;
        if (isVisible)
        {
            _lastShownLevel = Max(_lastShownLevel, pressure);
            return HeadsUpDecision.None;
        }
        if (SnoozedUntil is { } until && now < until) return HeadsUpDecision.None;
        if (pressure != Pressure.Critical && _strainedSamples < 2) return HeadsUpDecision.None;
        if (_lastShownAt is { } shown && now - shown < Cooldown && pressure <= _lastShownLevel)
            return HeadsUpDecision.None;

        _lastShownAt = now;
        _lastShownLevel = pressure;
        return HeadsUpDecision.Present;
    }

    public void Snooze(TimeSpan duration, DateTime now) => SnoozedUntil = now + duration;

    public void Dismissed(Pressure pressure, DateTime now)
    {
        _lastShownAt = now;
        _lastShownLevel = Max(_lastShownLevel, pressure);
    }

    private static Pressure Max(Pressure a, Pressure b) => a > b ? a : b;
}
