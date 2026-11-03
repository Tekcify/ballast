import Foundation

/// Last line of defence before anything is removed. Built from the same target
/// list the scanner uses, so a path that no target could have produced is refused
/// even if it reached the cleaner some other way.
package nonisolated struct DeletionGuard: Sendable {
    private let home: String
    private let exactRoots: Set<String>
    private let childBases: Set<String>
    private let searchSuffixes: [String]

    /// Top level directories that hold real work and must never be a delete root.
    private static let protectedTop: Set<String> = [
        "Documents", "Desktop", "Pictures", "Movies", "Music", "Public", "Applications",
        "Library", "Sites", "Dropbox", "iCloud Drive (Archive)",
        ".ssh", ".gnupg", ".aws", ".config", ".kube", ".docker",
        ".codex", ".claude", ".cursor", ".agents", ".openai",
    ]

    /// Directory names that are off limits wherever they appear, not just at the
    /// top of the home folder. These hold local assistant instructions, memory
    /// and credentials, and nothing inside them is a cache worth reclaiming.
    private static let forbiddenComponents: Set<String> = [
        ".git", ".ssh", ".gnupg", ".aws", ".kube",
        ".codex", ".claude", ".cursor", ".agents", ".openai",
    ]

    package init(home: String, targets: [CleanupTarget]) {
        self.home = home
        var exact: Set<String> = []
        var children: Set<String> = []
        var suffixes: [String] = []

        for target in targets where target.risk.isSelectable {
            switch target.shape {
            case .directory(let path):
                exact.insert(path)
            case .children(let base):
                children.insert(base)
            case .search(_, let names, _):
                for name in names {
                    if target.searchSubpaths.isEmpty {
                        suffixes.append("/" + name)
                    } else {
                        for sub in target.searchSubpaths { suffixes.append("/\(name)/\(sub)") }
                    }
                }
            }
        }
        exactRoots = exact
        childBases = children
        searchSuffixes = suffixes
    }

    /// Returns nil when the path may be deleted, otherwise the reason it may not.
    package func rejection(for rawPath: String) -> String? {
        guard rawPath.hasPrefix("/") else { return "not an absolute path" }
        guard !rawPath.contains("..") else { return "contains a parent reference" }

        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().path

        guard path.hasPrefix(root + "/") else { return "outside the home folder" }
        guard path != root else { return "the home folder itself" }

        let relative = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard relative.count >= 2 else { return "too close to the top of the home folder" }
        guard let first = relative.first else { return "unreadable path" }

        // .Trash is the one depth-one exception, and only its contents are removed.
        if first != ".Trash", Self.protectedTop.contains(first) {
            // ~/Library is protected as a root but its cache subtrees are targets.
            if !(first == "Library" && isKnownTarget(path)) {
                return "inside \(first), which Ballast never deletes from"
            }
        }
        if let forbidden = relative.first(where: { Self.forbiddenComponents.contains($0) }) {
            return "inside \(forbidden), which Ballast never deletes from"
        }
        guard isKnownTarget(path) else { return "not a path Ballast knows how to clean" }
        return nil
    }

    private func isKnownTarget(_ path: String) -> Bool {
        if exactRoots.contains(path) { return true }
        let parent = (path as NSString).deletingLastPathComponent
        if childBases.contains(parent) { return true }
        if searchSuffixes.contains(where: { path.hasSuffix($0) }) { return true }
        // Contents of a trashed or child-measured root.
        if exactRoots.contains(parent) { return true }
        return false
    }
}
