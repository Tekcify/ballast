import Foundation
import Observation

@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    private func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? fallback
    }
    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    var refreshSeconds: Double {
        didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") }
    }
    var perAppThresholdGB: Double {
        didSet { defaults.set(perAppThresholdGB, forKey: "perAppThresholdGB") }
    }
    var swapThresholdGB: Double {
        didSet { defaults.set(swapThresholdGB, forKey: "swapThresholdGB") }
    }
    var growthMBPerMinute: Double {
        didSet { defaults.set(growthMBPerMinute, forKey: "growthMBPerMinute") }
    }
    var lowDiskGB: Double {
        didSet { defaults.set(lowDiskGB, forKey: "lowDiskGB") }
    }
    var idleMinutes: Double {
        didSet { defaults.set(idleMinutes, forKey: "idleMinutes") }
    }
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    var cooldownMinutes: Double {
        didSet { defaults.set(cooldownMinutes, forKey: "cooldownMinutes") }
    }
    var showPercentInMenuBar: Bool {
        didSet { defaults.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }
    var includeDependencyFolders: Bool {
        didSet { defaults.set(includeDependencyFolders, forKey: "includeDependencyFolders") }
    }
    var autoScanEnabled: Bool {
        didSet { defaults.set(autoScanEnabled, forKey: "autoScanEnabled") }
    }
    var autoScanHours: Double {
        didSet { defaults.set(autoScanHours, forKey: "autoScanHours") }
    }
    var headsUpEnabled: Bool {
        didSet { defaults.set(headsUpEnabled, forKey: "headsUpEnabled") }
    }
    var rankStorageBySize: Bool {
        didSet { defaults.set(rankStorageBySize, forKey: "rankStorageBySize") }
    }

    init() {
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
    }

    var perAppThresholdBytes: UInt64 { UInt64(perAppThresholdGB * 1_073_741_824) }
    var swapThresholdBytes: UInt64 { UInt64(swapThresholdGB * 1_073_741_824) }
    var lowDiskBytes: UInt64 { UInt64(lowDiskGB * 1_073_741_824) }
    var growthBytesPerSecond: Double { growthMBPerMinute * 1_048_576 / 60 }
}
