import AppKit
import SwiftUI

/// Geometry and priorities for the notch island, kept free of AppKit so the
/// arithmetic can be tested.
nonisolated enum IslandLayout {
    /// Room either side of the notch for the live activity's icon and value.
    static let wing: CGFloat = 58
    /// Concave top corners that let the island flow out of the bezel.
    static let shoulder: CGFloat = 6
    static let expandedShoulder: CGFloat = 10
    static let expandedWidth: CGFloat = 372
    /// Used when matching the notch on a display that has none.
    static let fallbackCore = CGSize(width: 200, height: 32)

    enum Mode: Equatable, Sendable {
        case alert, recovered, cleaning, scanning, glance
    }

    /// Width and height of the hardware notch, or nil when the display has none.
    static func notchSize(screenWidth: CGFloat, safeTop: CGFloat, leftWidth: CGFloat?, rightWidth: CGFloat?) -> CGSize? {
        guard safeTop > 0, let leftWidth, let rightWidth else { return nil }
        let width = screenWidth - leftWidth - rightWidth
        guard width > 0 else { return nil }
        return CGSize(width: width, height: safeTop)
    }

    /// The part of the pill that sits over the notch: the notch itself, or the
    /// size you set when you would rather not match it.
    static func core(notch: CGSize?, matchNotch: Bool, custom: CGSize) -> CGSize {
        matchNotch ? (notch ?? fallbackCore) : custom
    }

    static func compactSize(core: CGSize) -> CGSize {
        CGSize(width: core.width + 2 * (wing + shoulder), height: core.height)
    }

    /// Flush with the top edge of the screen and centred on it, which is where
    /// the notch is.
    static func windowFrame(size: CGSize, screen: CGRect) -> CGRect {
        CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
    }

    /// A memory alert outranks a cleanup, which outranks a scan, which outranks
    /// the always-on readout.
    static func mode(
        alert: Bool, strained: Bool, scanning: Bool, cleaning: Bool, liveActivities: Bool, alwaysOn: Bool
    ) -> Mode? {
        if alert { return strained ? .alert : .recovered }
        if liveActivities, cleaning { return .cleaning }
        if liveActivities, scanning { return .scanning }
        if alwaysOn { return .glance }
        return nil
    }
}

@MainActor
@Observable
final class IslandModel {
    var alert = false
    var presented = false
    var expanded = false
    var showingPanel = false
    var panelPane: Pane = .memory
    var hovering = false
    var notch: CGSize?
}

/// The heads-up as a Dynamic Island around the notch. The window covers the
/// whole area the island can grow into, ignores the mouse unless the pointer
/// is over the island itself, and never activates Ballast.
@MainActor
final class IslandController: HeadsUpSurface {
    static let windowSize = CGSize(width: 480, height: 760)

    private unowned let monitor: Monitor
    let model = IslandModel()
    private var window: IslandWindow?
    /// The island's frame in the window's top-left coordinates, as SwiftUI laid it out.
    private var islandRect: CGRect = .zero
    private var tracking: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var outsideClicks: Any?
    private var escapeKey: Any?
    private var screenObserver: NSObjectProtocol?

