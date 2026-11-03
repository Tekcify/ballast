import Foundation
import WinSDK

// Only one Ballast at a time: a second copy would add a second tray icon.
let instanceLock = CreateMutexW(nil, false, "Local\\BallastTray".wide)
if GetLastError() == DWORD(ERROR_ALREADY_EXISTS) { exit(0) }

let app = TrayApp()
guard app.start() else { exit(1) }

if ProcessInfo.processInfo.environment["BALLAST_SELFTEST"] != nil {
    let passed = app.selfTest()
    app.stop()
    exit(passed ? 0 : 1)
}

// The Win32 message loop. Each message goes to `trayWindowProc`, which records
// what happened; `drainEvents` then acts on it here on the main actor.
var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    TranslateMessage(&message)
    DispatchMessageW(&message)
    app.drainEvents()
}
app.stop()
withExtendedLifetime(instanceLock) {}
