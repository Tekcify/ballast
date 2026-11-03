import AppKit
import BallastCore
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
    var isScanning = false {
        didSet { if isScanning != oldValue { headsUp?.sync() } }
    }
    var isCleaning = false {
        didSet { if isCleaning != oldValue { headsUp?.sync() } }
    }
    var lastScanAt: Date? {
        didSet { UserDefaults.standard.set(lastScanAt, forKey: "lastScanAt") }
    }
    var lastReport: CleanReport?
    var statusLine: String?
    var lastQuitOutcome: String?
    /// Whole-machine CPU use between the last two samples, 0 to 1.
    var cpuUsage: Double?
    private var previousTicks: Probes.CPUTicks?
    /// Held here rather than read from `SMAppService` in each view, because the
    /// service is not observable and a toggle bound to it never redraws.
    var loginStatus: LoginItem.Status = LoginItem.status

    let prefs: Preferences

    init(prefs: Preferences = Preferences()) {
        self.prefs = prefs
        lastScanAt = UserDefaults.standard.object(forKey: "lastScanAt") as? Date
        restoreLastScan()
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
    private(set) var headsUp: (any HeadsUpSurface)?
    private var headsUpStyle: Preferences.HeadsUpStyle?
    private var headsUpPolicy = HeadsUpPolicy()
    /// While set, pressure reads as warning so the heads-up can be previewed.
    private var previewUntil: Date?

    // MARK: Lifecycle

    /// Called at launch and again when the panel first appears, so it must only
    /// start the loop once.
    func start() {
        guard loop == nil else { return }
        applyLoginDefault()
        applyHeadsUpSettings()
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
        var cpu: Probes.CPUTicks?
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
            cpu: Probes.cpuTicks(),
            processes: processes,
            workingDirectories: directories,
            at: Date()
        )
    }

    func refresh() async {
        guard let sample = await Self.collect() else { return }

        vm = sample.vm
        swap = sample.swap
        pressure = (previewUntil.map { sample.at < $0 } ?? false) ? .warning : sample.pressure
        disk = sample.disk
        lastSampledAt = sample.at
        if let ticks = sample.cpu {
            if let previous = previousTicks { cpuUsage = ticks.usage(since: previous) ?? cpuUsage }
            previousTicks = ticks
        }

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

        updateHeadsUp(at: sample.at)
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
        guard prefs.notificationsEnabled, headsUp?.isVisible != true else { return }

        // Under pressure the heads-up card carries the memory story, so banners
        // are left for disk space.
        let cardOwnsMemory = prefs.headsUpEnabled && pressure > .normal
        let urgent = advice.filter {
            $0.severity >= .warning && (!cardOwnsMemory || $0.action == .openStorage)
        }
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

    // MARK: Heads-up

    private func updateHeadsUp(at now: Date) {
        guard let headsUp else { return }
        headsUp.sync()
        guard prefs.headsUpEnabled else {
            if headsUp.isVisible { headsUp.close() }
            return
        }
        switch headsUpPolicy.observe(pressure, isVisible: headsUp.isVisible, now: now) {
        case .present: headsUp.present()
        case .recover: headsUp.closeSoon()
        case .none: if pressure > .normal { headsUp.cancelClose() }
        }
    }

    func dismissHeadsUp() {
        headsUpPolicy.dismissed(at: pressure, now: Date())
        headsUp?.close()
    }

    /// Builds the surface for the chosen look, swapping out the old one, and
    /// re-reads the island's options.
    func applyHeadsUpSettings() {
        if headsUpStyle != prefs.headsUpStyle {
            headsUp?.teardown()
            headsUpStyle = prefs.headsUpStyle
            headsUp = prefs.headsUpStyle == .island
                ? IslandController(monitor: self)
                : HeadsUpController(monitor: self)
        }
        (headsUp as? IslandController)?.position()
        headsUp?.sync()
    }

    /// Shows the heads-up as if memory were getting cooked, for eight seconds.
    func previewHeadsUp() {
        applyHeadsUpSettings()
        previewUntil = Date().addingTimeInterval(8)
        pressure = .warning
        headsUp?.present()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8.5))
            guard let self, let until = self.previewUntil, Date() >= until else { return }
            self.previewUntil = nil
            await self.refresh()
        }
    }

    func snoozeHeadsUp() {
        headsUpPolicy.snooze(for: 3600, now: Date())
        headsUp?.close()
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
        statusLine = "Asking \(name) to dip…"
        let outcome = await Quitter.quit(name: name, pids: pids)
        statusLine = outcome.summary
        lastQuitOutcome = outcome.summary
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
                guard self.isScanning else { return }
                self.isScanning = false
                self.scanProgress = nil
                self.lastScanAt = Date()
                ScanCache.save(self.storageItems)
                let elapsed = Fmt.duration(Date().timeIntervalSince(startedAt))
                self.statusLine = self.storageItems.isEmpty
                    ? "Your disk is clean, honestly. Checked in \(elapsed)."
                    : "Found \(self.storageItems.count) spots in \(elapsed). Biggest ones up top."
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        scanProgress = nil
        statusLine = "Scan stopped. These are only the spots measured so far."
    }

    private func absorb(_ items: [CleanupItem]) {
        let known = Set(storageItems.map(\.path))
        storageItems.append(contentsOf: items.filter { !known.contains($0.path) })
        storageItems.sort { $0.sizeBytes > $1.sizeBytes }
        let now = Date()
        for item in items where item.isDefaultPick(at: now) {
            selection.insert(item.id)
        }
    }

    private func restoreLastScan() {
        storageItems = ScanCache.load().sorted { $0.sizeBytes > $1.sizeBytes }
        let now = Date()
        selection = Set(storageItems.filter { $0.isDefaultPick(at: now) }.map(\.id))
        if !storageItems.isEmpty, let lastScanAt {
            statusLine = "From your last scan \(Fmt.duration(now.timeIntervalSince(lastScanAt))) ago. Rescan for fresh numbers."
        }
    }

    func toggle(_ item: CleanupItem) {
        guard item.isSelectable else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    /// Safe caches plus rebuildable ones nobody has touched in a month, skipping
    /// anything an app wrote to in the last few minutes.
    func smartPick() {
        let now = Date()
        let picks = storageItems.filter { $0.isSmartPick(at: now) }
        selection = Set(picks.map(\.id))
        let dormant = picks.filter { $0.risk == .review }.count
        statusLine = picks.isEmpty
            ? "Nothing's safe to auto pick rn. Tick what you want by hand."
            : dormant > 0
                ? "Picked the safe stuff plus \(dormant) cache\(dormant == 1 ? "" : "s") you ghosted for 30+ days."
                : "Picked the safe stuff. Nothing else has been sitting long enough."
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
        if report.trashedBytes > 0 { growTrash(by: report.trashedBytes) }
        selection = []
        isCleaning = false
        scanProgress = nil
        statusLine = report.trashedBytes > 0
            ? "\(Fmt.bytes(report.trashedBytes)) is chilling in the Trash and still takes space. Empty it when you're sure."
            : report.summary
        disk = Probes.diskSample()
        ScanCache.save(storageItems)
    }

    /// Rebuildable items go to the Trash, so the space only comes back once it
    /// is emptied. Keep the Trash row honest about that.
    private func growTrash(by bytes: UInt64) {
        let path = NSHomeDirectory() + "/.Trash"
        if let index = storageItems.firstIndex(where: { $0.path == path }) {
            storageItems[index].sizeBytes += bytes
            storageItems[index].lastTouched = Date()
        } else if let target = CleanupTarget.all(home: NSHomeDirectory()).first(where: {
            if case .directory(path) = $0.shape { true } else { false }
        }) {
            storageItems.append(CleanupItem(
                path: path, title: target.title, category: target.category, risk: target.risk,
                reason: target.reason, sizeBytes: bytes, lastTouched: Date()
            ))
        }
        storageItems.sort { $0.sizeBytes > $1.sizeBytes }
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

    /// Start at login is on by default. It is switched on once, the first time
    /// Ballast runs from an Applications folder, so turning it off later sticks
    /// and a build run from elsewhere never registers itself.
    private func applyLoginDefault() {
        let key = "startAtLoginDefaultApplied"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key), LoginItem.isInstalledCopy else { return }
        defaults.set(true, forKey: key)
        if LoginItem.status == .off { setStartAtLogin(true) }
    }

    func setStartAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        refreshLoginStatus()
    }

    /// Re-reads the status, which can change in System Settings while Ballast runs.
    func refreshLoginStatus() {
        let status = LoginItem.status
        if loginStatus != status { loginStatus = status }
    }

    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
