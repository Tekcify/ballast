import AppKit
import Foundation
import SwiftUI

/// `BALLAST_DIAGNOSTIC=1 Ballast` prints one snapshot and exits, so the readings
/// can be checked against vm_stat, vmmap and Activity Monitor without the UI.
@MainActor
enum Diagnostic {
    static func runIfRequested() {
        let mode = ProcessInfo.processInfo.environment["BALLAST_DIAGNOSTIC"]
        if mode == "scan" { runScan() }
        if mode == "render" { RenderPreview.run() }
        if mode == "notify" { runNotify() }
        if mode == "layout" { runLayout() }
        if mode == "headsup" { runHeadsUp() }
        if mode == "readme" { ReadmeShots.run() }
        if mode == "login" {
            print("LOGIN \(LoginItem.status) bundle \(Bundle.main.bundleIdentifier ?? "none")")
            exit(0)
        }
        if mode == "login-roundtrip" { runLoginRoundTrip() }
        guard mode == "1" else { return }

        guard let vm = Probes.vmSample() else {
            print("vm sample failed")
            exit(1)
        }
        let swap = Probes.swapSample()
        let disk = Probes.diskSample()

        print("TOTAL \(vm.totalBytes)")
        print("USED \(vm.usedBytes)")
        print("APP \(vm.appBytes)")
        print("WIRED \(vm.wiredBytes)")
        print("COMPRESSED \(vm.compressedBytes)")
        print("CACHED \(vm.cachedBytes)")
        print("FREE \(vm.freeBytes)")
        print("PAGESIZE \(vm.pageSize)")
        print("PRESSURE \(Probes.pressure().rawValue)")
        print("SWAPUSED \(swap?.used ?? 0)")
        print("DISKAVAIL \(disk?.available ?? 0)")

        let processes = Probes.processList()
        print("PROCS \(processes.count)")
        print("APPROX \(processes.filter(\.memoryIsApproximate).count)")

        var directories: [pid_t: String] = [:]
        for process in processes where process.memoryBytes > 50 * 1_048_576 {
            guard !(process.execPath ?? "").contains(".app/") else { continue }
            if let cwd = Probes.workingDirectory(process.pid) { directories[process.pid] = cwd }
        }

        var runningApps: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let path = app.bundleURL?.resolvingSymlinksInPath().path else { continue }
            runningApps[path] = app
        }

        let groups = Grouping.build(
            from: processes,
            cpuPercents: [:],
            workingDirectories: directories,
            runningApps: runningApps,
            frontmostBundlePath: NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        )

        for group in groups.prefix(14) {
            let flags = [
                Grouping.isEssential(group) ? "essential" : nil,
                group.isApproximate ? "approx" : nil,
                group.isRunningApp ? "app" : nil,
            ].compactMap { $0 }.joined(separator: ",")
            print("GROUP \(group.memoryBytes) \(group.processCount) \(group.pids.prefix(4).map(String.init).joined(separator: ",")) [\(flags)] \(group.name)")
        }

