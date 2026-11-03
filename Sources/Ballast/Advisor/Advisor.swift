import Foundation

struct AdvisorInput {
    var vm: Probes.VMSample
    var swap: Probes.SwapSample?
    var pressure: Probes.Pressure
    var disk: Probes.DiskSample?
    var groups: [AppGroup]
    var growth: GrowthTracker
    /// Group id to the last time that app was frontmost in this session.
    var lastActive: [String: Date]
    var reclaimableStorage: UInt64?
}

enum Advisor {
    static func advise(_ input: AdvisorInput, prefs: Preferences, now: Date = Date()) -> [Advice] {
        var advice: [Advice] = []

        advice.append(contentsOf: systemAdvice(input, prefs: prefs))
        advice.append(contentsOf: processAdvice(input, prefs: prefs, now: now))

        return advice.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.isSystemWide != $1.isSystemWide { return $0.isSystemWide }
            return $0.reclaimBytes > $1.reclaimBytes
        }
    }

    // MARK: System level

    private static func systemAdvice(_ input: AdvisorInput, prefs: Preferences) -> [Advice] {
        var out: [Advice] = []

        if input.pressure > .normal {
            let compressed = Fmt.bytes(input.vm.compressedBytes)
            let swapped = input.swap.map { Fmt.bytes($0.used) } ?? "none"
            out.append(Advice(
                id: "pressure",
                headline: input.pressure == .critical
                    ? "Memory pressure is critical"
                    : "Memory is under pressure",
                detail: "\(compressed) compressed, \(swapped) on swap. The system is working to stay ahead of demand.",
                severity: input.pressure == .critical ? .critical : .warning,
                action: .none,
                reclaimBytes: 0,
                isSystemWide: true
            ))
        }

        if let swap = input.swap, swap.used >= prefs.swapThresholdBytes, input.pressure == .normal {
            out.append(Advice(
                id: "swap",
                headline: "\(Fmt.bytes(swap.used)) has been pushed to swap",
                detail: "Pressure has eased but the swap file stays large until the processes that caused it are restarted.",
                severity: .info,
                action: .none,
                reclaimBytes: 0,
                isSystemWide: true
            ))
        }

        if let disk = input.disk, disk.available <= prefs.lowDiskBytes {
            let reclaim = input.reclaimableStorage
            out.append(Advice(
                id: "disk",
                headline: "\(Fmt.bytes(disk.available)) free on disk",
                detail: reclaim.map { "A scan found \(Fmt.bytes($0)) of caches you can clear." }
                    ?? "Run a storage scan to see what can be cleared.",
                severity: disk.available <= prefs.lowDiskBytes / 2 ? .critical : .warning,
                action: .openStorage,
                reclaimBytes: reclaim ?? 0,
                isSystemWide: true
            ))
        }

        return out
    }

    // MARK: Per application

    private static func processAdvice(_ input: AdvisorInput, prefs: Preferences, now: Date) -> [Advice] {
        struct Candidate {
            var group: AppGroup
            var score: Double
            var clauses: [String]
            var isLeak: Bool
        }

        var candidates: [Candidate] = []

        for group in input.groups {
            guard !Grouping.isEssential(group) else { continue }
            guard group.memoryBytes > 512 * 1_048_576 else { continue }

            let growth = input.growth.growthRate(group.id)
            let isLeak = (growth ?? 0) >= prefs.growthBytesPerSecond
            let meetsThreshold = group.memoryBytes >= prefs.perAppThresholdBytes
            let pressureRelevant = input.pressure > .normal && group.memoryBytes >= 1_073_741_824

            guard meetsThreshold || pressureRelevant || isLeak else { continue }

            var score = Double(group.memoryBytes) / 1_073_741_824
            var clauses: [String] = ["\(Fmt.bytes(group.memoryBytes)) across \(group.processCount) process\(group.processCount == 1 ? "" : "es")"]

            // Telling someone to quit the window they are looking at is not advice.
            if group.isFrontmost, input.pressure != .critical { continue }

            if group.isFrontmost {
                score *= 0.5
                clauses.append("you are using it right now, so save your work first")
            } else if let last = input.lastActive[group.id] {
                let idle = now.timeIntervalSince(last)
                if idle >= prefs.idleMinutes * 60 {
                    score *= 1.6
                    clauses.append("last in front \(Fmt.duration(idle)) ago")
                }
            } else if group.isRunningApp {
                score *= 1.4
                clauses.append("has not been in front since Ballast started")
            }

            if group.isHidden {
                score *= 1.2
                clauses.append("window is hidden")
            }

            if Grouping.transient.contains(group.name) {
                score *= 0.3
                clauses.append("usually finishes on its own")
            }

            if let growth, isLeak {
                score *= 1.5
                clauses.append("growing \(Fmt.rate(growth)) for the last \(Fmt.duration(input.growth.observedSpan(group.id)))")
            }

            if group.isSystemOwned && !group.isRunningApp {
                score *= 0.4
            }

            let livesInside = Grouping.holdsLiveState.contains(group.name)
            if livesInside {
                score *= 0.5
                clauses.append("holds live state, so shut it down from inside it rather than quitting it")
            }

            candidates.append(Candidate(group: group, score: score, clauses: clauses, isLeak: isLeak))
        }

        return candidates
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { candidate in
                let group = candidate.group
                return Advice(
                    id: "quit:\(group.id)",
                    headline: candidate.isLeak
                        ? "\(group.name) keeps growing"
                        : "Quit \(group.name)",
                    detail: sentence(candidate.clauses)
                        + (candidate.isLeak ? ". Restarting it reclaims the memory." : "."),
                    severity: candidate.isLeak
                        ? .warning
                        : (input.pressure > .normal ? .warning : .info),
                    action: .quit(name: group.name, pids: group.pids),
                    reclaimBytes: group.memoryBytes
                )
            }
    }

    private static func sentence(_ clauses: [String]) -> String {
        guard clauses.count > 1 else { return clauses.first ?? "" }
        return clauses.dropLast().joined(separator: ", ") + " and " + clauses[clauses.count - 1]
    }
}
