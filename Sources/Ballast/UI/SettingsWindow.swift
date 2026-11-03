import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case headsUp = "Heads-up"
    case alerts = "Alerts"
    case storage = "Storage"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .headsUp: "capsule.portrait"
        case .alerts: "bell"
        case .storage: "internaldrive"
        case .about: "info.circle"
        }
    }
}

/// The full settings, in a window of its own. The popover keeps the handful of
/// switches you reach for often.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selection = SettingsSelection()

    func show(monitor: Monitor, section: SettingsSection? = nil) {
        if let section { selection.section = section }
        let window = window ?? makeWindow(monitor: monitor)
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(monitor: Monitor) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ballast Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsWindowView(monitor: monitor, selection: selection))
        return window
    }
}

@MainActor
@Observable
final class SettingsSelection {
    var section: SettingsSection = .general
}

struct SettingsWindowView: View {
    var monitor: Monitor
    var selection: SettingsSelection
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 1)
            if staticRender {
                page
            } else {
                ScrollView { page }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: 760)
        .frame(minHeight: 560, maxHeight: staticRender ? nil : 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(selection.section.rawValue)
                .font(Theme.font(20, 620))
            detail
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.appMemory)
                Text("Ballast").font(Theme.font(14, 620))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section, selected: selection.section == section) {
                    selection.section = section
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.fill)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection.section {
        case .general: GeneralSettings(monitor: monitor)
        case .headsUp: HeadsUpSettings(monitor: monitor)
        case .alerts: AlertSettings(monitor: monitor)
        case .storage: StorageSettings(monitor: monitor)
        case .about: AboutSettings(monitor: monitor)
        }
    }
}

private struct SidebarRow: View {
    var section: SettingsSection
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.appMemory : .secondary)
                Text(section.rawValue)
                    .font(Theme.font(12.5, selected ? 580 : 480))
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Theme.appMemory.opacity(0.14) : (hovering ? Theme.fill : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Building blocks

/// One quiet group of rows, the way System Settings lays them out.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(Theme.font(11.5, 580))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 11) { content }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
            if let footer {
                Text(footer)
                    .font(Theme.font(10.5, 440))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

struct SettingsToggle: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(12.5, 500))
                if let detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Switch(isOn: $isOn)
        }
    }
}

struct SettingsSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = "pt"
    var enabled: Bool = true
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.font(12.5, 500))
                .frame(width: 110, alignment: .leading)
            if staticRender {
                renderedSlider
            } else {
                Slider(value: $value, in: range, step: step)
                    .tint(Theme.appMemory)
                    .controlSize(.small)
            }
            Text("\(Int(value.rounded())) \(unit)")
                .font(Theme.number)
                .frame(width: 52, alignment: .trailing)
        }
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }

    /// Offscreen renders draw a stand-in, since the AppKit slider only draws once
    /// it is in a visible window.
    private var renderedSlider: some View {
        GeometryReader { proxy in
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 4)
                Capsule().fill(Theme.appMemory).frame(width: proxy.size.width * fraction, height: 4)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .frame(width: 14, height: 14)
                    .offset(x: proxy.size.width * fraction - 7)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 16)
    }
}

struct SettingsDivider: View {
    var body: some View { Hairline().padding(.horizontal, -14) }
}

// MARK: Sections

private struct GeneralSettings: View {
    var monitor: Monitor
    @State private var loginStatus = LoginItem.status

    private var prefs: Preferences { monitor.prefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Startup") {
                SettingsToggle(
                    title: "Start Ballast at login",
                    detail: loginDetail,
                    isOn: Binding(
                        get: { loginStatus != .off },
                        set: {
                            LoginItem.setEnabled($0)
                            loginStatus = LoginItem.status
                        }
                    )
                )
                if loginStatus == .needsApproval {
                    SettingsDivider()
                    HStack {
                        Text("macOS wants your OK before Ballast can launch on its own.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.warning)
                        Spacer(minLength: 8)
                        QuietButton(title: "Open Login Items", tint: Theme.appMemory) {
                            LoginItem.openSystemSettings()
                        }
                    }
                }
            }

            SettingsGroup(title: "Menu bar") {
                SettingsToggle(
                    title: "Show memory use next to the icon",
                    isOn: Binding(get: { prefs.showPercentInMenuBar }, set: { prefs.showPercentInMenuBar = $0 })
                )
                SettingsDivider()
                ValueStepper(
                        emphasized: true,
                    label: "Refresh memory every",
                    value: Binding(get: { prefs.refreshSeconds }, set: { prefs.refreshSeconds = $0 }),
                    range: 2...60, step: 1, format: { "\(Int($0)) s" }
                )
            }

            SettingsGroup(title: "Notifications", footer: "Delivering through \(monitor.alerter.describePath()).") {
                SettingsToggle(
                    title: "Send banners",
                    detail: "For leaks, low disk and swap. Memory pressure goes to the heads-up instead.",
                    isOn: Binding(get: { prefs.notificationsEnabled }, set: { prefs.notificationsEnabled = $0 })
                )
            }
        }
        .onAppear { loginStatus = LoginItem.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = LoginItem.status
        }
    }

    private var loginDetail: String {
        switch loginStatus {
        case .enabled: "On. Ballast starts watching as soon as you log in."
        case .needsApproval: "Waiting on your OK in System Settings."
        case .off: "Off. You'll have to open Ballast yourself after a restart."
        }
    }
}