    init(monitor: Monitor) {
        self.monitor = monitor
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.position() }
        }
    }

    private var prefs: Preferences { monitor.prefs }

    var isVisible: Bool { model.alert && window?.isVisible == true }
    var isExpanded: Bool { model.showingPanel }

    var frame: NSRect? {
        guard let window, window.isVisible else { return nil }
        return screenRect(islandRect, in: window)
    }

    var mode: IslandLayout.Mode? {
        IslandLayout.mode(
            alert: model.alert,
            strained: monitor.pressure > .normal,
            scanning: monitor.isScanning,
            cleaning: monitor.isCleaning,
            liveActivities: prefs.islandLiveActivities,
            alwaysOn: prefs.islandAlwaysOn
        )
    }

    // MARK: HeadsUpSurface

    func present() {
        cancelClose()
        monitor.lastQuitOutcome = nil
        let wasAlert = model.alert
        model.alert = true
        sync()
        guard !wasAlert else { return }
        haptic()
        if prefs.islandAutoExpand {
            setExpanded(true)
            scheduleCollapse(after: 6)
        }
    }

    func close() {
        cancelClose()
        model.alert = false
        collapsePanel()
    }

    func closeSoon() {
        guard closeTask == nil, model.alert, !model.showingPanel else { return }
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

    func expand(to pane: Pane) {
        cancelCollapse()
        model.panelPane = pane
        model.showingPanel = true
        model.expanded = true
        sync()
        installPanelMonitors()
    }

    func sync() {
        if mode != nil || model.showingPanel { show() } else { hide() }
    }

    /// Hides everything, used when switching to the card.
    func teardown() {
        cancelClose()
        model.alert = false
        model.showingPanel = false
        removePanelMonitors()
        hide()
    }

    // MARK: Interaction

    func toggleExpanded() {
        cancelCollapse()
        setExpanded(!model.expanded)
    }

    func collapsePanel() {
        model.showingPanel = false
        removePanelMonitors()
        setExpanded(false)
        sync()
    }

    func reportRect(_ rect: CGRect) {
        islandRect = rect
    }

    private func setExpanded(_ expanded: Bool) {
        guard model.expanded != expanded else { return }
        model.expanded = expanded
        if expanded { haptic() }
    }

    private func scheduleCollapse(after seconds: Double) {
        cancelCollapse()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.model.hovering, !self.model.showingPanel else { return }
            self.setExpanded(false)
        }
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func haptic() {
        guard prefs.islandHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: Window

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        let window = window ?? makeWindow()
        self.window = window
        position()
        guard !window.isVisible || !model.presented else { return }
        window.orderFrontRegardless()
        startTracking()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            self.model.presented = true
        }
    }

    /// Shrinks back into the notch, then leaves the screen.
    private func hide() {
        guard let window, window.isVisible, hideTask == nil else { return }
        model.expanded = false
        model.presented = false
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, let self else { return }
            window.orderOut(nil)
            self.stopTracking()
            self.model.hovering = false
            self.hideTask = nil
        }
    }

    func position() {
        guard let window, let screen = targetScreen() else { return }
        model.notch = IslandLayout.notchSize(
            screenWidth: screen.frame.width,
            safeTop: screen.safeAreaInsets.top,
            leftWidth: screen.auxiliaryTopLeftArea?.width,
            rightWidth: screen.auxiliaryTopRightArea?.width
        )
        let frame = IslandLayout.windowFrame(size: Self.windowSize, screen: screen.frame)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    private func targetScreen() -> NSScreen? {
        let menuBar = StatusItemLocator.button()?.window?.screen ?? NSScreen.screens.first
        switch prefs.islandScreen {
        case .notch:
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? menuBar
        case .menuBar:
            return menuBar
        case .mouse:
            let point = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? menuBar
        }
    }

    private func makeWindow() -> IslandWindow {
        let window = IslandWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true

        let view = IslandView(
            monitor: monitor,
            model: model,
            onToggle: { [weak self] in self?.toggleExpanded() },
            onDismiss: { [weak self] in self?.monitor.dismissHeadsUp() },
            onSnooze: { [weak self] in self?.monitor.snoozeHeadsUp() },
            onOpen: { [weak self] in self?.expand() },
            onStorage: { [weak self] in self?.expand(to: .storage) },
            onRect: { [weak self] rect in self?.reportRect(rect) }
        )
        window.contentView = FirstMouseHostingView(rootView: view)
        return window
    }

    private func screenRect(_ rect: CGRect, in window: NSWindow) -> CGRect {
        CGRect(
            x: window.frame.minX + rect.minX,
            y: window.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: Pointer

    /// Polling the pointer is the one approach that works while Ballast is
    /// inactive and the window is ignoring the mouse.
    private func startTracking() {
        guard tracking == nil else { return }
        tracking = Task { [weak self] in
            while !Task.isCancelled {
                self?.trackPointer()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopTracking() {
        tracking?.cancel()
        tracking = nil
    }

    private func trackPointer() {
        guard let window, window.isVisible, model.presented else { return }
        let inside = screenRect(islandRect, in: window).insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if window.ignoresMouseEvents == inside { window.ignoresMouseEvents = !inside }
        guard inside != model.hovering else { return }
        model.hovering = inside
        inside ? hoverBegan() : hoverEnded()
    }

    private func hoverBegan() {
        cancelCollapse()
        guard prefs.islandExpandOnHover, !model.expanded else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self, self.model.hovering else { return }
            self.setExpanded(true)
        }
    }

    private func hoverEnded() {
        hoverTask?.cancel()
        hoverTask = nil
        guard model.expanded, !model.showingPanel else { return }
        scheduleCollapse(after: 0.5)
    }

    private func installPanelMonitors() {
        guard outsideClicks == nil else { return }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.collapsePanel() }
        }
        escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.collapsePanel()
            return nil
        }
    }

    private func removePanelMonitors() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let escapeKey { NSEvent.removeMonitor(escapeKey) }
        outsideClicks = nil
        escapeKey = nil
    }
}

