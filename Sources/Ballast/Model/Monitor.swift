import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class Monitor {
    // MARK: Memory state
    var vm: Probes.VMSample?
    var swap: Probes.SwapSample?
    var pressure: Probes.Pressure = .normal
    var disk: Probes.DiskSample?
    var groups: [AppGroup] = []
    var advice: [Advice] = []
    var lastSampledAt: Date?
    var approximateCount = 0

    // MARK: Storage state
    var storageItems: [CleanupItem] = []
    var selection: Set<String> = []
    var scanProgress: ScanProgress?
    var isScanning = false
    var isCleaning = false
    var lastScanAt: Date? {
        didSet { UserDefaults.standard.set(lastScanAt, forKey: "lastScanAt") }
    }
    var lastReport: CleanReport?
    var statusLine: String?

    let prefs = Preferences()

    init() {
        lastScanAt = UserDefaults.standard.object(forKey: "lastScanAt") as? Date
    }

    let alerter = Alerter()
    private let scanner = StorageScanner()
    private let cleaner = Cleaner()
    private var growth = GrowthTracker()
    private var lastActive: [String: Date] = [:]
    private var previousCPU: [pid_t: (nanos: UInt64, at: Date)] = [:]
    private var loop: Task<Void, Never>?
    private let launchedAt = Date()
    private var scanTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        alerter.start { [weak self] name, pids in
            Task { @MainActor in await self?.quit(name: name, pids: pids) }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = self?.prefs.refreshSeconds ?? 5
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        loop?.cancel()
        scanTask?.cancel()
    }

    // MARK: Sampling

    struct Sample: Sendable {
        var vm: Probes.VMSample
        var swap: Probes.SwapSample?
        var pressure: Probes.Pressure
        var disk: Probes.DiskSample?
        var processes: [Probes.RawProcess]
        var workingDirectories: [pid_t: String]
        var at: Date
    }

    /// Reading 1,400 processes means as many `proc_pidpath` and `proc_pid_rusage`
    /// calls, so it runs off the main thread and hands back a plain value.
    @concurrent
    nonisolated private static func collect() async -> Sample? {
        guard let vm = Probes.vmSample() else { return nil }
        let processes = Probes.processList()

        // Only command line tools need their working directory, and only the
        // sizeable ones, which keeps this to a handful of extra calls.
        var directories: [pid_t: String] = [:]
        for process in processes where process.memoryBytes > 50 * 1_048_576 {
            let path = process.execPath ?? ""
            guard !path.contains(".app/") else { continue }
            if let cwd = Probes.workingDirectory(process.pid) { directories[process.pid] = cwd }
        }

        return Sample(
            vm: vm,
            swap: Probes.swapSample(),
            pressure: Probes.pressure(),
            disk: Probes.diskSample(),
            processes: processes,
            workingDirectories: directories,
            at: Date()
        )
    }

    func refresh() async {
        guard let sample = await Self.collect() else { return }

        vm = sample.vm
        swap = sample.swap
        pressure = sample.pressure
        disk = sample.disk
        lastSampledAt = sample.at

        let cpu = cpuPercents(sample)
        let workspace = NSWorkspace.shared
        var runningApps: [String: NSRunningApplication] = [:]
        for app in workspace.runningApplications {
            guard let path = app.bundleURL?.resolvingSymlinksInPath().path else { continue }
            runningApps[path] = app
        }
        let frontmost = workspace.frontmostApplication?.bundleURL?.resolvingSymlinksInPath().path

        groups = Grouping.build(
            from: sample.processes,
            cpuPercents: cpu,
            workingDirectories: sample.workingDirectories,
            runningApps: runningApps,
            frontmostBundlePath: frontmost
        )
        approximateCount = groups.filter(\.isApproximate).count

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
                reclaimableStorage: reclaimableBytes > 0 ? reclaimableBytes : nil
            ),
            prefs: prefs,
            now: sample.at
        )

        notify()
        await maybeAutoScan()
    }

    private func cpuPercents(_ sample: Sample) -> [pid_t: Double] {
        var out: [pid_t: Double] = [:]
        var next: [pid_t: (nanos: UInt64, at: Date)] = [:]

        for process in sample.processes {
            guard let nanos = process.cpuNanos else { continue }
            next[process.pid] = (nanos, sample.at)
            guard let previous = previousCPU[process.pid] else { continue }
            let elapsed = sample.at.timeIntervalSince(previous.at)
            guard elapsed > 0.5, nanos >= previous.nanos else { continue }
            let used = Double(nanos - previous.nanos) / 1_000_000_000
            out[process.pid] = used / elapsed * 100
        }
        previousCPU = next
        return out
    }

    /// Only the single most useful alert goes out per refresh. Firing one per
    /// piece of advice would mean four banners the moment pressure rises.
    private func notify() {
        guard prefs.notificationsEnabled else { return }

        let urgent = advice.filter { $0.severity >= .warning }
        guard let top = urgent.first(where: { if case .quit = $0.action { true } else { false } })
            ?? urgent.first
        else { return }

        var quit: (name: String, pids: [pid_t])?
        if case .quit(let name, let pids) = top.action { quit = (name, pids) }

        alerter.post(
            title: top.headline,
            body: top.detail,
            subject: top.id,
            cooldown: prefs.cooldownMinutes * 60,
            quit: quit
        )
    }

    // MARK: Derived values

    var usedFraction: Double {
        guard let vm, vm.totalBytes > 0 else { return 0 }
        return min(Double(vm.usedBytes) / Double(vm.totalBytes), 1)
    }

    var menuBarLabel: String? {
        guard prefs.showPercentInMenuBar, vm != nil else { return nil }
        return Fmt.percent(usedFraction)
    }

    var reclaimableBytes: UInt64 {
        storageItems.filter(\.isSelectable).reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedBytes: UInt64 {
        storageItems.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    var protectedItems: [CleanupItem] { storageItems.filter(\.isProtected) }

    /// Most of the 1,400 running processes are small system daemons. Listing every
    /// one turns the panel into noise, so only groups worth acting on are shown.
    var listedGroups: [AppGroup] {
        groups.filter { $0.memoryBytes >= 50 * 1_048_576 }
    }

    // MARK: Actions

    func quit(name: String, pids: [pid_t]) async {
        statusLine = "Asking \(name) to quit…"
        let outcome = await Quitter.quit(name: name, pids: pids)
        statusLine = outcome.summary
        alerter.resetCooldown(for: "quit:\(name)")
        await refresh()
    }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        let startedAt = Date()
        isScanning = true
        storageItems = []
        selection = []
        lastReport = nil
        scanProgress = ScanProgress(stage: "Starting", completed: 0, total: 0)

        scanTask = Task { [weak self] in
            guard let self else { return }
            await scanner.scan(
                includeDependencies: prefs.includeDependencyFolders,
                onProgress: { progress in
                    Task { @MainActor [weak self] in self?.scanProgress = progress }
                },
                onItems: { items in
                    Task { @MainActor [weak self] in self?.absorb(items) }
                }
            )
            await MainActor.run {
                self.isScanning = false
                self.scanProgress = nil
                self.lastScanAt = Date()
                let elapsed = Fmt.duration(Date().timeIntervalSince(startedAt))
                self.statusLine = self.storageItems.isEmpty
                    ? "Nothing worth clearing. Measured in \(elapsed)."
                    : "Measured \(self.storageItems.count) locations in \(elapsed)."
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        scanProgress = nil
    }

    private func absorb(_ items: [CleanupItem]) {
        let known = Set(storageItems.map(\.path))
        storageItems.append(contentsOf: items.filter { !known.contains($0.path) })
        storageItems.sort { $0.sizeBytes > $1.sizeBytes }
        for item in items where item.risk.defaultsOn && item.isSelectable {
            selection.insert(item.id)
        }
    }

    func toggle(_ item: CleanupItem) {
        guard item.isSelectable else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectAll(risk: Risk) {
        for item in storageItems where item.risk == risk && item.isSelectable {
            selection.insert(item.id)
        }
    }

    func clearSelection() { selection = [] }

    func clean() async {
        guard !isCleaning else { return }
        let chosen = storageItems.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }

        isCleaning = true
        scanProgress = ScanProgress(stage: "Starting", completed: 0, total: chosen.count)

        let report = await cleaner.clean(chosen) { progress in
            Task { @MainActor [weak self] in self?.scanProgress = progress }
        }

        lastReport = report
        storageItems.removeAll { item in
            selection.contains(item.id) && !report.failures.contains { $0.path == item.path }
        }
        selection = []
        isCleaning = false
        scanProgress = nil
        statusLine = report.summary
        disk = Probes.diskSample()
    }

    // MARK: Scheduled upkeep

    /// A scan reads a lot of disk, so it never runs in the first few minutes
    /// after launch and otherwise keeps to the chosen interval across restarts.
    private func maybeAutoScan() async {
        guard prefs.autoScanEnabled, !isScanning, !isCleaning else { return }
        guard Date().timeIntervalSince(launchedAt) > 300 else { return }
        if let last = lastScanAt, Date().timeIntervalSince(last) < prefs.autoScanHours * 3600 { return }
        scan()
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }

    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