private struct HeadsUpSettings: View {
    var monitor: Monitor

    private var prefs: Preferences { monitor.prefs }

    /// Every heads-up option goes through here so the live surface picks the
    /// change up straight away.
    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(
            get: { prefs[keyPath: keyPath] },
            set: {
                prefs[keyPath: keyPath] = $0
                monitor.applyHeadsUpSettings()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsToggle(
                    title: "Pop up when memory gets cooked",
                    detail: "Shows up when pressure holds for a couple of samples, or right away when it's critical.",
                    isOn: bind(\.headsUpEnabled)
                )
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Look")
                    .font(Theme.font(11.5, 580))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                HStack(spacing: 12) {
                    LookTile(style: .island, selected: prefs.headsUpStyle == .island) {
                        bind(\.headsUpStyle).wrappedValue = .island
                    }
                    LookTile(style: .card, selected: prefs.headsUpStyle == .card) {
                        bind(\.headsUpStyle).wrappedValue = .card
                    }
                }
            }

            if prefs.headsUpStyle == .island {
                IslandPreview(prefs: prefs, notch: detectedNotch?.size)

                SettingsGroup(title: "Shape", footer: notchFooter) {
                    SettingsToggle(
                        title: "Match my notch",
                        detail: "Sizes the island to the notch so it looks like part of the screen.",
                        isOn: bind(\.islandMatchNotch)
                    )
                    SettingsDivider()
                    SettingsSlider(title: "Width", value: bind(\.islandWidth), range: 120...320,
                                   enabled: !prefs.islandMatchNotch)
                    SettingsSlider(title: "Height", value: bind(\.islandHeight), range: 22...48,
                                   enabled: !prefs.islandMatchNotch)
                    SettingsDivider()
                    SettingsSlider(title: "Corner radius", value: bind(\.islandCornerRadius), range: 0...24)
                }

                SettingsGroup(title: "Where") {
                    HStack {
                        Text("Show on").font(Theme.font(12.5, 500))
                        Spacer(minLength: 8)
                        Segmented(
                            options: Preferences.IslandScreen.allCases.map { ($0, $0.label) },
                            selection: bind(\.islandScreen)
                        )
                    }
                }

                SettingsGroup(title: "Behaviour") {
                    SettingsToggle(title: "Expand when I hover", isOn: bind(\.islandExpandOnHover))
                    SettingsDivider()
                    SettingsToggle(
                        title: "Pop open on its own",
                        detail: "Expands for a few seconds when memory first gets cooked.",
                        isOn: bind(\.islandAutoExpand)
                    )
                    SettingsDivider()
                    SettingsToggle(
                        title: "Live activities",
                        detail: "Shows scan and cleanup progress around the notch.",
                        isOn: bind(\.islandLiveActivities)
                    )
                    SettingsDivider()
                    SettingsToggle(
                        title: "Always show memory",
                        detail: "Keeps a small readout by the notch, even when things are chill.",
                        isOn: bind(\.islandAlwaysOn)
                    )
                    SettingsDivider()
                    SettingsToggle(title: "Haptic tap on the trackpad", isOn: bind(\.islandHaptics))
                }
            } else {
                SettingsGroup(footer: "The card floats under the Ballast icon and never steals focus from what you're typing.") {
                    HStack {
                        Text("Card")
                            .font(Theme.font(12.5, 500))
                        Spacer()
                    }
                }
            }

            HStack(spacing: 8) {
                PrimaryButton(title: "Preview on screen") { monitor.previewHeadsUp() }
                QuietButton(title: "Reset look") {
                    prefs.resetHeadsUpLook()
                    monitor.applyHeadsUpSettings()
                }
                Spacer()
            }
        }
    }

    private var detectedNotch: (size: CGSize, name: String)? {
        for screen in NSScreen.screens {
            if let size = IslandLayout.notchSize(
                screenWidth: screen.frame.width,
                safeTop: screen.safeAreaInsets.top,
                leftWidth: screen.auxiliaryTopLeftArea?.width,
                rightWidth: screen.auxiliaryTopRightArea?.width
            ) {
                return (size, screen.localizedName)
            }
        }
        return nil
    }

    private var notchFooter: String {
        guard let notch = detectedNotch else {
            let core = IslandLayout.fallbackCore
            return "No notch on your displays, so matching uses \(Int(core.width)) × \(Int(core.height)) pt."
        }
        return "Found a \(Int(notch.size.width)) × \(Int(notch.size.height)) pt notch on \(notch.name)."
    }
}

