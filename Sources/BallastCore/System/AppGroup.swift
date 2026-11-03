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
    #if os(Windows)
    /// Processes Windows depends on. Quitting any of these signs you out, kills
    /// the desktop or stops security services. Names are lowercase exe names.
    package static let essential: Set<String> = [
        "system", "registry", "secure system", "memory compression", "smss", "csrss",
        "wininit", "winlogon", "services", "lsass", "lsaiso", "svchost", "fontdrvhost",
        "dwm", "explorer", "sihost", "taskhostw", "ctfmon", "runtimebroker", "searchhost",
        "searchindexer", "startmenuexperiencehost", "shellexperiencehost", "textinputhost",
        "applicationframehost", "lockapp", "securityhealthservice", "msmpeng", "nissrv",
        "smartscreen", "spoolsv", "audiodg", "conhost", "dllhost", "wudfhost", "ballast",
    ]

    /// Stopping these from outside loses live state, so they get a warning and a
    /// lower score rather than a plain "quit it".
    package static let holdsLiveState: Set<String> = [
        "vmmem", "vmmemwsl", "vmwp", "virtualboxvm", "vmware-vmx", "qemu-system-x86_64",
        "qemu-system-aarch64", "docker desktop", "com.docker.backend", "wslservice",
    ]

    /// Processes whose large memory use is normal and self-correcting.
    package static let transient: Set<String> = [
        "searchprotocolhost", "searchfilterhost", "tiworker", "trustedinstaller",
        "mousocoreworker", "compattelrunner", "wmiprvse", "swift-frontend", "clangd",
    ]
    #else
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
    #endif

    /// The names a group is known by. On macOS that is its display name. On
    /// Windows the display name comes from the exe's description, so the exe
    /// name is included too and everything is compared in lowercase.
    package static func identifiers(of group: AppGroup) -> [String] {
        #if os(Windows)
        var names = [group.name.lowercased()]
        if let path = group.bundlePath {
            let file = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
            let lower = file.lowercased()
            names.append(lower.hasSuffix(".exe") ? String(lower.dropLast(4)) : lower)
        }
        return names
        #else
        return [group.name]
        #endif
    }

    /// True when the group goes by any name in `names`.
    package static func matches(_ names: Set<String>, _ group: AppGroup) -> Bool {
        identifiers(of: group).contains(where: names.contains)
    }

    package static func isEssential(_ group: AppGroup) -> Bool {
        if matches(essential, group) { return true }
        if group.bundleIdentifier?.hasPrefix("com.apple.") == true, group.isSystemOwned { return true }
        #if os(Windows)
        // Everything under the Windows folder, and anything we cannot even read
        // the path of, belongs to the system.
        if group.isSystemOwned { return true }
        #endif
        return false
    }
}

/// The operating system's name, for copy shared between platforms.
package nonisolated enum Platform {
    #if os(Windows)
    package static let name = "Windows"
    /// The Windows app has no storage scan yet, so point at the built-in tools.
    package static let storageHint = "Storage Sense in Settings, System, Storage can clear temp files."
    #else
    package static let name = "macOS"
    package static let storageHint = "Run a storage scan to see what can go."
    #endif
}