        let advice = Advisor.advise(
            AdvisorInput(
                vm: vm, swap: swap, pressure: Probes.pressure(), disk: disk,
                groups: groups, growth: GrowthTracker(), lastActive: [:], reclaimableStorage: nil
            ),
            prefs: Preferences()
        )
        for item in advice {
            print("ADVICE [\(item.severity)] \(item.headline) :: \(item.detail)")
        }
        exit(0)
    }

    /// Dry run of the storage scan. Measures and prints every item and whether
    /// it would be selected, and deletes nothing.
    private static func runScan() {
        let scanner = StorageScanner()
        let deep = ProcessInfo.processInfo.environment["BALLAST_DEEP"] == "1"
        let guardrail = DeletionGuard(
            home: NSHomeDirectory(),
            targets: CleanupTarget.all(home: NSHomeDirectory(), includeDependencies: true)
        )
        let collected = Collector()
        let started = Date()

        let task = Task {
            await scanner.scan(
                includeDependencies: deep,
                onProgress: { progress in
                    if progress.stage == "Done" { return }
                },
                onItems: { items in Task { await collected.add(items) } }
            )
            let items = await collected.items
            print("SCANNED \(items.count) items in \(Int(Date().timeIntervalSince(started)))s")

            var selectable: UInt64 = 0
            var autoSelected: UInt64 = 0
            for item in items.sorted(by: { $0.sizeBytes > $1.sizeBytes }) {
                let rejection = guardrail.rejection(for: item.path)
                let auto = item.isDefaultPick(at: Date())
                let smart = item.isSmartPick(at: Date())
                if item.isSelectable { selectable += item.sizeBytes }
                if auto { autoSelected += item.sizeBytes }
                let flags = [
                    item.risk.label,
                    auto ? "AUTO" : (smart ? "SMART" : "manual"),
                    item.idle(at: Date()).map { "idle \(Fmt.duration($0))" },
                    item.isProtected ? "PROTECTED(\(item.heldBy ?? "?"))" : nil,
                    rejection.map { "REFUSED: \($0)" },
                ].compactMap { $0 }.joined(separator: " ")
                print("ITEM \(Fmt.bytes(item.sizeBytes))\t[\(flags)]\t\(item.path)")
            }
            print("TOTAL selectable \(Fmt.bytes(selectable))")
            print("TOTAL auto-selected \(Fmt.bytes(autoSelected))")
            exit(0)
        }
        _ = task
        RunLoop.main.run()
    }

    /// Posts one real alert and reports which delivery path carried it.
    private static func runNotify() {
        _ = NSApplication.shared
        let alerter = Alerter()
        alerter.start { name, pids in print("quit action: \(name) \(pids)") }

        // Launched through LaunchServices there is no stdout, so report to a file.
        let report = URL(fileURLWithPath: "/tmp/ballast-notify.txt")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let before = alerter.describePath()
            alerter.post(
                title: "Ballast is watching memory",
                body: "This is a test alert. Memory and storage alerts will look like this.",
                subject: "diagnostic",
                cooldown: 0
            )
            try? await Task.sleep(for: .seconds(4))
            let text = "before: \(before)\nafter: \(alerter.describePath())\n"
            try? text.write(to: report, atomically: true, encoding: .utf8)
            print(text)
            exit(0)
        }
        RunLoop.main.run()
    }

    /// Shows the real heads-up card for ten seconds with pressure faked to
    /// warning, so it can be seen without starving the Mac of memory.
    private static func runHeadsUp() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Theme.registerBundledFont()
        let monitor = Monitor()
        Task { @MainActor in
            await monitor.refresh()
            monitor.pressure = .warning
            let controller = HeadsUpController(monitor: monitor)
            controller.present()
            try? await Task.sleep(for: .milliseconds(600))
            print("HEADSUP visible \(controller.isVisible) frame \(controller.frame.map { NSStringFromRect($0) } ?? "none")")
            try? await Task.sleep(for: .seconds(10))
            exit(controller.isVisible ? 0 : 1)
        }
        RunLoop.main.run()
    }

    /// `BALLAST_SELFTEST=headsup` checks the live app: monitoring runs without
    /// the panel ever opening, the menu bar item the card anchors to is found,
    /// the card shows and hides, and "Open Ballast" expands it to the panel.
    static func selfTestIfRequested(_ monitor: Monitor) {
        guard ProcessInfo.processInfo.environment["BALLAST_SELFTEST"] == "headsup" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            var failed = false
            let sampled = monitor.lastSampledAt != nil
            let button = StatusItemLocator.button() != nil
            print("SELFTEST sampled-without-panel \(sampled)")
            print("SELFTEST status-button \(button)")
            monitor.pressure = .warning
            monitor.headsUp?.present()
            try? await Task.sleep(for: .milliseconds(600))
            let visible = monitor.headsUp?.isVisible == true
            print("SELFTEST headsup-visible \(visible)")
            monitor.dismissHeadsUp()
            try? await Task.sleep(for: .seconds(6))
            let closed = monitor.headsUp?.isVisible == false
            print("SELFTEST headsup-closed \(closed)")
            monitor.headsUp?.present()
            try? await Task.sleep(for: .milliseconds(400))
            monitor.headsUp?.expand()
            try? await Task.sleep(for: .milliseconds(600))
            let island = monitor.headsUp as? IslandController
            let panelWidth = Theme.panelWidth + (island == nil ? 0 : 2 * IslandLayout.expandedShoulder)
            let width = monitor.headsUp?.frame?.width ?? 0
            let expanded = monitor.headsUp?.isExpanded == true && abs(width - panelWidth) < 2
            print("SELFTEST style \(monitor.prefs.headsUpStyle.rawValue)")
            print("SELFTEST expanded-to-panel \(expanded) width \(Int(width)) height \(Int(monitor.headsUp?.frame?.height ?? 0))")
            var placed = true
            if let island, let frame = island.frame {
                let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
                let flush = screen.map { abs(frame.maxY - $0.frame.maxY) < 1 && abs(frame.midX - $0.frame.midX) < 1 } ?? false
                placed = flush
                print("SELFTEST island-flush-with-notch-centre \(flush) on \(screen?.localizedName ?? "none") notch \(island.model.notch.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none")")
                island.collapsePanel()
                try? await Task.sleep(for: .milliseconds(600))
                print("SELFTEST island-after-collapse \(island.frame.map { NSStringFromRect($0) } ?? "hidden") expanded \(island.model.expanded) hovering \(island.model.hovering) pointer \(NSStringFromPoint(NSEvent.mouseLocation))")
            }
            let cpu = monitor.cpuUsage
            print("SELFTEST cpu \(cpu.map(Fmt.percent) ?? "missing") live-readout \(monitor.prefs.islandAlwaysOn)")
            failed = !(sampled && button && visible && closed && expanded && placed && cpu != nil)
            exit(failed ? 1 : 0)
        }
    }

    /// Turns the login item on, reads it back, then puts it back how it was.
    private static func runLoginRoundTrip() {
        let before = LoginItem.status
        LoginItem.setEnabled(true)
        let on = LoginItem.status
        print("LOGIN before \(before) after-enable \(on) error \(LoginItem.lastError ?? "none")")
        if before == .off {
            LoginItem.setEnabled(false)
            print("LOGIN restored \(LoginItem.status) error \(LoginItem.lastError ?? "none")")
        }
        exit(on == .off ? 1 : 0)
    }

    private actor Collector {
        var items: [CleanupItem] = []
        func add(_ new: [CleanupItem]) { items.append(contentsOf: new) }
    }

    /// Hosts the real panel offscreen and prints its fitted size per pane, so a
    /// collapsed popover shows up as a height near the tab bar's.
    static func runLayout() {
        _ = NSApplication.shared
        Theme.registerBundledFont()
        let monitor = Monitor()
        Task { @MainActor in
            await monitor.refresh()
            var failed = false
            var ideals: [Pane: CGFloat] = [:]
            for pane in Pane.allCases {
                let controller = NSHostingController(rootView: PanelView(monitor: monitor, pane: pane))
                let window = NSWindow(contentViewController: controller)
                window.styleMask = [.borderless]
                for _ in 0..<5 {
                    controller.view.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let ideal = controller.view.fittingSize
                let minimum = controller.sizeThatFits(in: CGSize(width: Theme.panelWidth, height: 0))
                ideals[pane] = ideal.height
                print("LAYOUT \(pane.rawValue) ideal \(Int(ideal.height)) minimum \(Int(minimum.height))")
                if minimum.height < 150 { failed = true }
            }

            // The popover's window never shrinks on its own. Start it too tall,
            // switch to a shorter pane, and expect it to fit with the top held.
            let host = NSHostingView(rootView: AnyView(PanelView(monitor: monitor, pane: .memory, fitsWindow: true)))
            host.sizingOptions = []
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.setFrame(NSRect(x: 200, y: 100, width: Theme.panelWidth, height: 760), display: true)
            let top = window.frame.maxY
            try? await Task.sleep(for: .milliseconds(400))
            let memoryHeight = window.frame.height
            host.rootView = AnyView(PanelView(monitor: monitor, pane: .settings, fitsWindow: true).id("settings"))
            try? await Task.sleep(for: .milliseconds(400))
            let settingsHeight = window.frame.height
            let fitted = abs(settingsHeight - (ideals[.settings] ?? 0)) < 2
            let held = abs(window.frame.maxY - top) < 1
            print("LAYOUT popover memory \(Int(memoryHeight)) then settings \(Int(settingsHeight)) fitted \(fitted) top-held \(held)")
            if !(fitted && held && settingsHeight < memoryHeight) { failed = true }
            exit(failed ? 1 : 0)
        }
        RunLoop.main.run()
    }
}
