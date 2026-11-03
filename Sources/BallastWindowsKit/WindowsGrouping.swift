import BallastCore
import Foundation

/// How Windows processes are folded into apps. Windows has no app bundles, but
/// an app's helpers run the same exe (every Chrome process is `chrome.exe` in
/// the same folder), so processes are grouped by their image path.
extension Grouping {
    private static var descriptionCache: [String: String?] = [:]

    static func displayName(path: String?, fallback: String) -> String {
        guard let path else { return fallback }
        if let cached = descriptionCache[path] { return cached ?? fallback }
        let description = Probes.fileDescription(of: path)
        descriptionCache[path] = description
        return description ?? fallback
    }

    package static func build(from sample: WindowsSample, cpuPercents: [pid_t: Double]) -> [AppGroup] {
        struct Accumulator {
            var name: String
            var path: String?
            var pids: [pid_t] = []
            var memory: UInt64 = 0
            var cpu: Double = 0
            var systemOwned = false
            var started = Date.distantFuture
        }

        let systemRoot = Probes.windowsDirectory().map { $0.lowercased() + "\\" }
        var buckets: [String: Accumulator] = [:]

        for process in sample.processes where process.memoryBytes > 0 {
            let key = process.path?.lowercased() ?? process.name.lowercased()
            var accumulator = buckets[key] ?? Accumulator(name: process.name, path: process.path)
            accumulator.pids.append(process.pid)
            accumulator.memory += process.memoryBytes
            accumulator.cpu += cpuPercents[process.pid] ?? 0
            let underWindows = systemRoot.map { process.path?.lowercased().hasPrefix($0) ?? false } ?? false
            accumulator.systemOwned = accumulator.systemOwned || process.path == nil || underWindows
            if let started = process.startedAt { accumulator.started = min(accumulator.started, started) }
            buckets[key] = accumulator
        }

        return buckets.map { key, value in
            let pids = Set(value.pids)
            let windowed = !pids.isDisjoint(with: sample.windowedPids)
            return AppGroup(
                id: key,
                name: displayName(path: value.path, fallback: value.name),
                bundleIdentifier: nil,
                bundlePath: value.path,
                projectPath: nil,
                pids: value.pids.sorted(),
                memoryBytes: value.memory,
                cpuPercent: value.cpu,
                isApproximate: false,
                isSystemOwned: value.systemOwned,
                isRunningApp: windowed,
                isFrontmost: sample.frontmostPid.map(pids.contains) ?? false,
                isHidden: windowed && pids.isDisjoint(with: sample.restoredPids),
                startedAt: value.started == .distantFuture ? sample.at : value.started
            )
        }
        .sorted { $0.memoryBytes > $1.memoryBytes }
    }
}
