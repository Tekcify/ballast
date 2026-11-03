import Foundation

#if os(Windows)
/// Process identifiers are `pid_t` on Apple platforms. Windows has no such
/// type, so give the shared code the same name for the same 32-bit number.
package typealias pid_t = Int32
#endif

/// The readings each platform's probes produce. Only the data lives here; the
/// code that reads it from the operating system extends `Probes` in each app.
package nonisolated enum Probes {
    // MARK: Virtual memory

    package nonisolated struct VMSample: Sendable {
        package var pageSize: UInt64
        package var totalBytes: UInt64
        package var wiredBytes: UInt64
        package var compressedBytes: UInt64
        package var appBytes: UInt64
        package var cachedBytes: UInt64
        package var freeBytes: UInt64
        package var pageInsBytes: UInt64
        package var pageOutsBytes: UInt64

        package var usedBytes: UInt64 { wiredBytes + compressedBytes + appBytes }

        package init(
            pageSize: UInt64, totalBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
            appBytes: UInt64, cachedBytes: UInt64, freeBytes: UInt64,
            pageInsBytes: UInt64, pageOutsBytes: UInt64
        ) {
            self.pageSize = pageSize
            self.totalBytes = totalBytes
            self.wiredBytes = wiredBytes
            self.compressedBytes = compressedBytes
            self.appBytes = appBytes
            self.cachedBytes = cachedBytes
            self.freeBytes = freeBytes
            self.pageInsBytes = pageInsBytes
            self.pageOutsBytes = pageOutsBytes
        }
    }

    package nonisolated struct SwapSample: Sendable {
        package var total: UInt64
        package var used: UInt64
        package var encrypted: Bool

        package init(total: UInt64, used: UInt64, encrypted: Bool) {
            self.total = total
            self.used = used
            self.encrypted = encrypted
        }
    }

    /// Kernel memory pressure: 1 normal, 2 warning, 4 critical.
    package nonisolated enum Pressure: Int, Sendable, Comparable {
        case normal = 1, warning = 2, critical = 4
        package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        package var label: String {
            switch self {
            case .normal: "Chillin"
            case .warning: "Getting cooked"
            case .critical: "Fully cooked"
            }
        }
    }

    // MARK: Disk

    package nonisolated struct DiskSample: Sendable {
        package var total: UInt64
        package var available: UInt64
        package var used: UInt64 { total > available ? total - available : 0 }

        package init(total: UInt64, available: UInt64) {
            self.total = total
            self.available = available
        }
    }
}
