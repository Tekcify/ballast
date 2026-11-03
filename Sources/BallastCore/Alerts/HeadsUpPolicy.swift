import Foundation

/// Decides when the heads-up card appears. A single pressured sample is often a
/// blip, so warning has to hold for two samples; critical shows at once. After a
/// dismissal it stays quiet for the cooldown unless pressure gets worse.
package nonisolated struct HeadsUpPolicy: Sendable {
    package enum Decision: Equatable, Sendable {
        case present
        case recover
        case none
    }

    package var cooldown: TimeInterval = 15 * 60
    package private(set) var snoozedUntil: Date?
    private var strainedSamples = 0
    private var calmSamples = 0
    private var lastShownAt: Date?
    private var lastShownLevel: Probes.Pressure = .normal

    package init() {}

    package mutating func observe(_ pressure: Probes.Pressure, isVisible: Bool, now: Date) -> Decision {
        guard pressure > .normal else {
            strainedSamples = 0
            calmSamples += 1
            return isVisible && calmSamples >= 2 ? .recover : .none
        }

        calmSamples = 0
        strainedSamples += 1
        if isVisible {
            lastShownLevel = max(lastShownLevel, pressure)
            return .none
        }
        if let snoozedUntil, now < snoozedUntil { return .none }
        guard pressure == .critical || strainedSamples >= 2 else { return .none }
        if let lastShownAt, now.timeIntervalSince(lastShownAt) < cooldown, pressure <= lastShownLevel {
            return .none
        }

        lastShownAt = now
        lastShownLevel = pressure
        return .present
    }

    package mutating func snooze(for duration: TimeInterval, now: Date) {
        snoozedUntil = now.addingTimeInterval(duration)
    }

    /// A dismissal starts the cooldown even when the card was shown some other
    /// way, such as a preview, or it would pop straight back on the next sample.
    package mutating func dismissed(at pressure: Probes.Pressure, now: Date) {
        lastShownAt = now
        lastShownLevel = max(lastShownLevel, pressure)
    }
}