/// Picks between the island and the card, each drawn as a small picture.
private struct LookTile: View {
    var style: Preferences.HeadsUpStyle
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: style == .island ? .top : .topTrailing) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(white: 0.16))
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 9)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7))
                    if style == .island {
                        IslandShape(shoulder: 3, radius: 7)
                            .fill(Color.black)
                            .frame(width: 92, height: 15)
                            .overlay(alignment: .leading) {
                                Image(systemName: "flame.fill")
                                    .font(.system(size: 6.5))
                                    .foregroundStyle(Theme.warning)
                                    .padding(.leading, 10)
                            }
                            .overlay(alignment: .trailing) {
                                Text("82%")
                                    .font(Theme.font(6.5, 600))
                                    .foregroundStyle(Theme.warning)
                                    .padding(.trailing, 9)
                            }
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(white: 0.92))
                            .frame(width: 76, height: 42)
                            .overlay(alignment: .topLeading) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Capsule().fill(Theme.warning).frame(width: 40, height: 3.5)
                                    Capsule().fill(Color.black.opacity(0.2)).frame(width: 58, height: 3)
                                    Capsule().fill(Color.black.opacity(0.2)).frame(width: 46, height: 3)
                                }
                                .padding(7)
                            }
                            .padding(.top, 13)
                            .padding(.trailing, 12)
                    }
                }
                .frame(height: 74)

                VStack(alignment: .leading, spacing: 2) {
                    Text(style.label).font(Theme.font(12.5, 580))
                    Text(style == .island ? "Grows out of the notch, live activity style" : "Floats under the menu bar icon")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.appMemory.opacity(0.1) : (hovering ? Color.primary.opacity(0.07) : Theme.fill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.appMemory : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(style.label) look")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The resting island at real size, redrawn as the shape options change.
struct IslandPreview: View {
    var prefs: Preferences
    var notch: CGSize?

    private var core: CGSize {
        IslandLayout.core(
            notch: notch,
            matchNotch: prefs.islandMatchNotch,
            custom: CGSize(width: prefs.islandWidth, height: prefs.islandHeight)
        )
    }

    var body: some View {
        let size = IslandLayout.compactSize(core: core)
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.14))
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: core.height)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
            IslandShape(shoulder: IslandLayout.shoulder, radius: prefs.islandCornerRadius)
                .fill(Color.black)
                .frame(width: size.width, height: core.height)
                .overlay {
                    HStack(spacing: 0) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                            .frame(width: IslandLayout.wing)
                        Color.clear.frame(width: core.width)
                        Text("82%")
                            .font(Theme.font(12, 600, tabular: true))
                            .foregroundStyle(Theme.warning)
                            .frame(width: IslandLayout.wing)
                    }
                    .padding(.horizontal, IslandLayout.shoulder)
                }
                .animation(.easeOut(duration: 0.15), value: prefs.islandCornerRadius)
                .animation(.easeOut(duration: 0.15), value: core)
        }
        .frame(height: max(core.height + 46, 90))
        .accessibilityLabel("Preview of the island at \(Int(size.width)) by \(Int(core.height)) points")
    }
}

private struct AlertSettings: View {
    var monitor: Monitor

