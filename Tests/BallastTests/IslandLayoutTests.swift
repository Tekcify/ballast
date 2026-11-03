import CoreGraphics
import Testing
@testable import Ballast

struct IslandLayoutTests {
    @Test func notchIsTheGapBetweenTheTwoMenuBarAreas() {
        let notch = IslandLayout.notchSize(screenWidth: 1800, safeTop: 38, leftWidth: 790, rightWidth: 790)
        #expect(notch == CGSize(width: 220, height: 38))
    }

    @Test func displaysWithoutANotchReportNone() {
        #expect(IslandLayout.notchSize(screenWidth: 3440, safeTop: 0, leftWidth: nil, rightWidth: nil) == nil)
        #expect(IslandLayout.notchSize(screenWidth: 1800, safeTop: 38, leftWidth: 900, rightWidth: 900) == nil)
    }

    @Test func coreFollowsTheNotchOrTheCustomSize() {
        let notch = CGSize(width: 220, height: 38)
        let custom = CGSize(width: 180, height: 30)
        #expect(IslandLayout.core(notch: notch, matchNotch: true, custom: custom) == notch)
        #expect(IslandLayout.core(notch: nil, matchNotch: true, custom: custom) == IslandLayout.fallbackCore)
        #expect(IslandLayout.core(notch: notch, matchNotch: false, custom: custom) == custom)
    }

    @Test func restingPillWrapsTheCoreWithTwoWings() {
        let size = IslandLayout.compactSize(core: CGSize(width: 220, height: 38))
        #expect(size.width == 220 + 2 * (IslandLayout.defaultWing + IslandLayout.shoulder))
        #expect(size.height == 38)
        let tight = IslandLayout.compactSize(core: CGSize(width: 220, height: 38), wing: 32)
        #expect(tight.width == 220 + 2 * (32 + IslandLayout.shoulder))
    }

    @Test func windowSitsFlushWithTheTopAndCentred() {
        let screen = CGRect(x: -1566, y: 1169, width: 3440, height: 1440)
        let frame = IslandLayout.windowFrame(size: CGSize(width: 480, height: 760), screen: screen)
        #expect(frame.maxY == screen.maxY)
        #expect(frame.midX == screen.midX)
    }

    @Test func readoutSpendsMostOfTheCycleOnMemory() {
        let samples = (0..<120).map { IslandLayout.readout(at: Double($0) / 10 + 1_000_000) }
        #expect(samples.filter { $0 == .memory }.count == 60)
        #expect(samples.filter { $0 == .cpu }.count == 30)
        #expect(samples.filter { $0 == .disk }.count == 30)
        #expect(IslandLayout.readout(at: 0) == .memory)
        #expect(IslandLayout.readout(at: 6) == .cpu)
        #expect(IslandLayout.readout(at: 9) == .disk)
        #expect(IslandLayout.readout(at: 12) == .memory)
        #expect(IslandLayout.readout(at: -1) == .disk)
    }

    @Test func cpuUsageIsTheBusyShareOfNewTicks() {
        let earlier = Probes.CPUTicks(busy: 1_000, total: 4_000)
        #expect(Probes.CPUTicks(busy: 1_250, total: 5_000).usage(since: earlier) == 0.25)
        #expect(Probes.CPUTicks(busy: 1_000, total: 4_000).usage(since: earlier) == nil)
    }

    @Test func alertOutranksActivitiesWhichOutrankTheReadout() {
        typealias L = IslandLayout
        #expect(L.mode(alert: true, strained: true, scanning: true, cleaning: true, liveActivities: true, alwaysOn: true) == .alert)
        #expect(L.mode(alert: true, strained: false, scanning: false, cleaning: false, liveActivities: true, alwaysOn: false) == .recovered)
        #expect(L.mode(alert: false, strained: true, scanning: true, cleaning: true, liveActivities: true, alwaysOn: true) == .cleaning)
        #expect(L.mode(alert: false, strained: false, scanning: true, cleaning: false, liveActivities: true, alwaysOn: true) == .scanning)
        #expect(L.mode(alert: false, strained: false, scanning: true, cleaning: false, liveActivities: false, alwaysOn: true) == .glance)
        #expect(L.mode(alert: false, strained: true, scanning: true, cleaning: false, liveActivities: false, alwaysOn: false) == nil)
    }
}
