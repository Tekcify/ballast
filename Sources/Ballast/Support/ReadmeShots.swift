import AppKit
import SwiftUI

/// `BALLAST_DIAGNOSTIC=readme` renders the README screenshots from made-up
/// data, so nobody's real process list or disk ends up in the repository.
/// `BALLAST_OUT` picks the folder, `assets` by default.
@MainActor
enum ReadmeShots {
    private static let gb: Double = 1_073_741_824

    static func run() {
        _ = NSApplication.shared
        Theme.registerBundledFont()
        let out = ProcessInfo.processInfo.environment["BALLAST_OUT"] ?? "assets"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        // A scratch store, so the shots show the defaults and never read or
        // write the settings of whoever runs this.
        let suite = "com.tekcify.ballast.readme"
        UserDefaults().removePersistentDomain(forName: suite)
        let monitor = Monitor(prefs: Preferences(defaults: UserDefaults(suiteName: suite) ?? .standard))
        seedMemory(monitor)
        RenderPreview.seedStorage(monitor)
        monitor.disk = Probes.DiskSample(total: UInt64(994 * gb), available: UInt64(118 * gb))
        monitor.lastScanAt = Date().addingTimeInterval(-3 * 3600)

        let island = IslandModel()
        island.notch = CGSize(width: 220, height: 38)
        island.presented = true

        func shoot(_ view: some View, _ name: String) {
            RenderPreview.render(view.transaction { $0.animation = nil }, to: "\(out)/\(name).png", appearance: .darkAqua)
        }

        island.alert = true
        island.expanded = true
        shoot(Desk(height: 430) { islandView(monitor, island) }, "island")

        island.expanded = false
        let strips: [(String, () -> Void)] = [
            ("Memory", {
                island.alert = false
                monitor.pressure = .normal
                island.pinnedReadout = .memory
            }),
            ("CPU", { island.pinnedReadout = .cpu }),
            ("Free disk", { island.pinnedReadout = .disk }),
            ("Getting cooked", {
                island.pinnedReadout = nil
                island.alert = true
                monitor.pressure = .warning
            }),
            ("Fully cooked", { monitor.pressure = .critical }),
            ("Scanning", {
                island.alert = false
                monitor.pressure = .normal
                monitor.isScanning = true
                monitor.scanProgress = ScanProgress(stage: "Sizing things up", completed: 104, total: 170)
            }),
            ("Chillin again", {
                monitor.isScanning = false
                monitor.scanProgress = nil
                island.alert = true
            }),
        ]
        var images: [(String, CGImage)] = []
        for index in strips.indices {
            strips[index].1()
            if let image = snapshot(Desk(height: 64) { islandView(monitor, island) }) {
                images.append((strips[index].0, image))
            }
        }
        shoot(StateSheet(images: images), "island-states")

        monitor.pressure = .warning
        island.alert = false
        shoot(PanelHost(monitor: monitor, pane: .memory), "memory")
        shoot(PanelHost(monitor: monitor, pane: .storage), "storage")
        shoot(
            HeadsUpView(monitor: monitor, onDismiss: {}, onSnooze: {}, onOpen: {}, onStorage: {})
                .padding(24)
                .background(Color(red: 0.11, green: 0.12, blue: 0.15)),
            "card"
        )

        let selection = SettingsSelection()
        selection.section = .headsUp
        shoot(SettingsWindowView(monitor: monitor, selection: selection), "settings")

        print("readme shots written to \(out)")
        exit(0)
    }

    private static func islandView(_ monitor: Monitor, _ model: IslandModel) -> some View {
        IslandView(monitor: monitor, model: model, onToggle: {}, onDismiss: {}, onSnooze: {}, onOpen: {}, onStorage: {})
    }

    private static func snapshot(_ view: some View) -> CGImage? {
        RenderPreview.bitmap(view.transaction { $0.animation = nil }, appearance: .darkAqua)?.cgImage
    }