/// Borderless and allowed over the menu bar. AppKit would otherwise push the
/// window below it.
final class IslandWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: Views

/// Black island with concave shoulders at the top edge and rounded corners at
/// the bottom. Both radii animate, so it can grow out of the notch.
nonisolated struct IslandShape: Shape {
    var shoulder: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set {
            shoulder = newValue.first
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 4, rect.height / 2))
        let r = max(0, min(radius, (rect.width - 2 * s) / 2, rect.height - s))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX + s, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + s, y: rect.minY + s), radius: s
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX + s, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX + s + r, y: rect.maxY), radius: r
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX - s, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - s, y: rect.maxY - r), radius: r
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX - s, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: s
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    var monitor: Monitor
    var model: IslandModel
    var onToggle: () -> Void
    var onDismiss: () -> Void
    var onSnooze: () -> Void
    var onOpen: () -> Void
    var onStorage: () -> Void = {}
    var onRect: (CGRect) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var prefs: Preferences { monitor.prefs }

    private var core: CGSize {
        IslandLayout.core(
            notch: model.notch,
            matchNotch: prefs.islandMatchNotch,
            custom: CGSize(width: prefs.islandWidth, height: prefs.islandHeight)
        )
    }

    private var mode: IslandLayout.Mode? {
        IslandLayout.mode(
            alert: model.alert,
            strained: monitor.pressure > .normal,
            scanning: monitor.isScanning,
            cleaning: monitor.isCleaning,
            liveActivities: prefs.islandLiveActivities,
            alwaysOn: prefs.islandAlwaysOn
        ) ?? (model.showingPanel ? .glance : nil)
    }

    private var isOpen: Bool { model.presented && (model.expanded || model.showingPanel) }

    private var width: CGFloat {
        if !model.presented { return core.width }
        if model.showingPanel { return Theme.panelWidth + 2 * IslandLayout.expandedShoulder }
        if model.expanded { return IslandLayout.expandedWidth }
        return IslandLayout.compactSize(core: core).width
    }

    private var shape: IslandShape {
        IslandShape(
            shoulder: isOpen ? IslandLayout.expandedShoulder : IslandLayout.shoulder,
            radius: isOpen ? prefs.islandCornerRadius + 14 : prefs.islandCornerRadius
        )
    }

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.78)
    }

    var body: some View {
        content
            .frame(width: width, alignment: .top)
            .frame(minHeight: core.height, alignment: .top)
            .background(shape.fill(Color.black))
            .clipShape(shape)
            .shadow(color: .black.opacity(isOpen ? 0.35 : 0), radius: 16, y: 8)
            .opacity(model.presented || model.notch != nil ? 1 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onRect($0) }
            .animation(animation, value: model.presented)
            .animation(animation, value: model.expanded)
            .animation(animation, value: model.showingPanel)
            .animation(animation, value: mode)
            .animation(.easeOut(duration: 0.15), value: prefs.islandCornerRadius)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        if model.showingPanel, model.presented {
            VStack(spacing: 0) {
                Color.clear.frame(height: core.height)
                PanelView(monitor: monitor, pane: model.panelPane)
                    .id(model.panelPane)
            }
            .padding(.horizontal, IslandLayout.expandedShoulder)
            .padding(.bottom, 6)
            .transition(.opacity)
        } else if model.expanded, model.presented, let mode {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: core.height)
                expanded(mode)
                    .padding(.horizontal, 18 + IslandLayout.expandedShoulder)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        } else {
            compact
                .frame(height: core.height)
                .opacity(model.presented ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .transition(.opacity)
        }
    }

    // MARK: Compact

    private var compact: some View {
        HStack(spacing: 0) {
            leading.frame(width: IslandLayout.wing)
            Color.clear.frame(width: core.width)
            trailing.frame(width: IslandLayout.wing)
        }
        .padding(.horizontal, IslandLayout.shoulder)
        .font(Theme.font(12, 600, tabular: true))
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var leading: some View {
        switch mode {
        case .alert:
            symbol("flame.fill", tint: pressureTint)
        case .recovered:
            symbol("checkmark.circle.fill", tint: Theme.positive)
        case .scanning:
            symbol("magnifyingglass", tint: .white)
        case .cleaning:
            symbol("sparkles", tint: Theme.positive)
        case .glance, nil:
            symbol("memorychip", tint: .white.opacity(0.85))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch mode {
        case .alert:
            Text(Fmt.percent(monitor.usedFraction)).foregroundStyle(pressureTint)
        case .recovered:
            Text("Chillin").font(Theme.font(11, 560)).foregroundStyle(Theme.positive)
        case .scanning, .cleaning:
            HStack(spacing: 4) {
                ProgressRing(fraction: progressFraction, tint: mode == .cleaning ? Theme.positive : .white)
                Text(Fmt.percent(progressFraction))
                    .font(Theme.font(10.5, 560, tabular: true))
            }
        case .glance, nil:
            Text(Fmt.percent(monitor.usedFraction)).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && (mode == .alert || mode == .scanning))
    }

    private var pressureTint: Color {
        monitor.pressure == .critical ? Theme.critical : Theme.warning
    }

    private var progressFraction: Double {
        guard let progress = monitor.scanProgress, progress.total > 1 else { return 0 }
        return min(Double(progress.completed) / Double(progress.total), 1)
    }

    // MARK: Expanded

    @ViewBuilder
    private func expanded(_ mode: IslandLayout.Mode) -> some View {
        switch mode {
        case .alert, .recovered:
            PressureSummary(monitor: monitor, onDismiss: onDismiss, onSnooze: onSnooze, onOpen: onOpen, onStorage: onStorage)
        case .scanning, .cleaning:
            ActivitySummary(monitor: monitor, cleaning: mode == .cleaning, onOpen: onStorage)
        case .glance:
            GlanceSummary(monitor: monitor, onOpen: onOpen)
        }
    }
}

/// Small determinate ring for the compact live activity.
private struct ProgressRing: View {
    var fraction: Double
    var tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// Scan or cleanup in progress, as a live activity.
private struct ActivitySummary: View {
    var monitor: Monitor
    var cleaning: Bool
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: cleaning ? "sparkles" : "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(cleaning ? Theme.positive : .primary)
                Text(cleaning ? "Clearing your picks" : "Sizing up your disk")
                    .font(Theme.font(13.5, 600))
                Spacer(minLength: 4)
                if let progress = monitor.scanProgress, progress.total > 1 {
                    Text("\(progress.completed) of \(progress.total)")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = monitor.scanProgress {
                Text(progress.stage)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if progress.total > 1 {
                    MeterBar(segments: [
                        .init(color: cleaning ? Theme.positive : Theme.appMemory,
                              fraction: Double(progress.completed) / Double(progress.total)),
                    ], height: 5)
                }
            }

            HStack(spacing: 8) {
                Text(cleaning
                     ? "Clearing \(Fmt.bytes(monitor.selectedBytes))"
                     : "\(Fmt.bytes(monitor.reclaimableBytes)) up for grabs so far")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !cleaning {
                    QuietButton(title: "Stop") { monitor.cancelScan() }
                }
                PrimaryButton(title: "Open Ballast", action: onOpen)
            }
        }
    }
}

/// The always-on readout, expanded: where memory stands and who is using it.
private struct GlanceSummary: View {
    var monitor: Monitor
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(monitor.vm.map { Fmt.bytes($0.usedBytes) } ?? "…")
                    .font(Theme.font(22, 600, tabular: true))
                Text(monitor.vm.map { "of \(Fmt.bytes($0.totalBytes)) · \(monitor.pressure.label)" } ?? "")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let vm = monitor.vm, vm.totalBytes > 0 {
                MeterBar(segments: [
                    .init(color: Theme.appMemory, fraction: Double(vm.appBytes) / Double(vm.totalBytes)),
                    .init(color: Theme.wired, fraction: Double(vm.wiredBytes) / Double(vm.totalBytes)),
                    .init(color: Theme.compressed, fraction: Double(vm.compressedBytes) / Double(vm.totalBytes)),
                ], height: 5)
            }
            VStack(spacing: 6) {
                ForEach(monitor.listedGroups.filter { !Grouping.isEssential($0) }.prefix(3)) { group in
                    HStack(spacing: 8) {
                        AppIcon(bundlePath: group.bundlePath)
                        Text(group.name).font(Theme.rowTitle).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Fmt.bytes(group.memoryBytes)).font(Theme.number)
                    }
                }
            }
            HStack {
                Spacer()
                PrimaryButton(title: "Open Ballast", action: onOpen)
            }
        }
    }
}
