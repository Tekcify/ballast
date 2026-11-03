import Foundation

nonisolated enum Risk: Int, Sendable, Comparable, CaseIterable {
    /// Regenerated automatically. Deleted outright.
    case safe
    /// Regenerated, but at the cost of a download or a rebuild. Moved to Trash.
    case review
    /// Real content. Moved to Trash, and never selected for you.
    case caution
    /// Measured and shown, never offered for deletion.
    case reportOnly

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Rebuilds"
        case .caution: "Careful"
        case .reportOnly: "Kept"
        }
    }

    var isSelectable: Bool { self != .reportOnly }
    var defaultsOn: Bool { self == .safe }
    var usesTrash: Bool { self == .review || self == .caution }
}

nonisolated struct CleanupItem: Identifiable, Sendable {
    var id: String { path }
    var path: String
    var title: String
    var category: String
    var risk: Risk
    var reason: String
    var sizeBytes: UInt64
    /// Set when a live process is working inside this path, which makes it unsafe
    /// to remove no matter how reclaimable it looks.
    var heldBy: String?

    var isProtected: Bool { heldBy != nil }
    var isSelectable: Bool { risk.isSelectable && !isProtected && sizeBytes > 0 }
}

/// Declarative description of somewhere worth measuring.
nonisolated struct CleanupTarget: Sendable {
    enum Shape: Sendable {
        /// One directory, measured whole.
        case directory(String)
        /// Each immediate child measured separately, so one stale project can be
        /// cleared without touching the rest.
        case children(String)
        /// Directories matching `names` found beneath `roots`.
        case search(roots: [String], names: [String], maxDepth: Int)
    }

    var category: String
    var title: String
    var shape: Shape
    var risk: Risk
    var reason: String
    /// When true, a running process whose working directory sits inside the
    /// enclosing project marks the item protected.
    var guardAgainstLiveProjects = false
    /// For searches, measure these subdirectories instead of the match itself.
    var searchSubpaths: [String] = []
    /// For searches, skip matches whose project was touched more recently than this.
    var staleAfterDays: Int?

    /// Dependency folders are measured only on request. There are typically
    /// hundreds of them and walking every one dominates the scan, while they are
    /// never selected for you anyway.
    static func all(home: String, includeDependencies: Bool = false) -> [CleanupTarget] {
        let h = { (suffix: String) in home + "/" + suffix }

        var targets: [CleanupTarget] = [
            // MARK: Xcode
            CleanupTarget(
                category: "Xcode",
                title: "Derived data",
                shape: .children(h("Library/Developer/Xcode/DerivedData")),
                risk: .safe,
                reason: "Build intermediates. Xcode regenerates them on the next build."
            ),
            CleanupTarget(
                category: "Xcode",
                title: "Device support symbols",
                shape: .children(h("Library/Developer/Xcode/iOS DeviceSupport")),
                risk: .review,
                reason: "Re-downloaded from the device the next time you attach it."
            ),
            CleanupTarget(
                category: "Xcode",
                title: "Simulator caches",
                shape: .directory(h("Library/Developer/CoreSimulator/Caches")),
                risk: .safe,
                reason: "Simulator scratch data. Your installed simulators stay."
            ),
            CleanupTarget(
                category: "Xcode",
                title: "Xcode cache",
                shape: .directory(h("Library/Caches/com.apple.dt.Xcode")),
                risk: .safe,
                reason: "Index and module cache. Rebuilt when you open a project."
            ),
            CleanupTarget(
                category: "Xcode",
                title: "Build archives",
                shape: .directory(h("Library/Developer/Xcode/Archives")),
                risk: .reportOnly,
                reason: "Your shipped builds and their dSYMs. Needed to symbolise crash reports."
            ),

            // MARK: Package managers
            CleanupTarget(
                category: "Package managers",
                title: "npm cache",
                shape: .directory(h(".npm/_cacache")),
                risk: .safe,
                reason: "Tarball cache. npm refetches anything it needs."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "pnpm store",
                shape: .directory(h("Library/pnpm/store")),
                risk: .review,
                reason: "Shared package store. Existing installs relink from it, so expect a refetch."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Yarn cache",
                shape: .directory(h("Library/Caches/Yarn")),
                risk: .safe,
                reason: "Yarn refetches on the next install."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Bun cache",
                shape: .directory(h(".bun/install/cache")),
                risk: .safe,
                reason: "Bun refetches on the next install."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "SwiftPM cache",
                shape: .directory(h("Library/Caches/org.swift.swiftpm")),
                risk: .safe,
                reason: "Cloned dependencies. Re-resolved on the next build."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Homebrew downloads",
                shape: .directory(h("Library/Caches/Homebrew")),
                risk: .safe,
                reason: "Downloaded bottles. Installed formulae are unaffected."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "pip cache",
                shape: .directory(h("Library/Caches/pip")),
                risk: .safe,
                reason: "Wheel cache. pip refetches when needed."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "uv cache",
                shape: .directory(h(".cache/uv")),
                risk: .safe,
                reason: "uv refetches on the next sync."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Go build cache",
                shape: .directory(h("Library/Caches/go-build")),
                risk: .safe,
                reason: "Go rebuilds these objects on demand."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Go module downloads",
                shape: .directory(h("go/pkg/mod/cache/download")),
                risk: .review,
                reason: "Module zips. Re-downloaded on the next build."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Cargo registry cache",
                shape: .directory(h(".cargo/registry/cache")),
                risk: .review,
                reason: "Crate archives. Re-downloaded on the next build."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Gradle caches",
                shape: .directory(h(".gradle/caches")),
                risk: .review,
                reason: "Re-downloaded and rebuilt on the next Gradle run."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Maven repository",
                shape: .directory(h(".m2/repository")),
                risk: .review,
                reason: "Re-downloaded on the next Maven build."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Playwright browsers",
                shape: .directory(h("Library/Caches/ms-playwright")),
                risk: .review,
                reason: "Browser binaries. Reinstall with playwright install."
            ),
            CleanupTarget(
                category: "Package managers",
                title: "Puppeteer browsers",
                shape: .directory(h(".cache/puppeteer")),
                risk: .review,
                reason: "Browser binaries. Re-downloaded on the next install."
            ),

            // MARK: Project build output
            CleanupTarget(
                category: "Project builds",
                title: "Next.js cache",
                shape: .search(roots: [home], names: [".next"], maxDepth: 6),
                risk: .safe,
                reason: "Next.js rebuilds this. Covers both .next/cache and .next/dev/cache.",
                guardAgainstLiveProjects: true,
                searchSubpaths: ["cache", "dev/cache"]
            ),
            CleanupTarget(
                category: "Project builds",
                title: "Turbo cache",
                shape: .search(roots: [home], names: [".turbo"], maxDepth: 6),
                risk: .safe,
                reason: "Turborepo task cache. Rebuilt on the next run.",
                guardAgainstLiveProjects: true
            ),
            CleanupTarget(
                category: "Project builds",
                title: "Vite and SvelteKit caches",
                shape: .search(roots: [home], names: [".svelte-kit", ".vite", ".parcel-cache", ".nuxt"], maxDepth: 6),
                risk: .safe,
                reason: "Dev server caches. Rebuilt on the next start.",
                guardAgainstLiveProjects: true
            ),
            CleanupTarget(
                category: "Project builds",
                title: "Angular cache",
                shape: .search(roots: [home], names: [".angular"], maxDepth: 6),
                risk: .safe,
                reason: "Angular rebuilds this cache.",
                guardAgainstLiveProjects: true
            ),

            // MARK: Application caches
            CleanupTarget(
                category: "App caches",
                title: "User caches",
                shape: .children(h("Library/Caches")),
                risk: .safe,
                reason: "Per-app scratch data. Apps rebuild what they need."
            ),
            CleanupTarget(
                category: "App caches",
                title: "Logs",
                shape: .children(h("Library/Logs")),
                risk: .safe,
                reason: "Diagnostic logs. Only useful while chasing a specific bug."
            ),

            // MARK: Reversible but real
            CleanupTarget(
                category: "Reclaimable",
                title: "Trash",
                shape: .directory(h(".Trash")),
                risk: .caution,
                reason: "Emptying this is final. Check it first."
            ),
            CleanupTarget(
                category: "Reclaimable",
                title: "Device backups",
                shape: .children(h("Library/Application Support/MobileSync/Backup")),
                risk: .reportOnly,
                reason: "Local iPhone and iPad backups. Cannot be recovered from Apple."
            ),
            CleanupTarget(
                category: "Reclaimable",
                title: "Downloads",
                shape: .directory(h("Downloads")),
                risk: .reportOnly,
                reason: "Your own files. Shown so you know what the space is for."
            ),
        ]

        if includeDependencies {
            targets.append(CleanupTarget(
                category: "Reclaimable",
                title: "Dependencies in dormant projects",
                shape: .search(roots: [home], names: ["node_modules"], maxDepth: 4),
                risk: .caution,
                reason: "Reinstall with your package manager before that project builds again.",
                guardAgainstLiveProjects: true,
                staleAfterDays: 45
            ))
        }
        return targets
    }
}