    private var prefs: Preferences { monitor.prefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "When to speak up") {
                VStack(spacing: 10) {
                    ValueStepper(
                        emphasized: true,
                        label: "Warn when one app passes",
                        value: Binding(get: { prefs.perAppThresholdGB }, set: { prefs.perAppThresholdGB = $0 }),
                        range: 1...20, step: 1, format: { "\(Int($0)) GB" }
                    )
                    ValueStepper(
                        emphasized: true,
                        label: "Warn when swap passes",
                        value: Binding(get: { prefs.swapThresholdGB }, set: { prefs.swapThresholdGB = $0 }),
                        range: 1...32, step: 1, format: { "\(Int($0)) GB" }
                    )
                    ValueStepper(
                        emphasized: true,
                        label: "Call it a leak above",
                        value: Binding(get: { prefs.growthMBPerMinute }, set: { prefs.growthMBPerMinute = $0 }),
                        range: 20...1000, step: 20, format: { "\(Int($0)) MB/min" }
                    )
                    ValueStepper(
                        emphasized: true,
                        label: "Warn when free disk drops under",
                        value: Binding(get: { prefs.lowDiskGB }, set: { prefs.lowDiskGB = $0 }),
                        range: 5...200, step: 5, format: { "\(Int($0)) GB" }
                    )
                    ValueStepper(
                        emphasized: true,
                        label: "Treat an app as idle after",
                        value: Binding(get: { prefs.idleMinutes }, set: { prefs.idleMinutes = $0 }),
                        range: 5...180, step: 5, format: { "\(Int($0)) min" }
                    )
                }
            }

            SettingsGroup(title: "Repeats", footer: "The heads-up stays quiet for 15 minutes after you dismiss it, unless things get worse.") {
                ValueStepper(
                        emphasized: true,
                    label: "Repeat the same banner at most every",
                    value: Binding(get: { prefs.cooldownMinutes }, set: { prefs.cooldownMinutes = $0 }),
                    range: 5...180, step: 5, format: { "\(Int($0)) min" }
                )
            }
        }
    }
}

private struct StorageSettings: View {
    var monitor: Monitor

    private var prefs: Preferences { monitor.prefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Scanning", footer: monitor.lastScanAt.map { "Last scan \(Fmt.duration(Date().timeIntervalSince($0))) ago." }) {
                SettingsToggle(
                    title: "Measure storage in the background",
                    detail: "Never in the first five minutes after launch.",
                    isOn: Binding(get: { prefs.autoScanEnabled }, set: { prefs.autoScanEnabled = $0 })
                )
                SettingsDivider()
                ValueStepper(
                        emphasized: true,
                    label: "Measure every",
                    value: Binding(get: { prefs.autoScanHours }, set: { prefs.autoScanHours = $0 }),
                    range: 6...168, step: 6, format: { "\(Int($0)) h" }
                )
                SettingsDivider()
                SettingsToggle(
                    title: "Also measure node_modules",
                    detail: "Slow. Only dormant projects are offered, and never picked for you.",
                    isOn: Binding(get: { prefs.includeDependencyFolders }, set: { prefs.includeDependencyFolders = $0 })
                )
            }

            SettingsGroup(title: "List") {
                HStack {
                    Text("Show results").font(Theme.font(12.5, 500))
                    Spacer(minLength: 8)
                    Segmented(
                        options: [(true, "Biggest first"), (false, "By type")],
                        selection: Binding(get: { prefs.rankStorageBySize }, set: { prefs.rankStorageBySize = $0 })
                    )
                }
            }

            HStack(spacing: 8) {
                PrimaryButton(title: monitor.isScanning ? "Scanning…" : "Scan now", enabled: !monitor.isScanning && !monitor.isCleaning) {
                    monitor.scan()
                }
                QuietButton(title: "Cleanup log") { monitor.revealInFinder(Cleaner.logURL.path) }
                Spacer()
            }
        }
    }
}

private struct AboutSettings: View {
    var monitor: Monitor

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                HStack(spacing: 12) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.appMemory)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ballast").font(Theme.font(15, 620))
                        Text("Version \(version)").font(Theme.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            SettingsGroup(title: "How the numbers work") {
                Text("Per app figures are physical footprint, the same measure Activity Monitor shows. They're summed per app, so shared framework pages count once per process and the totals read higher than the system figure. \(monitor.approximateCount) system owned apps report resident size instead, because footprint needs elevated privileges.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                QuietButton(title: "Activity Monitor") { monitor.openActivityMonitor() }
                QuietButton(title: "Cleanup log") { monitor.revealInFinder(Cleaner.logURL.path) }
                QuietButton(title: "Source on GitHub") {
                    if let url = URL(string: "https://github.com/Tekcify/ballast") { NSWorkspace.shared.open(url) }
                }
                Spacer()
            }
        }
    }
}
