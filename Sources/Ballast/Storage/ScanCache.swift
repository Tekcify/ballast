import Foundation

/// The last scan's results, kept on disk so the Storage pane is not empty after
/// a restart while the next scheduled scan is still hours away.
nonisolated enum ScanCache {
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Ballast/last-scan.json")
    }

    /// Paths cleared outside Ballast since the scan are dropped on load.
    static func load(from url: URL = url) -> [CleanupItem] {
        guard let data = try? Data(contentsOf: url),
              let items = try? decoder.decode([CleanupItem].self, from: data)
        else { return [] }
        return items.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func save(_ items: [CleanupItem], to url: URL = url) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
