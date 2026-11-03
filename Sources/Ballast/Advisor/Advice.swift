import Foundation

struct Advice: Identifiable, Sendable {
    enum Severity: Int, Sendable, Comparable {
        case info, warning, critical
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum Action: Sendable, Equatable {
        case quit(name: String, pids: [pid_t])
        case openStorage
        case none
    }

    var id: String
    var headline: String
    var detail: String
    var severity: Severity
    var action: Action
    /// Bytes this advice would reclaim, used for ordering and for the alert text.
    var reclaimBytes: UInt64
    /// System wide context is listed before any individual app at equal severity,
    /// because it explains why the app advice is there at all.
    var isSystemWide = false
}

/// Memory footprint history for one group, used to separate a process that is
/// simply large from one that is steadily growing.
struct GrowthTracker: Sendable {
    private var samples: [String: [(at: Date, bytes: UInt64)]] = [:]
    private let window = 16

    mutating func record(_ groups: [AppGroup], at now: Date = Date()) {
        var live: Set<String> = []
        for group in groups {
            live.insert(group.id)
            var series = samples[group.id] ?? []
            series.append((now, group.memoryBytes))
            if series.count > window { series.removeFirst(series.count - window) }
            samples[group.id] = series
        }
        samples = samples.filter { live.contains($0.key) }
    }

    /// Bytes per second of sustained growth, or nil when the series is too short
    /// or the footprint has gone down at any point in the window.
    func growthRate(_ groupID: String) -> Double? {
        guard let series = samples[groupID], series.count >= 6 else { return nil }
        let span = series[series.count - 1].at.timeIntervalSince(series[0].at)
        guard span > 60 else { return nil }

        for index in 1..<series.count where series[index].bytes < series[index - 1].bytes {
            return nil
        }
        let delta = Double(series[series.count - 1].bytes) - Double(series[0].bytes)
        guard delta > 0 else { return nil }
        return delta / span
    }

    func observedSpan(_ groupID: String) -> TimeInterval {
        guard let series = samples[groupID], series.count >= 2 else { return 0 }
        return series[series.count - 1].at.timeIntervalSince(series[0].at)
    }
}
