import Foundation

nonisolated struct CleanReport: Sendable {
    var freedBytes: UInt64
    var removed: Int
    var trashed: Int
    var failures: [(path: String, reason: String)]
    var diskAvailableBefore: UInt64?
    var diskAvailableAfter: UInt64?

    /// What the volume actually gained, which can differ from the sum of item
    /// sizes because of snapshots, Trash and other activity during the run.
    var measuredGain: Int64? {
        guard let before = diskAvailableBefore, let after = diskAvailableAfter else { return nil }
        return Int64(after) - Int64(before)
    }

    var summary: String {
        var parts: [String] = []
        if removed > 0 { parts.append("\(removed) deleted") }
        if trashed > 0 { parts.append("\(trashed) moved to Trash") }
        if !failures.isEmpty { parts.append("\(failures.count) skipped") }
        let detail = parts.isEmpty ? "nothing to do" : parts.joined(separator: ", ")
        return "\(Fmt.bytes(freedBytes)) cleared · \(detail)"
    }
}

actor Cleaner {
    private let home: String
    private let guardrail: DeletionGuard
    private let fileManager = FileManager.default

    init(home: String = NSHomeDirectory()) {
        self.home = home
        self.guardrail = DeletionGuard(
            home: home, targets: CleanupTarget.all(home: home, includeDependencies: true)
        )
    }

    /// Safe tier items are deleted outright because trashing them would keep the
    /// space occupied. Everything else goes to Trash so it can be put back.
    func clean(
        _ items: [CleanupItem],
        onProgress: @Sendable @escaping (ScanProgress) -> Void
    ) async -> CleanReport {
        let before = Probes.diskSample()?.available
        var freed: UInt64 = 0
        var removed = 0
        var trashed = 0
        var failures: [(path: String, reason: String)] = []
        var log: [LogEntry] = []

        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            onProgress(ScanProgress(stage: item.title, completed: index, total: items.count))

            guard item.risk.isSelectable else {
                failures.append((item.path, "report only"))
                continue
            }
            guard !item.isProtected else {
                failures.append((item.path, "in use by \(item.heldBy ?? "a running process")"))
                continue
            }
            if let reason = guardrail.rejection(for: item.path) {
                failures.append((item.path, reason))
                continue
            }

            let method: String
            do {
                if item.path == home + "/.Trash" {
                    try emptyContents(of: item.path)
                    method = "emptied"
                    removed += 1
                } else if item.risk.usesTrash {
                    var resulting: NSURL?
                    try fileManager.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resulting)
                    method = "trashed"
                    trashed += 1
                } else {
                    try fileManager.removeItem(atPath: item.path)
                    method = "deleted"
                    removed += 1
                }
                freed += item.sizeBytes
                log.append(LogEntry(
                    at: Date(), path: item.path, bytes: item.sizeBytes,
                    method: method, risk: item.risk.label, category: item.category
                ))
            } catch {
                failures.append((item.path, error.localizedDescription))
            }
        }

        append(log)
        onProgress(ScanProgress(stage: "Done", completed: items.count, total: items.count))

        return CleanReport(
            freedBytes: freed,
            removed: removed,
            trashed: trashed,
            failures: failures,
            diskAvailableBefore: before,
            diskAvailableAfter: Probes.diskSample()?.available
        )
    }

    private func emptyContents(of directory: String) throws {
        for name in try fileManager.contentsOfDirectory(atPath: directory) {
            try fileManager.removeItem(atPath: directory + "/" + name)
        }
    }

    // MARK: Audit log

    private struct LogEntry: Codable {
        var at: Date
        var path: String
        var bytes: UInt64
        var method: String
        var risk: String
        var category: String
    }

    static var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Ballast/cleanup-log.jsonl")
    }

    private func append(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        let url = Self.logURL
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var blob = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: blob)
        } else {
            try? blob.write(to: url)
        }
    }
}
