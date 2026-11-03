import Foundation

package nonisolated enum Fmt {
    package static func bytes(_ v: UInt64) -> String { bytes(Double(v)) }

    package static func bytes(_ v: Double) -> String {
        let gb = v / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = v / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", max(v / 1024, 0))
    }

    package static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond * 60) + "/min"
    }

    package static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", (fraction * 100).rounded())
    }

    package static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        if s < 90 { return "\(s)s" }
        let m = s / 60
        if m < 90 { return "\(m)m" }
        let h = m / 60
        if h < 48 { return "\(h)h" }
        return "\(h / 24)d"
    }

    package static func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
