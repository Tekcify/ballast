import AppKit
import BallastCore
import SwiftUI

/// `BALLAST_DIAGNOSTIC=render` rasterises each pane to a PNG so the layout can be
/// checked without opening the menu bar popover. Memory uses live readings;
/// storage uses representative rows so the list and risk tags can be seen.
@MainActor
enum RenderPreview {
    static func run() {
        _ = NSApplication.shared
        Theme.registerBundledFont()
        let monitor = Monitor()

        Task { @MainActor in
            await monitor.refresh()
            seedStorage(monitor)

            render(PanelHost(monitor: monitor, pane: .memory), to: "/tmp/ballast-memory.png")
            render(PanelHost(monitor: monitor, pane: .storage), to: "/tmp/ballast-storage.png")
            render(PanelHost(monitor: monitor, pane: .settings), to: "/tmp/ballast-settings.png")

            monitor.prefs.rankStorageBySize.toggle()
            render(PanelHost(monitor: monitor, pane: .storage), to: "/tmp/ballast-storage-bytype.png")
            monitor.prefs.rankStorageBySize.toggle()

            let actual = monitor.pressure
            monitor.pressure = .warning
            render(card(monitor), to: "/tmp/ballast-headsup.png")
            monitor.pressure = .normal
            render(card(monitor), to: "/tmp/ballast-headsup-recovered.png")
            for (name, setup) in islandStates(monitor) {
                setup()
                render(islandFrame(monitor), to: "/tmp/ballast-island-\(name).png")
            }
            monitor.isScanning = false
            monitor.scanProgress = nil
            monitor.pressure = actual

            let selection = SettingsSelection()
            for section in [SettingsSection.headsUp, .general] {
                selection.section = section
                render(SettingsWindowView(monitor: monitor, selection: selection),
                       to: "/tmp/ballast-settings-\(section.rawValue.lowercased()).png")
            }
            print("rendered")
            exit(0)
        }
        RunLoop.main.run()
    }

    private static let island = IslandModel()

    private static func islandStates(_ monitor: Monitor) -> [(String, () -> Void)] {
        let notch = CGSize(width: 220, height: 38)
        func set(alert: Bool, expanded: Bool, pressure: Probes.Pressure, scanning: Bool = false) {
            island.notch = notch
            island.presented = true
            island.alert = alert
            island.expanded = expanded
            monitor.pressure = pressure
            monitor.isScanning = scanning
            monitor.scanProgress = scanning ? ScanProgress(stage: "Sizing things up", completed: 61, total: 170) : nil
        }
        return [
            ("compact", { set(alert: true, expanded: false, pressure: .warning) }),
            ("expanded", { set(alert: true, expanded: true, pressure: .warning) }),
            ("scan", { set(alert: false, expanded: false, pressure: .normal, scanning: true) }),
            ("scan-expanded", { set(alert: false, expanded: true, pressure: .normal, scanning: true) }),
        ]
    }

    private static func islandFrame(_ monitor: Monitor) -> some View {
        IslandView(monitor: monitor, model: island, onToggle: {}, onDismiss: {}, onSnooze: {}, onOpen: {}, onStorage: {})
            .frame(width: 480, height: island.expanded ? 420 : 70)
            .background(Color(white: 0.82))
            .transaction { $0.animation = nil }
    }

    private static func card(_ monitor: Monitor) -> some View {
        HeadsUpView(monitor: monitor, onDismiss: {}, onSnooze: {}, onOpen: {}, onStorage: {})
            .padding(10)
            .background(Color(white: 0.82))
    }

    /// Draws the view the way a window does, through AppKit. ImageRenderer dims
    /// any picture that contains an app icon and cannot draw native controls.
    static func bitmap(_ view: some View, appearance: NSAppearance.Name? = nil) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.environment(\.staticRender, true))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    static func render(_ view: some View, to path: String, appearance: NSAppearance.Name? = nil) {
        guard let png = bitmap(view, appearance: appearance)?.representation(using: .png, properties: [:]) else {
            print("render failed for \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    static func seedStorage(_ monitor: Monitor) {
        let home = NSHomeDirectory()
        let day: TimeInterval = 86_400
        let rows: [(String, String, String, Risk, String, UInt64, String?)] = [
            ("\(home)/Library/Developer/Xcode/DerivedData/Weather-gvqxrrryxhac", "Weather-gvqxrrryxhac", "Xcode", .safe,
             "Build intermediates. Xcode regenerates them on the next build.", 18_253_611_008, nil),
            ("\(home)/.gradle/caches", "Gradle caches", "Package managers", .review,
             "Re-downloaded and rebuilt on the next Gradle run.", 21_474_836_480, nil),
            ("\(home)/Library/pnpm/store", "pnpm store", "Package managers", .review,
             "Shared package store. Existing installs relink from it, so expect a refetch.", 15_032_385_536, nil),
            ("\(home)/Library/Developer/Xcode/Archives", "Build archives", "Xcode", .reportOnly,
             "Your shipped builds and their dSYMs. Needed to symbolise crash reports.", 8_697_308_774, nil),
            ("\(home)/code/shop/web/.next/dev/cache", "web · .next/dev/cache", "Project builds", .safe,
             "Next.js rebuilds this. Covers both .next/cache and .next/dev/cache.", 2_147_483_648, nil),
            ("\(home)/code/blog/web/.next/dev/cache", "web · .next/dev/cache", "Project builds", .safe,
             "Next.js rebuilds this. Covers both .next/cache and .next/dev/cache.", 2_147_483_648, "node"),
            ("\(home)/Library/Caches/Google", "Google", "App caches", .safe,
             "Per-app scratch data. Apps rebuild what they need.", 3_758_096_384, nil),
            ("\(home)/.Trash", "Trash", "Reclaimable", .caution,
             "Emptying this is final. Check it first.", 4_294_967_296, nil),
        ]

        let idle: [TimeInterval] = [3 * day, 64 * day, 2 * day, 200 * day, 1 * day, 0, 120, 20 * day]
        monitor.storageItems = zip(rows, idle).map { row, idle in
            CleanupItem(path: row.0, title: row.1, category: row.2, risk: row.3,
                        reason: row.4, sizeBytes: row.5, heldBy: row.6,
                        lastTouched: Date().addingTimeInterval(-idle))
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
        monitor.selection = Set(monitor.storageItems.filter { $0.isDefaultPick(at: Date()) }.map(\.id))
        monitor.statusLine = "Found \(monitor.storageItems.count) spots in 5m. Biggest ones up top."
    }
}

/// Mirrors PanelView but with the pane fixed, since its selection is local state.
struct PanelHost: View {
    var monitor: Monitor
    var pane: Pane

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch pane {
                case .memory: MemoryPane(monitor: monitor) {}
                case .storage: StoragePane(monitor: monitor)
                case .settings: SettingsPane(monitor: monitor)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Hairline()
            HStack(spacing: 2) {
                ForEach(Pane.allCases) { item in
                    Text(item.rawValue)
                        .font(Theme.font(11, pane == item ? 580 : 460))
                        .foregroundStyle(pane == item ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(pane == item ? Theme.fill : .clear)
                        )
                }
                Spacer(minLength: 4)
                Text(Fmt.shortTime(Date()))
                    .font(Theme.font(9.5, 420, tabular: true))
                    .foregroundStyle(.tertiary)
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 18)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(width: Theme.panelWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
