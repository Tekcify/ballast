import BallastCore
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case memory = "Memory"
    case storage = "Storage"
    case settings = "Settings"

    var id: String { rawValue }
}

struct PanelView: View {
    @Bindable var monitor: Monitor
    @State private var pane: Pane
    /// Set for the menu bar popover, whose window has to be resized by hand.
    var fitsWindow = false

    init(monitor: Monitor, pane: Pane = .memory, fitsWindow: Bool = false) {
        self.monitor = monitor
        self.fitsWindow = fitsWindow
        _pane = State(initialValue: pane)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch pane {
                    case .memory:
                        MemoryPane(monitor: monitor) { pane = .storage }
                    case .storage:
                        StoragePane(monitor: monitor)
                    case .settings:
                        SettingsPane(monitor: monitor)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), Self.maxContentHeight))

            Hairline()
            tabs
        }
        .frame(width: Theme.panelWidth)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        .background {
            if fitsWindow { WindowFitter(height: panelHeight) }
        }
    }

    @State private var panelHeight: CGFloat = 0

    static let maxContentHeight: CGFloat = 580
    @State private var contentHeight: CGFloat = 0

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Pane.allCases) { item in
                Tab(title: item.rawValue, selected: pane == item) { pane = item }
            }
            Spacer(minLength: 4)
            if let at = monitor.lastSampledAt {
                Text(Fmt.shortTime(at))
                    .font(Theme.font(9.5, 420, tabular: true))
                    .foregroundStyle(.tertiary)
            }
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(.plain)
            .help("Quit Ballast")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// MenuBarExtra sizes its window when it opens and never shrinks it again, so a
/// shorter pane left a see-through band above the content. This resizes the
/// window to fit whenever the content changes, keeping the top edge where it is.
private struct WindowFitter: NSViewRepresentable {
    /// The panel's own laid out height. The popover's hosting view reports no
    /// fitting size of its own, so it cannot be asked.
    var height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async { [weak view] in
            guard height > 1, let window = view?.window else { return }
            let content = NSSize(width: window.contentLayoutRect.width, height: height)
            let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
            guard abs(window.frame.height - target.height) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y = frame.maxY - target.height
            frame.size.height = target.height
            window.setFrame(frame, display: true)
        }
    }
}

private struct Tab: View {
    var title: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(11, selected ? 580 : 460))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Theme.fill : (hovering ? Theme.fill.opacity(0.6) : .clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
