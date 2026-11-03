import AppKit
import BallastCore
import Foundation

/// How macOS processes are folded into apps: helpers belong to the outermost
/// `.app` bundle in their executable path, and command line tools are split by
/// the project they run in. The group type and the essential lists live in
/// BallastCore.
extension Grouping {
    /// The bundle's own display name. Simulator and wrapped bundles have
    /// directory names like `Expo-Go-58.0.7.tar.app`, which is not what to show.
    private static var displayNameCache: [String: String?] = [:]

    static func bundleDisplayName(at bundlePath: String) -> String? {
        if let cached = displayNameCache[bundlePath] { return cached }
        let candidates = [bundlePath + "/Contents/Info.plist", bundlePath + "/Info.plist"]
        var resolved: String?
        for candidate in candidates {
            guard let data = FileManager.default.contents(atPath: candidate),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: Any]
            else { continue }
            resolved = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
            if resolved?.isEmpty == true { resolved = nil }
            if resolved != nil { break }
        }
        displayNameCache[bundlePath] = resolved
        return resolved
    }

    /// The outermost `.app` in an executable path is the responsible application:
    /// a Chrome renderer lives several nested bundles deep but belongs to Chrome.
    static func responsibleBundle(for execPath: String) -> (path: String, name: String)? {
        var components = execPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        components = Array(components[0...index])
        let path = components.joined(separator: "/")
        let name = String(components[index].dropLast(4))
        return (path, name)
    }

    private static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]

    static func build(
        from processes: [Probes.RawProcess],
        cpuPercents: [pid_t: Double],
        workingDirectories: [pid_t: String],
        runningApps: [String: NSRunningApplication],
        frontmostBundlePath: String?
    ) -> [AppGroup] {
        struct Accumulator {
            var name: String
            var bundlePath: String?
            var projectPath: String?
            var pids: [pid_t] = []
            var memory: UInt64 = 0
            var cpu: Double = 0
            var approximate = false
            var systemOwned = false
            var started = Date.distantFuture
        }

        var buckets: [String: Accumulator] = [:]
        let home = NSHomeDirectory()

        for process in processes where process.memoryBytes > 0 {
            let path = process.execPath ?? process.name
            var key: String
            var accumulator: Accumulator

            if let bundle = responsibleBundle(for: path) {
                key = bundle.path
                accumulator = buckets[key] ?? Accumulator(name: bundle.name, bundlePath: bundle.path)
            } else {
                // Command line tools: split by project so two dev servers stay distinct.
                let project = workingDirectories[process.pid].flatMap { cwd -> String? in
                    guard cwd.hasPrefix(home), cwd != home else { return nil }
                    return cwd
                }
                key = project.map { "\(process.name)|\($0)" } ?? process.name
                accumulator = buckets[key] ?? Accumulator(
                    name: process.name,
                    bundlePath: nil,
                    projectPath: project
                )
            }

            accumulator.pids.append(process.pid)
            accumulator.memory += process.memoryBytes
            accumulator.cpu += cpuPercents[process.pid] ?? 0
            accumulator.approximate = accumulator.approximate || process.memoryIsApproximate
            accumulator.systemOwned = accumulator.systemOwned
                || process.uid == 0
                || systemPrefixes.contains(where: { path.hasPrefix($0) })
            accumulator.started = min(accumulator.started, process.startedAt)
            buckets[key] = accumulator
        }

        return buckets.map { key, value in
            let app = value.bundlePath.flatMap { runningApps[$0] }
            return AppGroup(
                id: key,
                name: app?.localizedName
                    ?? value.bundlePath.flatMap { bundleDisplayName(at: $0) }
                    ?? value.name,
                bundleIdentifier: app?.bundleIdentifier,
                bundlePath: value.bundlePath,
                projectPath: value.projectPath,
                pids: value.pids.sorted(),
                memoryBytes: value.memory,
                cpuPercent: value.cpu,
                isApproximate: value.approximate,
                isSystemOwned: value.systemOwned,
                isRunningApp: app != nil,
                isFrontmost: value.bundlePath != nil && value.bundlePath == frontmostBundlePath,
                isHidden: app?.isHidden ?? false,
                startedAt: value.started == .distantFuture ? Date() : value.started
            )
        }
        .sorted { $0.memoryBytes > $1.memoryBytes }
    }
}
