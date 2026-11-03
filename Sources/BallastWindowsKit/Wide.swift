import WinSDK

/// Win32 takes text as null-terminated UTF-16 ("wide") strings.
nonisolated extension String {
    /// This string as a null-terminated UTF-16 buffer, ready to pass as `LPCWSTR`.
    package var wide: [WCHAR] { Array(utf16) + [0] }
}

/// Reads a fixed-size `WCHAR` array that Win32 hands back as a Swift tuple,
/// such as `PROCESSENTRY32W.szExeFile`.
package nonisolated func readWide<T>(_ field: T) -> String {
    withUnsafeBytes(of: field) { raw in
        let units = raw.assumingMemoryBound(to: WCHAR.self)
        let end = units.firstIndex(of: 0) ?? units.count
        return String(decoding: units[..<end], as: UTF16.self)
    }
}

/// Writes `text` into a fixed-size `WCHAR` tuple, truncating to fit and always
/// leaving room for the terminating null.
package nonisolated func writeWide<T>(_ text: String, to field: inout T) {
    withUnsafeMutableBytes(of: &field) { raw in
        let units = raw.bindMemory(to: WCHAR.self)
        guard !units.isEmpty else { return }
        let copied = Array(text.utf16.prefix(units.count - 1))
        for (index, unit) in copied.enumerated() { units[index] = unit }
        units[copied.count] = 0
    }
}

/// `INVALID_HANDLE_VALUE` is a C macro Swift cannot import. A computed value,
/// since a raw pointer cannot be a concurrency-safe global constant.
package nonisolated var invalidHandleValue: HANDLE? { HANDLE(bitPattern: -1) }
