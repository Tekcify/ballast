import AppKit
import BallastCore
import SwiftUI

/// Whether the card has been expanded into the full panel.
@MainActor
@Observable
final class HeadsUpState {
    var expanded = false
    var pane: Pane = .memory
}

/// The two looks the heads-up can take: a floating card or the notch island.
@MainActor
protocol HeadsUpSurface: AnyObject {
    /// True while a memory alert is on screen. The island can also be up for
    /// a scan or the always-on readout, which does not count.
    var isVisible: Bool { get }
    var isExpanded: Bool { get }
    var frame: NSRect? { get }
    func present()
    func close()
    func closeSoon()
    func cancelClose()
    /// Shows the full Ballast panel, opened on `pane`.
    func expand(to pane: Pane)
    /// Re-reads settings and activity, for surfaces that show more than alerts.
    func sync()
    /// Hides everything before the other look takes over.
    func teardown()
}

extension HeadsUpSurface {
    func expand() { expand(to: .memory) }
}

/// SwiftUI buttons in a window of an inactive app swallow the first click to
/// focus the window. Heads-up surfaces should act on the first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating card shown under the menu bar icon. It never activates Ballast, so
/// whatever you are typing into keeps focus. "Open Ballast" expands it into the
/// full panel in place, because SwiftUI's MenuBarExtra cannot be opened from code.
@MainActor
final class HeadsUpController: HeadsUpSurface {
    private unowned let monitor: Monitor
    private var panel: HeadsUpWindow?
    private var closeTask: Task<Void, Never>?
    private let state = HeadsUpState()
    private var outsideClicks: Any?
    private var escapeKey: Any?
    /// Bumped on every show and hide, so a fade-out that finishes after the card
    /// was shown again does not hide the new one.
    private var generation = 0

    init(monitor: Monitor) { self.monitor = monitor }

    var isVisible: Bool { panel?.isVisible == true }
    var isExpanded: Bool { state.expanded }
    var frame: NSRect? { panel?.frame }

    func expand(to pane: Pane) {
        cancelClose()
        state.pane = pane
        state.expanded = true
        guard outsideClicks == nil else { return }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.close() }
        }
        escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
    }

    func present() {
        cancelClose()
        if panel?.isVisible != true { state.expanded = false }
        monitor.lastQuitOutcome = nil
        let panel = panel ?? makePanel()
        self.panel = panel
        generation += 1
        guard !panel.isVisible || panel.alphaValue < 1 else { return }

        let size = panel.contentView?.fittingSize ?? NSSize(width: HeadsUpView.width, height: 200)
        panel.setFrame(placement(for: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        cancelClose()
        removeMonitors()
        guard let panel, panel.isVisible else { return }
        generation += 1
        let closing = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.generation == closing else { return }
            panel.orderOut(nil)
            self.state.expanded = false
        }
    }

    private func removeMonitors() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let escapeKey { NSEvent.removeMonitor(escapeKey) }
        outsideClicks = nil
        escapeKey = nil
    }

    /// Pressure has eased. The card says so, then gets out of the way.
    func closeSoon() {
        guard closeTask == nil, isVisible, !state.expanded else { return }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.closeTask = nil
            self?.close()
        }
    }

    func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    func sync() {}

    func teardown() { close() }

    private func makePanel() -> HeadsUpWindow {
        let panel = HeadsUpWindow(
            contentRect: NSRect(x: 0, y: 0, width: HeadsUpView.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let view = HeadsUpRoot(
            monitor: monitor,
            state: state,
            onDismiss: { [weak self] in self?.monitor.dismissHeadsUp() },
            onSnooze: { [weak self] in self?.monitor.snoozeHeadsUp() },
            onOpen: { [weak self] in self?.expand() },
            onStorage: { [weak self] in self?.expand(to: .storage) },
            onSize: { [weak self] size in self?.resize(to: size) }
        )
        panel.contentView = FirstMouseHostingView(rootView: view)
        return panel
    }

    /// Keeps the top edge where it is, so the card grows downwards as rows
    /// appear instead of climbing into the menu bar.
    private func resize(to size: CGSize) {
        guard let panel, size.height > 0 else { return }
        let current = panel.frame
        guard abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
        let frame = panel.isVisible
            ? NSRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
            : placement(for: size)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func placement(for size: NSSize) -> NSRect {
        let anchor = StatusItemLocator.button()?.window?.frame
        let screen = StatusItemLocator.button()?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 8
        var x = anchor.map { $0.midX - size.width / 2 } ?? (visible.maxX - size.width - margin)
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        return NSRect(x: x, y: visible.maxY - size.height - 6, width: size.width, height: size.height)
    }
}

/// Borderless panels refuse key status by default, which leaves the first click
/// on a button doing nothing. A non-activating panel can be key without
/// bringing Ballast forward.
final class HeadsUpWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Finds the menu bar item SwiftUI made for the MenuBarExtra, so the card can
/// sit under it. The process also holds replicant windows of other menu bar
/// items, which have no real button and are skipped.
enum StatusItemLocator {
    static func button() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = find(in: subview) { return button }
        }
        return nil
    }
}

/// The card, or the full panel once "Open Ballast" is pressed.
private struct HeadsUpRoot: View {
    var monitor: Monitor
    var state: HeadsUpState
    var onDismiss: () -> Void
    var onSnooze: () -> Void
    var onOpen: () -> Void
    var onStorage: () -> Void
    var onSize: (CGSize) -> Void

