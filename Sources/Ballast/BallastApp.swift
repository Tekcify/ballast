import SwiftUI

@main
struct BallastApp: App {
    private let monitor: Monitor

    /// Monitoring starts at launch rather than when the panel first opens, so
    /// alerts and the heads-up card work before Ballast has ever been clicked.
    init() {
        Diagnostic.runIfRequested()
        Theme.registerBundledFont()
        monitor = Monitor()
        monitor.start()
        Diagnostic.selfTestIfRequested(monitor)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
                .task { monitor.start() }
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    var monitor: Monitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            if let label = monitor.menuBarLabel {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
    }

    private var symbol: String {
        switch monitor.pressure {
        case .normal: "memorychip"
        case .warning: "memorychip.fill"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch monitor.pressure {
        case .normal: .primary
        case .warning: Theme.warning
        case .critical: Theme.critical
        }
    }
}
