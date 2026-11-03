import SwiftUI

@main
struct BallastApp: App {
    @State private var monitor = Monitor()

    init() {
        Diagnostic.runIfRequested()
        Theme.registerBundledFont()
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
    @Bindable var monitor: Monitor

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
