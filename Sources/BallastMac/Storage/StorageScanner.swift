import BallastCore
import Foundation

nonisolated struct ScanProgress: Sendable {
    var stage: String
    var completed: Int
    var total: Int
}

/// Measures every cleanup target. Sizes come from `du`, which is far quicker on
/// deep trees than walking them in process, and results are reported as each
/// batch lands so the list fills in rather than blocking on the slowest tree.
actor StorageScanner {
    nonisolated private struct Candidate: Sendable {
        var path: String
        var target: CleanupTarget
        var projectRoot: String?
    }

    private let home: String
    private let fileManager = FileManager.default

    init(home: String = NSHomeDirectory()) { self.home = home }

    func scan(
        includeDependencies: Bool = false,
        onProgress: @Sendable @escaping (ScanProgress) -> Void,
        onItems: @Sendable @escaping ([CleanupItem]) -> Void
    ) async {
        let targets = CleanupTarget.all(home: home, includeDependencies: includeDependencies)
        onProgress(ScanProgress(stage: "Hunting for build caches", completed: 0, total: 1))

        let liveDirectories = Probes.liveWorkingDirectories(home: home)
        // One `find` for every searched name, rather than one pass per target.
        let matches = runSearch(for: targets)
        if Task.isCancelled { return }

        var candidates: [Candidate] = []
        for target in targets {
            if Task.isCancelled { return }
            candidates.append(contentsOf: expand(target, matches: matches))
        }

        candidates = dedupe(candidates)
        let total = candidates.count
        var completed = 0
        onProgress(ScanProgress(stage: "Sizing things up", completed: 0, total: total))

        // Four concurrent `du` calls keep the disk busy without saturating it.
        let batches = stride(from: 0, to: candidates.count, by: 12).map {
            Array(candidates[$0..<min($0 + 12, candidates.count)])
        }

        await withTaskGroup(of: [CleanupItem].self) { group in
            var next = 0
            let limit = 4

            func addBatch() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask { [self] in
                    measure(batch, liveDirectories: liveDirectories)
                }
            }

            for _ in 0..<min(limit, batches.count) { addBatch() }

            for await items in group {
                if Task.isCancelled { return }
                completed += items.count
                onProgress(ScanProgress(stage: "Sizing things up", completed: completed, total: total))
                if !items.isEmpty { onItems(items) }
                addBatch()
            }
        }

        onProgress(ScanProgress(stage: "Done", completed: total, total: total))
    }

    // MARK: Expansion

    /// A path can be reached by more than one target: `~/Library/Caches/go-build`
    /// is both an explicit target and a child of the caches sweep. Keep the more
    /// cautious classification and the more specific description.
    private func dedupe(_ candidates: [Candidate]) -> [Candidate] {
        var best: [String: Candidate] = [:]
        for candidate in candidates {
            guard let existing = best[candidate.path] else {
                best[candidate.path] = candidate
                continue
            }
            if rank(candidate) > rank(existing) { best[candidate.path] = candidate }
        }
        return Array(best.values)
    }

    private func rank(_ candidate: Candidate) -> Int {
        let specificity = switch candidate.target.shape {
        case .directory: 3
        case .search: 2
        case .children: 1
        }
        return candidate.target.risk.rawValue * 10 + specificity
    }

    /// Runs a single `find` covering every name any search target asks for, then
    /// hands back the matches keyed by directory name.
    private func runSearch(for targets: [CleanupTarget]) -> [String: [String]] {
        var names: Set<String> = []
        var depth = 0
        for target in targets {
            guard case .search(_, let targetNames, let maxDepth) = target.shape else { continue }
            names.formUnion(targetNames)
            depth = max(depth, maxDepth)
        }
        guard !names.isEmpty else { return [:] }

        var grouped: [String: [String]] = [:]
        for path in search(root: home, names: Array(names).sorted(), maxDepth: depth) {
            grouped[(path as NSString).lastPathComponent, default: []].append(path)
        }
        return grouped
    }

    private func expand(_ target: CleanupTarget, matches: [String: [String]]) -> [Candidate] {
        switch target.shape {
        case .directory(let path):
            guard isDirectory(path) else { return [] }
            return [Candidate(path: path, target: target, projectRoot: nil)]

        case .children(let base):
            guard let names = try? fileManager.contentsOfDirectory(atPath: base) else { return [] }
            return names
                .map { base + "/" + $0 }
                .filter { isDirectory($0) }
                .map { Candidate(path: $0, target: target, projectRoot: nil) }

        case .search(_, let names, let maxDepth):
            var found: [Candidate] = []
            let homeDepth = home.split(separator: "/").count

            for name in names {
                for match in matches[name] ?? [] {
                    // Each target keeps its own depth limit even though one find
                    // covered the deepest of them.
                    let relativeDepth = match.split(separator: "/").count - homeDepth
                    guard relativeDepth <= maxDepth else { continue }

                    let projectRoot = (match as NSString).deletingLastPathComponent
                    if let days = target.staleAfterDays, !isStale(projectRoot, days: days) { continue }

                    if target.searchSubpaths.isEmpty {
                        found.append(Candidate(path: match, target: target, projectRoot: projectRoot))
                    } else {
                        for sub in target.searchSubpaths {
                            let path = match + "/" + sub
                            guard isDirectory(path) else { continue }
                            found.append(Candidate(path: path, target: target, projectRoot: projectRoot))
                        }
                    }
                }
            }
            return found
        }
    }

    private func search(root: String, names: [String], maxDepth: Int) -> [String] {
        var args = [root, "-maxdepth", String(maxDepth), "("]
        for (index, skip) in ["Library", ".Trash", "Applications", "Pictures", "Music", "Movies"].enumerated() {
            if index > 0 { args.append("-o") }
            args += ["-path", root + "/" + skip]
        }
        args += [")", "-prune", "-o", "-type", "d", "("]
        for (index, name) in names.enumerated() {
            if index > 0 { args.append("-o") }
            args += ["-name", name]
        }
        args += [")", "-prune", "-print"]

        guard let output = Shell.run("/usr/bin/find", args, timeout: 240) else { return [] }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func isStale(_ path: String, days: Int) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(modified) > Double(days) * 86_400
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Measurement

    nonisolated private func measure(
        _ batch: [Candidate], liveDirectories: [String: String]
    ) -> [CleanupItem] {
        guard !batch.isEmpty else { return [] }
        var args = ["-sk", "-x"]
        args.append(contentsOf: batch.map(\.path))
        guard let output = Shell.run("/usr/bin/du", args, timeout: 300) else { return [] }

        var sizes: [String: UInt64] = [:]
        for line in output.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            guard let kb = UInt64(line[line.startIndex..<tab]) else { continue }
            sizes[String(line[line.index(after: tab)...])] = kb * 1024
        }

        return batch.compactMap { candidate in
            guard let size = sizes[candidate.path], size >= 1_048_576 else { return nil }
            let guarded = candidate.target.guardAgainstLiveProjects ? candidate.projectRoot : nil
            return CleanupItem(
                path: candidate.path,
                title: displayTitle(for: candidate),
                category: candidate.target.category,
                risk: candidate.target.risk,
                reason: candidate.target.reason,
                sizeBytes: size,
                heldBy: guarded.flatMap { Probes.holder(of: $0, in: liveDirectories) },
                lastTouched: lastTouched(candidate.path),
                projectRoot: guarded
            )
        }
    }

    /// A folder's own date only moves when its direct entries change, so the
    /// newest of it and its children is a better read on when it was last used.
    nonisolated private func lastTouched(_ path: String) -> Date? {
        let manager = FileManager.default
        let modified = { (path: String) in
            (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        var newest = modified(path)
        for name in (try? manager.contentsOfDirectory(atPath: path)) ?? [] {
            guard let date = modified(path + "/" + name) else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

    nonisolated private func displayTitle(for candidate: Candidate) -> String {
        switch candidate.target.shape {
        case .directory:
            return candidate.target.title
        case .children:
            return (candidate.path as NSString).lastPathComponent
        case .search:
            let leaf = candidate.path
                .replacingOccurrences(of: (candidate.projectRoot ?? "") + "/", with: "")
            return "\(projectLabel(candidate.projectRoot)) · \(leaf)"
        }
    }

    /// Two projects can both end in `admin`, so a single folder name is not enough
    /// to tell their caches apart. Keep the parent when there is one.
    nonisolated private func projectLabel(_ projectRoot: String?) -> String {
        guard let projectRoot else { return "project" }
        let parts = projectRoot.split(separator: "/").map(String.init)
        guard let last = parts.last else { return "project" }
        guard parts.count >= 2 else { return last }
        let parent = parts[parts.count - 2]
        if parent == (home as NSString).lastPathComponent { return last }
        return "\(parent)/\(last)"
    }
}
