import Foundation

/// One responsible application and every helper process it spawned.
/// Browsers and editors account for their memory across dozens of processes,
/// so a per-process list is the wrong unit for deciding what to quit.
package struct AppGroup: Identifiable, Sendable {
    package var id: String
    package var name: String
    package var bundleIdentifier: String?
    package var bundlePath: String?
    /// Working directory shared by the group, when it is a project-scoped tool.
    package var projectPath: String?
    package var pids: [pid_t]
    package var memoryBytes: UInt64
    package var cpuPercent: Double
    package var isApproximate: Bool
    package var isSystemOwned: Bool
    package var isRunningApp: Bool
    package var isFrontmost: Bool
    package var isHidden: Bool
    package var startedAt: Date

    package var processCount: Int { pids.count }

    package init(
        id: String, name: String, bundleIdentifier: String?, bundlePath: String?,
        projectPath: String?, pids: [pid_t], memoryBytes: UInt64, cpuPercent: Double,
        isApproximate: Bool, isSystemOwned: Bool, isRunningApp: Bool, isFrontmost: Bool,
        isHidden: Bool, startedAt: Date
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.projectPath = projectPath
        self.pids = pids
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.isApproximate = isApproximate
        self.isSystemOwned = isSystemOwned
        self.isRunningApp = isRunningApp
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.startedAt = startedAt
    }
}

/// Which processes the advisor must leave alone or treat gently. Each
/// platform's app extends this with the code that builds groups.
package enum Grouping {
    /// Processes macOS depends on. Quitting any of these logs you out,
    /// kills the window server, or breaks indexing.
    package static let essential: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logd", "UserEventAgent",
        "distnoted", "cfprefsd", "opendirectoryd", "securityd", "syspolicyd", "trustd",
        "powerd", "hidd", "bluetoothd", "configd", "mDNSResponder", "notifyd", "diskarbitrationd",
        "coreaudiod", "coreservicesd", "launchservicesd", "runningboardd", "amfid", "watchdogd",
        "Dock", "Finder", "SystemUIServer", "ControlCenter", "NotificationCenter", "WindowManager",
        "Spotlight", "mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd",
        "backupd", "fseventsd", "revisiond", "kernelmanagerd", "nsurlsessiond", "cloudd",
        "bird", "fileproviderd", "secd", "tccd", "sharingd", "universalaccessd", "Ballast",
    ]

    /// Stopping these from outside loses live state, so they get a warning and a
    /// lower score rather than a plain "quit it".
    package static let holdsLiveState: Set<String> = [
        "com.apple.Virtualization.VirtualMachine", "qemu-system-aarch64", "qemu-system-x86_64",
        "VirtualBoxVM", "prl_vm_app", "UTM", "vmware-vmx", "com.docker.backend",
        "Docker Desktop", "colima", "lima", "podman",
    ]

    /// Processes whose large memory use is normal and self-correcting.
    package static let transient: Set<String> = [
        "mdworker", "mdworker_shared", "mds_stores", "backupd", "photoanalysisd",
        "photolibraryd", "XProtectBehaviorService", "swift-frontend", "clangd",
    ]

    package static func isEssential(_ group: AppGroup) -> Bool {
        if essential.contains(group.name) { return true }
        if group.bundleIdentifier?.hasPrefix("com.apple.") == true, group.isSystemOwned { return true }
        return false
    }
}