    private static func seedMemory(_ monitor: Monitor) {
        let pages: UInt64 = 16_384
        monitor.vm = Probes.VMSample(
            pageSize: pages,
            totalBytes: UInt64(24 * gb),
            wiredBytes: UInt64(4.2 * gb),
            compressedBytes: UInt64(6.9 * gb),
            appBytes: UInt64(9.4 * gb),
            cachedBytes: UInt64(2.6 * gb),
            freeBytes: UInt64(0.5 * gb),
            pageInsBytes: 0,
            pageOutsBytes: 0
        )
        monitor.swap = Probes.SwapSample(total: UInt64(8 * gb), used: UInt64(6.1 * gb), encrypted: true)
        monitor.pressure = .warning
        monitor.lastSampledAt = Date()
        monitor.cpuUsage = 0.23

        let apps: [(String, String?, Double, Int, Double)] = [
            ("Google Chrome", "/Applications/Google Chrome.app", 4.8, 31, 12),
            ("Xcode", "/Applications/Xcode.app", 3.9, 6, 41),
            ("Docker", "/Applications/Docker.app", 3.1, 9, 4),
            ("Figma", "/Applications/Figma.app", 1.7, 7, 2),
            ("node", nil, 1.2, 4, 18),
            ("Safari", "/Applications/Safari.app", 0.9, 5, 1),
            ("Music", "/System/Applications/Music.app", 0.4, 2, 0),
            ("postgres", nil, 0.3, 8, 0),
        ]
        let started = Date().addingTimeInterval(-6 * 3600)
        monitor.groups = apps.enumerated().map { index, app in
            AppGroup(
                id: "readme-\(index)",
                name: app.0,
                bundleIdentifier: nil,
                bundlePath: app.1,
                projectPath: app.0 == "node" ? NSHomeDirectory() + "/code/shop" : nil,
                pids: Array(1...Int32(app.3)).map { 40_000 + Int32(index) * 100 + $0 },
                memoryBytes: UInt64(app.2 * gb),
                cpuPercent: app.4,
                isApproximate: false,
                isSystemOwned: false,
                isRunningApp: app.1 != nil,
                isFrontmost: app.0 == "Xcode",
                isHidden: app.0 == "Docker",
                startedAt: started
            )
        }

        monitor.advice = Advisor.advise(
            AdvisorInput(
                vm: monitor.vm!, swap: monitor.swap, pressure: .warning, disk: nil,
                groups: monitor.groups, growth: GrowthTracker(),
                lastActive: ["readme-0": Date().addingTimeInterval(-2 * 3600)],
                reclaimableStorage: nil
            ),
            prefs: monitor.prefs
        )
    }
}

/// A dark slice of screen with a menu bar, for the island to hang from.
private struct Desk<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.11, green: 0.12, blue: 0.15)
            HStack(spacing: 14) {
                Image(systemName: "apple.logo").font(.system(size: 13))
                Text("Finder").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View", "Go"], id: \.self) { Text($0).font(.system(size: 13)) }
                Spacer()
                Image(systemName: "memorychip").font(.system(size: 13))
                Image(systemName: "wifi").font(.system(size: 13))
                Text("Tue 9:41").font(.system(size: 13))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Color.white.opacity(0.06))
            content
        }
        .frame(width: 760, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The compact island in each of its moods, one strip per row.
private struct StateSheet: View {
    var images: [(String, CGImage)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(images.indices, id: \.self) { index in
                HStack(spacing: 16) {
                    Text(images[index].0)
                        .font(Theme.font(13, 560))
                        .foregroundStyle(Color(white: 0.75))
                        .frame(width: 120, alignment: .trailing)
                    Image(decorative: images[index].1, scale: 2)
                }
            }
        }
        .padding(20)
        .background(Color(red: 0.07, green: 0.08, blue: 0.1))
    }
}
