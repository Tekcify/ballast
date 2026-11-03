import BallastCore
import Foundation

/// The Windows counterpart of the Mac app's `Monitor`, memory side only. Each
/// `refresh()` reads the system, groups processes into apps and asks the shared
/// `Advisor` what to do about it.
package final class WindowsMonitor {
    package let prefs = Preferences()
    package private(set) var sample: WindowsSample?
    package private(set) var groups: [AppGroup] = []
    package private(set) var advice: [Advice] = []

    private var growth = GrowthTracker()
    private var lastActive: [String: Date] = [:]
    private var previousCPU: [pid_t: (nanos: UInt64, at: Date)] = [:]

    package init() {}

    /// Returns false when Windows would not report memory at all.
    @discardableResult
    package func refresh() -> Bool {
        guard let sample = Probes.windowsSample() else { return false }
        self.sample = sample

        groups = Grouping.build(from: sample, cpuPercents: cpuPercents(sample))
        for group in groups where group.isFrontmost { lastActive[group.id] = sample.at }
        growth.record(groups, at: sample.at)

        advice = Advisor.advise(
            AdvisorInput(
                vm: sample.vm,
                swap: sample.swap,
                pressure: sample.pressure,
                disk: sample.disk,
                groups: groups,
                growth: growth,
                lastActive: lastActive,
                reclaimableStorage: nil
            ),
            prefs: prefs,
            now: sample.at
        )
        return true
    }

    package var usedFraction: Double {
        guard let vm = sample?.vm, vm.totalBytes > 0 else { return 0 }
        return min(Double(vm.usedBytes) / Double(vm.totalBytes), 1)
    }

    /// Apps big enough to be worth listing.
    package var listedGroups: [AppGroup] {
        groups.filter { $0.memoryBytes >= 50 * 1_048_576 }
    }

    /// The advice that suggests quitting an app, with who to quit.
    package var quitSuggestions: [(advice: Advice, name: String, pids: [pid_t])] {
        advice.compactMap { item in
            guard case .quit(let name, let pids) = item.action else { return nil }
            return (item, name, pids)
        }
    }

    private func cpuPercents(_ sample: WindowsSample) -> [pid_t: Double] {
        var out: [pid_t: Double] = [:]
        var next: [pid_t: (nanos: UInt64, at: Date)] = [:]
        for process in sample.processes {
            guard let nanos = process.cpuNanos else { continue }
            next[process.pid] = (nanos, sample.at)
            guard let previous = previousCPU[process.pid] else { continue }
            let elapsed = sample.at.timeIntervalSince(previous.at)
            guard elapsed > 0.5, nanos >= previous.nanos else { continue }
            out[process.pid] = Double(nanos - previous.nanos) / 1_000_000_000 / elapsed * 100
        }
        previousCPU = next
        return out
    }
}
