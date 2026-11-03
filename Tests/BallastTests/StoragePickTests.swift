import Foundation
import Testing
@testable import Ballast

struct StoragePickTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func item(
        _ risk: Risk, idleDays: Double?, heldBy: String? = nil, size: UInt64 = 5 << 30
    ) -> CleanupItem {
        CleanupItem(
            path: "/tmp/\(UUID().uuidString)", title: "x", category: "c", risk: risk,
            reason: "r", sizeBytes: size, heldBy: heldBy,
            lastTouched: idleDays.map { now.addingTimeInterval(-$0 * 86_400) }
        )
    }

    @Test func safeCachesArePickedByDefaultAndBySmartPick() {
        let safe = item(.safe, idleDays: 2)
        #expect(safe.isDefaultPick(at: now))
        #expect(safe.isSmartPick(at: now))
    }

    @Test func rebuildablesNeedAMonthOfIdleForSmartPick() {
        #expect(!item(.review, idleDays: 29).isSmartPick(at: now))
        #expect(item(.review, idleDays: 31).isSmartPick(at: now))
        #expect(!item(.review, idleDays: 31).isDefaultPick(at: now))
        #expect(!item(.review, idleDays: nil).isSmartPick(at: now))
    }

    @Test func busyFoldersAreNeverPicked() {
        let busy = item(.safe, idleDays: 2.0 / 1440)
        #expect(busy.isBusy(at: now))
        #expect(!busy.isDefaultPick(at: now))
        #expect(!busy.isSmartPick(at: now))
    }

    @Test func carefulKeptAndHeldItemsAreNeverPicked() {
        #expect(!item(.caution, idleDays: 400).isSmartPick(at: now))
        #expect(!item(.reportOnly, idleDays: 400).isSmartPick(at: now))
        #expect(!item(.safe, idleDays: 40, heldBy: "node").isSmartPick(at: now))
        #expect(!item(.safe, idleDays: 40, size: 0).isSmartPick(at: now))
    }

    @Test func scanCacheRoundTripsAndDropsVanishedPaths() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ballast-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let kept = folder.appendingPathComponent("kept").path
        try FileManager.default.createDirectory(atPath: kept, withIntermediateDirectories: true)
        var present = item(.review, idleDays: 40)
        present.path = kept
        present.projectRoot = folder.path
        var gone = item(.safe, idleDays: 1)
        gone.path = folder.appendingPathComponent("gone").path

        let url = folder.appendingPathComponent("last-scan.json")
        ScanCache.save([present, gone], to: url)
        let loaded = ScanCache.load(from: url)

        #expect(loaded.map(\.path) == [kept])
        #expect(loaded.first?.risk == .review)
        #expect(loaded.first?.projectRoot == folder.path)
        #expect(loaded.first?.sizeBytes == present.sizeBytes)
        let touched = try #require(loaded.first?.lastTouched)
        #expect(abs(touched.timeIntervalSince(present.lastTouched!)) < 1)
    }
}
