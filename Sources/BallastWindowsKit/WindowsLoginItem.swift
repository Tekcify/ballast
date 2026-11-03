import Foundation
import WinSDK

/// "Start Ballast at login", through the per-user Run key in the registry.
package nonisolated enum WindowsLoginItem {
    private static let runKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    private static let valueName = "Ballast"

    /// `HKEY_CURRENT_USER` is a C macro Swift cannot import.
    private static var currentUser: HKEY? { HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001))) }

    package static var isEnabled: Bool {
        var size: DWORD = 0
        let status = RegGetValueW(
            currentUser, runKey.wide, valueName.wide, DWORD(RRF_RT_REG_SZ), nil, nil, &size
        )
        return status == 0
    }

    /// Returns false when the registry refused the change.
    @discardableResult
    package static func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            return RegDeleteKeyValueW(currentUser, runKey.wide, valueName.wide) == 0
        }
        guard let exe = executablePath() else { return false }
        let command = ("\"" + exe + "\"").wide
        let status = command.withUnsafeBytes { bytes in
            RegSetKeyValueW(
                currentUser, runKey.wide, valueName.wide, DWORD(REG_SZ),
                bytes.baseAddress, DWORD(bytes.count)
            )
        }
        return status == 0
    }

    package static func executablePath() -> String? {
        var buffer = [WCHAR](repeating: 0, count: 1024)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard length > 0, Int(length) < buffer.count else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF16.self)
    }
}
