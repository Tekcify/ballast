import Foundation
import ServiceManagement

/// A locally built, ad-hoc signed bundle is not always accepted by
/// `SMAppService`, so fall back to writing a launch agent directly.
enum LoginItem {
    private static var agentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/com.tekcify.ballast.plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13, *), SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    enum Status {
        case enabled, needsApproval, off
    }

    /// macOS can register the item but hold it until you allow it in System
    /// Settings, which reads as on here but never launches.
    static var status: Status {
        if #available(macOS 13, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .needsApproval
            default: break
            }
        }
        return FileManager.default.fileExists(atPath: agentURL.path) ? .enabled : .off
    }

    static func openSystemSettings() {
        if #available(macOS 13, *) { SMAppService.openSystemSettingsLoginItems() }
    }

    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                    try? FileManager.default.removeItem(at: agentURL)
                }
                return
            } catch {
                // Fall through to the launch agent.
            }
        }
        enabled ? writeAgent() : removeAgent()
    }

    private static func writeAgent() {
        guard let executable = Bundle.main.executableURL?.path else { return }
        let plist: [String: Any] = [
            "Label": "com.tekcify.ballast",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(
            at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else { return }
        try? data.write(to: agentURL)
        _ = Shell.run("/bin/launchctl", ["load", "-w", agentURL.path], timeout: 10)
    }

    private static func removeAgent() {
        _ = Shell.run("/bin/launchctl", ["unload", "-w", agentURL.path], timeout: 10)
        try? FileManager.default.removeItem(at: agentURL)
    }
}
