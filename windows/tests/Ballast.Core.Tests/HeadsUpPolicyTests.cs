namespace Ballast.Core.Tests;

public class HeadsUpPolicyTests
{
    private static readonly DateTime Start = new(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    private static DateTime At(double seconds) => Start.AddSeconds(seconds);

    [Fact]
    public void OneWarningSampleIsTreatedAsABlip()
    {
        var policy = new HeadsUpPolicy();
        Assert.Equal(HeadsUpDecision.None, policy.Observe(Pressure.Warning, false, At(0)));
        Assert.Equal(HeadsUpDecision.None, policy.Observe(Pressure.Normal, false, At(5)));
        Assert.Equal(HeadsUpDecision.None, policy.Observe(Pressure.Warning, false, At(10)));
    }

    [Fact]
    public void SustainedWarningPresents()
    {
        var policy = new HeadsUpPolicy();
        Assert.Equal(HeadsUpDecision.None, policy.Observe(Pressure.Warning, false, At(0)));
        Assert.Equal(HeadsUpDecision.Present, policy.Observe(Pressure.Warning, false, At(5)));
    }

    [Fact]
    public void CriticalPresentsImmediately()
    {
        var policy = new HeadsUpPolicy();
        Assert.Equal(HeadsUpDecision.Present, policy.Observe(Pressure.Critical, false, At(0)));
    }

    [Fact]
    public void DismissedCardStaysQuietDuringCooldown()
    {
        var policy = new HeadsUpPolicy();
        policy.Observe(Pressure.Warning, false, At(0));
        Assert.Equal(HeadsUpDecision.Present, policy.Observe(Pressure.Warning, false, At(5)));
        Assert.Equal(HeadsUpDecision.None, policy.Observe(Pressure.Warning, false, At(60)));
        Assert.Equal(HeadsUpDecision.Present, policy.Observe(Pressure.Warning, false, At(16 * 60)));
    }

    [Fact]
    public void EscalationBreaksThroughCooldown()
    {
        var policy = new HeadsUpPolicy();
        policy.Observe(Pressure.Warning, false, At(0));
        Assert.Equal(HeadsUpDecision.Present, policy.Observe(Pressure.Warning, false, At(5)));
        Assert.Equal(HeadsUpDecision.Present, policy.Observe(Pressure.Critical, false, At(30)));
    }

    [Fact]
    public void SnoozeHoldsEvenAtCritical()
    {
        var policy = new HeadsUpPolicy();
        policy.Snooze(TimeSpan.FromHours(1), At(0));
        Assert.Equal(HeadsUpDecision.None, policy.Observe(Pressure.Critical, false, At(10)));
        Assert.Equal(HeadsUpDecision.Present, policy.Observe(Pressure.Critical, false, At(3601)));
    }

    [Fact]
    public void DismissingACardShownOutsideThePolicyStartsTheCooldown()
    {
        var policy = new HeadsUpPolicy();
        policy.Observe(Pressure.Warning, true, At(0));
        policy.Dismissed(Pressure.Warning, At(1));
        Assert.Equal(HeadsUpDecision.None, policy.Observe(Pressure.Warning, false, At(5)));
        Assert.Equal(HeadsUpDecision.None, policy.Observe(Pressure.Warning, false, At(10)));
        Assert.Equal(HeadsUpDecision.Present, policy.Observe(Pressure.Critical, false, At(15)));
    }

    [Fact]
    public void VisibleCardRecoversAfterTwoCalmSamples()
    {
        var policy = new HeadsUpPolicy();
        Assert.Equal(HeadsUpDecision.Present, policy.Observe(Pressure.Critical, false, At(0)));
        Assert.Equal(HeadsUpDecision.None, policy.Observe(Pressure.Normal, true, At(5)));
        Assert.Equal(HeadsUpDecision.Recover, policy.Observe(Pressure.Normal, true, At(10)));
    }
}
