import Foundation
import Observation

@Observable
package final class Preferences {
    private let defaults = UserDefaults.standard

    private func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? fallback
    }
    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    package var refreshSeconds: Double {
        didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") }
    }
    package var perAppThresholdGB: Double {
        didSet { defaults.set(perAppThresholdGB, forKey: "perAppThresholdGB") }
    }
    package var swapThresholdGB: Double {
        didSet { defaults.set(swapThresholdGB, forKey: "swapThresholdGB") }
    }
    package var growthMBPerMinute: Double {
        didSet { defaults.set(growthMBPerMinute, forKey: "growthMBPerMinute") }
    }
    package var lowDiskGB: Double {
        didSet { defaults.set(lowDiskGB, forKey: "lowDiskGB") }
    }
    package var idleMinutes: Double {
        didSet { defaults.set(idleMinutes, forKey: "idleMinutes") }
    }
    package var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    package var cooldownMinutes: Double {
        didSet { defaults.set(cooldownMinutes, forKey: "cooldownMinutes") }
    }
    package var showPercentInMenuBar: Bool {
        didSet { defaults.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }
    package var includeDependencyFolders: Bool {
        didSet { defaults.set(includeDependencyFolders, forKey: "includeDependencyFolders") }
    }
    package var autoScanEnabled: Bool {
        didSet { defaults.set(autoScanEnabled, forKey: "autoScanEnabled") }
    }
    package var autoScanHours: Double {
        didSet { defaults.set(autoScanHours, forKey: "autoScanHours") }
    }
    package var headsUpEnabled: Bool {
        didSet { defaults.set(headsUpEnabled, forKey: "headsUpEnabled") }
    }
    package var rankStorageBySize: Bool {
        didSet { defaults.set(rankStorageBySize, forKey: "rankStorageBySize") }
    }

    // MARK: Heads-up look

    package enum HeadsUpStyle: String, CaseIterable, Sendable {
        case island, card
        package var label: String { self == .island ? "Island" : "Card" }
    }

    package enum IslandScreen: String, CaseIterable, Sendable {
        case notch, menuBar, mouse
        package var label: String {
            switch self {
            case .notch: "Notch display"
            case .menuBar: "Menu bar display"
            case .mouse: "Wherever my mouse is"
            }
        }
    }

    package var headsUpStyle: HeadsUpStyle {
        didSet { defaults.set(headsUpStyle.rawValue, forKey: "headsUpStyle") }
    }
    package var islandScreen: IslandScreen {
        didSet { defaults.set(islandScreen.rawValue, forKey: "islandScreen") }
    }
    /// Bottom corner radius of the resting pill. The expanded island adds to it.
    package var islandCornerRadius: Double {
        didSet { defaults.set(islandCornerRadius, forKey: "islandCornerRadius") }
    }
    package var islandMatchNotch: Bool {
        didSet { defaults.set(islandMatchNotch, forKey: "islandMatchNotch") }
    }
    package var islandWidth: Double {
        didSet { defaults.set(islandWidth, forKey: "islandWidth") }
    }
    package var islandHeight: Double {
        didSet { defaults.set(islandHeight, forKey: "islandHeight") }
    }
    package var islandExpandOnHover: Bool {
        didSet { defaults.set(islandExpandOnHover, forKey: "islandExpandOnHover") }
    }
    package var islandAutoExpand: Bool {
        didSet { defaults.set(islandAutoExpand, forKey: "islandAutoExpand") }
    }
    package var islandLiveActivities: Bool {
        didSet { defaults.set(islandLiveActivities, forKey: "islandLiveActivities") }
    }
    package var islandAlwaysOn: Bool {
        didSet { defaults.set(islandAlwaysOn, forKey: "islandAlwaysOn") }
    }
    package var islandHaptics: Bool {
        didSet { defaults.set(islandHaptics, forKey: "islandHaptics") }
    }

    package static let islandDefaults = (radius: 12.0, width: 220.0, height: 34.0)

    package func resetHeadsUpLook() {
        headsUpStyle = .island
        islandScreen = .notch
        islandCornerRadius = Self.islandDefaults.radius
        islandMatchNotch = true
        islandWidth = Self.islandDefaults.width
        islandHeight = Self.islandDefaults.height
        islandExpandOnHover = true
        islandAutoExpand = true
        islandLiveActivities = true
        islandAlwaysOn = false
        islandHaptics = true
    }

    package init() {
        refreshSeconds = defaults.object(forKey: "refreshSeconds") as? Double ?? 5
        perAppThresholdGB = defaults.object(forKey: "perAppThresholdGB") as? Double ?? 6
        swapThresholdGB = defaults.object(forKey: "swapThresholdGB") as? Double ?? 3
        growthMBPerMinute = defaults.object(forKey: "growthMBPerMinute") as? Double ?? 120
        lowDiskGB = defaults.object(forKey: "lowDiskGB") as? Double ?? 20
        idleMinutes = defaults.object(forKey: "idleMinutes") as? Double ?? 20
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        cooldownMinutes = defaults.object(forKey: "cooldownMinutes") as? Double ?? 20
        showPercentInMenuBar = defaults.object(forKey: "showPercentInMenuBar") as? Bool ?? true
        includeDependencyFolders = defaults.object(forKey: "includeDependencyFolders") as? Bool ?? false
        autoScanEnabled = defaults.object(forKey: "autoScanEnabled") as? Bool ?? true
        autoScanHours = defaults.object(forKey: "autoScanHours") as? Double ?? 24
        headsUpEnabled = defaults.object(forKey: "headsUpEnabled") as? Bool ?? true
        rankStorageBySize = defaults.object(forKey: "rankStorageBySize") as? Bool ?? true
        headsUpStyle = (defaults.string(forKey: "headsUpStyle")).flatMap(HeadsUpStyle.init) ?? .island
        islandScreen = (defaults.string(forKey: "islandScreen")).flatMap(IslandScreen.init) ?? .notch
        islandCornerRadius = defaults.object(forKey: "islandCornerRadius") as? Double ?? Self.islandDefaults.radius
        islandMatchNotch = defaults.object(forKey: "islandMatchNotch") as? Bool ?? true
        islandWidth = defaults.object(forKey: "islandWidth") as? Double ?? Self.islandDefaults.width
        islandHeight = defaults.object(forKey: "islandHeight") as? Double ?? Self.islandDefaults.height
        islandExpandOnHover = defaults.object(forKey: "islandExpandOnHover") as? Bool ?? true
        islandAutoExpand = defaults.object(forKey: "islandAutoExpand") as? Bool ?? true
        islandLiveActivities = defaults.object(forKey: "islandLiveActivities") as? Bool ?? true
        islandAlwaysOn = defaults.object(forKey: "islandAlwaysOn") as? Bool ?? false
        islandHaptics = defaults.object(forKey: "islandHaptics") as? Bool ?? true
    }

    package var perAppThresholdBytes: UInt64 { UInt64(perAppThresholdGB * 1_073_741_824) }
    package var swapThresholdBytes: UInt64 { UInt64(swapThresholdGB * 1_073_741_824) }
    package var lowDiskBytes: UInt64 { UInt64(lowDiskGB * 1_073_741_824) }
    package var growthBytesPerSecond: Double { growthMBPerMinute * 1_048_576 / 60 }
}
