import AppKit
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
            print("rendered")
            exit(0)
        }
        RunLoop.main.run()
    }

    private static func render(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view.environment(\.staticRender, true))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            print("render failed for \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private static func seedStorage(_ monitor: Monitor) {
        let home = NSHomeDirectory()
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

        monitor.storageItems = rows.map {
            CleanupItem(path: $0.0, title: $0.1, category: $0.2, risk: $0.3,
                        reason: $0.4, sizeBytes: $0.5, heldBy: $0.6)
        }
        monitor.selection = Set(
            monitor.storageItems.filter { $0.risk.defaultsOn && $0.isSelectable }.map(\.id)
        )
        monitor.statusLine = "\(Fmt.bytes(monitor.reclaimableBytes)) can be cleared."
    }
}

/// Mirrors PanelView but with the pane fixed, since its selection is local state.
private struct PanelHost: View {
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
