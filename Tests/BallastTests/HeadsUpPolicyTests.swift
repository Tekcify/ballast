import Foundation
import Testing
@testable import Ballast

struct HeadsUpPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func oneWarningSampleIsTreatedAsABlip() {
        var policy = HeadsUpPolicy()
        #expect(policy.observe(.warning, isVisible: false, now: at(0)) == .none)
        #expect(policy.observe(.normal, isVisible: false, now: at(5)) == .none)
        #expect(policy.observe(.warning, isVisible: false, now: at(10)) == .none)
    }

    @Test func sustainedWarningPresents() {
        var policy = HeadsUpPolicy()
        #expect(policy.observe(.warning, isVisible: false, now: at(0)) == .none)
        #expect(policy.observe(.warning, isVisible: false, now: at(5)) == .present)
    }

    @Test func criticalPresentsImmediately() {
        var policy = HeadsUpPolicy()
        #expect(policy.observe(.critical, isVisible: false, now: at(0)) == .present)
    }

    @Test func dismissedCardStaysQuietDuringCooldown() {
        var policy = HeadsUpPolicy()
        _ = policy.observe(.warning, isVisible: false, now: at(0))
        #expect(policy.observe(.warning, isVisible: false, now: at(5)) == .present)
        #expect(policy.observe(.warning, isVisible: false, now: at(60)) == .none)
        #expect(policy.observe(.warning, isVisible: false, now: at(16 * 60)) == .present)
    }

    @Test func escalationBreaksThroughCooldown() {
        var policy = HeadsUpPolicy()
        _ = policy.observe(.warning, isVisible: false, now: at(0))
        #expect(policy.observe(.warning, isVisible: false, now: at(5)) == .present)
        #expect(policy.observe(.critical, isVisible: false, now: at(30)) == .present)
    }

    @Test func snoozeHoldsEvenAtCritical() {
        var policy = HeadsUpPolicy()
        policy.snooze(for: 3600, now: at(0))
        #expect(policy.observe(.critical, isVisible: false, now: at(10)) == .none)
        #expect(policy.observe(.critical, isVisible: false, now: at(3601)) == .present)
    }

    @Test func visibleCardRecoversAfterTwoCalmSamples() {
        var policy = HeadsUpPolicy()
        #expect(policy.observe(.critical, isVisible: false, now: at(0)) == .present)
        #expect(policy.observe(.normal, isVisible: true, now: at(5)) == .none)
        #expect(policy.observe(.normal, isVisible: true, now: at(10)) == .recover)
    }
}