    var body: some View {
        Group {
            if state.expanded {
                PanelView(monitor: monitor, pane: state.pane)
                    .id(state.pane)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                    .fixedSize()
            } else {
                HeadsUpView(monitor: monitor, onDismiss: onDismiss, onSnooze: onSnooze, onOpen: onOpen, onStorage: onStorage)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }
}

struct HeadsUpView: View {
    static let width: CGFloat = 320

    var monitor: Monitor
    var onDismiss: () -> Void
    var onSnooze: () -> Void
    var onOpen: (() -> Void)?
    var onStorage: (() -> Void)? = nil

    var body: some View {
        PressureSummary(monitor: monitor, onDismiss: onDismiss, onSnooze: onSnooze, onOpen: onOpen, onStorage: onStorage)
            .padding(14)
            .frame(width: Self.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

/// What memory is doing and what to quit, shared by the card and the island.
struct PressureSummary: View {
    var monitor: Monitor
    var onDismiss: () -> Void
    var onSnooze: () -> Void
    var onOpen: (() -> Void)?
    /// Opens the panel on the Storage tab, so disk cleanup is one click away.
    var onStorage: (() -> Void)? = nil

    private var strained: Bool { monitor.pressure > .normal }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(headline)
                    .font(Theme.font(13.5, 600))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Theme.fill))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            Text(detail)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let vm = monitor.vm, strained {
                MeterBar(segments: [
                    .init(color: Theme.appMemory, fraction: share(vm.appBytes, vm)),
                    .init(color: Theme.wired, fraction: share(vm.wiredBytes, vm)),
                    .init(color: Theme.compressed, fraction: share(vm.compressedBytes, vm)),
                ], height: 6)
            }

            if strained, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestionsTitle)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(suggestions, id: \.name) { item in
                            SuggestionRow(suggestion: item, monitor: monitor)
                        }
                    }
                }
            }

            if let outcome = monitor.lastQuitOutcome {
                Text(outcome)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }

            if strained {
                HStack(spacing: 8) {
                    QuietButton(title: "Snooze 1h", action: onSnooze)
                    Spacer(minLength: 4)
                    if let onStorage {
                        QuietButton(title: "Storage", action: onStorage)
                    }
                    if let onOpen {
                        PrimaryButton(title: "Open Ballast", action: onOpen)
                    }
                }
            }
        }
    }

    private var headline: String {
        switch monitor.pressure {
        case .normal: "Okay, memory is chillin again"
        case .warning: "Your memory is getting cooked"
        case .critical: "Your memory is fully cooked"
        }
    }

    private var detail: String {
        guard strained, let vm = monitor.vm else {
            return "Pressure eased off. This card dips in a sec."
        }
        var text = "\(Fmt.bytes(vm.usedBytes)) of \(Fmt.bytes(vm.totalBytes)) in use. macOS is squeezing \(Fmt.bytes(vm.compressedBytes))"
        if let swap = monitor.swap, swap.used > 0 {
            text += " and leaning on \(Fmt.bytes(swap.used)) of swap"
        }
        return text + ". Close something heavy and let it breathe."
    }

    private var tint: Color {
        switch monitor.pressure {
        case .normal: Theme.positive
        case .warning: Theme.warning
        case .critical: Theme.critical
        }
    }

    private func share(_ value: UInt64, _ vm: Probes.VMSample) -> Double {
        vm.totalBytes == 0 ? 0 : Double(value) / Double(vm.totalBytes)
    }

    struct Suggestion {
        var name: String
        var pids: [pid_t]
        var bytes: UInt64
        var bundlePath: String?
    }

    private var adviceSuggestions: [Suggestion] {
        monitor.advice.compactMap { advice in
            guard case .quit(let name, let pids) = advice.action else { return nil }
            let group = monitor.groups.first { "quit:\($0.id)" == advice.id }
            return Suggestion(name: name, pids: pids, bytes: advice.reclaimBytes, bundlePath: group?.bundlePath)
        }
    }

    /// The advisor holds back when nothing clearly deserves quitting. The card
    /// still names the biggest apps, since that is what you came to see.
    private var suggestions: [Suggestion] {
        let advised = adviceSuggestions
        if !advised.isEmpty { return Array(advised.prefix(3)) }
        return monitor.listedGroups
            .filter { !Grouping.isEssential($0) && !$0.isFrontmost }
            .prefix(3)
            .map { Suggestion(name: $0.name, pids: $0.pids, bytes: $0.memoryBytes, bundlePath: $0.bundlePath) }
    }

    private var suggestionsTitle: String {
        adviceSuggestions.isEmpty ? "Biggest RAM eaters" : "Quit one of these"
    }
}

private struct SuggestionRow: View {
    var suggestion: PressureSummary.Suggestion
    var monitor: Monitor

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(bundlePath: suggestion.bundlePath)
            Text(suggestion.name)
                .font(Theme.rowTitle)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(Fmt.bytes(suggestion.bytes)).font(Theme.number)
            QuietButton(title: "Quit", tint: Theme.critical) {
                Task { await monitor.quit(name: suggestion.name, pids: suggestion.pids) }
            }
        }
        .padding(.vertical, 4)
    }
}
