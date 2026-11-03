import BallastCore
import BallastWindowsKit
import Foundation
import WinSDK

// MARK: Window messages

/// What the window procedure saw. Win32 calls the procedure from C, outside
/// Swift's main actor, so it only records events; the message loop in
/// main.swift hands them to `TrayApp` on the main actor.
nonisolated enum TrayEvent: Sendable {
    case timer(UInt)
    case command(UInt16)
    case openMenu
    case taskbarCreated
}

/// Touched only on the main thread: by the window procedure while a message is
/// dispatched, and by `TrayApp.drainEvents()` between messages.
nonisolated(unsafe) var trayEvents: [TrayEvent] = []
/// Explorer broadcasts this after it restarts, when tray icons must be re-added.
nonisolated(unsafe) var taskbarCreatedMessage: UINT = 0

nonisolated let trayCallbackMessage = UINT(WM_APP) + 1
/// `NIN_BALLOONUSERCLICK` (`WM_USER + 5`): the user clicked our notification.
nonisolated let balloonClickedEvent = UINT(WM_USER) + 5

nonisolated func trayWindowProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch message {
    case UINT(WM_TIMER):
        trayEvents.append(.timer(UInt(wParam)))
        return 0
    case UINT(WM_COMMAND):
        trayEvents.append(.command(UInt16(truncatingIfNeeded: wParam)))
        return 0
    case trayCallbackMessage:
        let event = UINT(truncatingIfNeeded: lParam)
        if event == UINT(WM_LBUTTONUP) || event == UINT(WM_RBUTTONUP) || event == balloonClickedEvent {
            trayEvents.append(.openMenu)
        }
        return 0
    case UINT(WM_DESTROY):
        PostQuitMessage(0)
        return 0
    default:
        if taskbarCreatedMessage != 0, message == taskbarCreatedMessage {
            trayEvents.append(.taskbarCreated)
            return 0
        }
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

// MARK: Tray app

/// Ballast on Windows: an icon in the notification area whose tooltip and
/// menu show memory, the apps worth quitting, and a few switches. When memory
/// pressure builds it posts a notification, using the same `HeadsUpPolicy` as
/// the Mac island.
final class TrayApp {
    private enum Command: UInt16 {
        case openTaskManager = 1
        case snooze
        case startAtLogin
        case exit
    }

    private static let quitCommandBase: UInt16 = 100
    private static let refreshTimer: UInt = 1
    private static let quitTimer: UInt = 2
    private static let className = "BallastTrayWindow".wide

    private let monitor = WindowsMonitor()
    private var policy = HeadsUpPolicy()
    private var window: HWND?
    /// The level of the alert currently standing, or nil when none is.
    private var alertLevel: Probes.Pressure?
    private var quitTargets: [UInt16: (name: String, pids: [pid_t])] = [:]
    private var pendingQuit: (name: String, identities: [ProcessIdentity])?
    private var lastOutcome: String?

    // MARK: Lifecycle

    func start() -> Bool {
        let instance = GetModuleHandleW(nil)
        taskbarCreatedMessage = RegisterWindowMessageW("TaskbarCreated".wide)

        let created: HWND? = Self.className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = trayWindowProc
            windowClass.hInstance = instance
            windowClass.lpszClassName = name.baseAddress
            guard RegisterClassExW(&windowClass) != 0 else { return nil }
            // A hidden window: it only exists to receive tray and timer messages.
            return CreateWindowExW(
                0, name.baseAddress, "Ballast".wide, 0,
                0, 0, 0, 0, nil, nil, instance, nil
            )
        }
        guard let created else { return false }
        window = created

        monitor.refresh()
        addIcon()
        let interval = UINT(max(monitor.prefs.refreshSeconds, 1) * 1000)
        SetTimer(created, UINT_PTR(Self.refreshTimer), interval, nil)
        return true
    }

    func stop() {
        guard let window else { return }
        KillTimer(window, UINT_PTR(Self.refreshTimer))
        KillTimer(window, UINT_PTR(Self.quitTimer))
        var data = iconData()
        Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
    }

    /// Exercised by CI: one more refresh, then the menu is built and thrown
    /// away without being shown.
    func selfTest() -> Bool {
        tick()
        guard monitor.sample != nil, !monitor.groups.isEmpty, let menu = buildMenu() else { return false }
        DestroyMenu(menu)
        return true
    }

    func drainEvents() {
        while !trayEvents.isEmpty {
            switch trayEvents.removeFirst() {
            case .timer(let id) where id == Self.refreshTimer: tick()
            case .timer(let id) where id == Self.quitTimer: finishQuit()
            case .timer: break
            case .command(let id): run(id)
            case .openMenu: showMenu()
            case .taskbarCreated: addIcon()
            }
        }
    }

    // MARK: Refresh and alerts

    private func tick() {
        guard monitor.refresh(), let sample = monitor.sample else { return }
        updateIcon()

        guard monitor.prefs.headsUpEnabled else {
            alertLevel = nil
            return
        }
        switch policy.observe(sample.pressure, isVisible: alertLevel != nil, now: sample.at) {
        case .present:
            alert(sample.pressure)
        case .recover:
            alertLevel = nil
            notify(title: "Chillin again", body: "Memory pressure eased. You're good.", warning: false)
        case .none:
            // The policy holds one alert per episode; still say so if it gets worse.
            if let level = alertLevel, sample.pressure == .critical, level < .critical {
                alert(.critical)
            }
        }
    }

    private func alert(_ level: Probes.Pressure) {
        alertLevel = level
        let title = level == .critical ? "Memory is fully cooked" : "Memory is getting cooked"
        let body = monitor.quitSuggestions.first.map {
            "\($0.advice.headline). Click the Ballast tray icon to quit it."
        } ?? "Nothing obvious to quit. Task Manager has the full list."
        notify(title: title, body: body, warning: true)
    }

    // MARK: Tray icon

    private func iconData() -> NOTIFYICONDATAW {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = window
        data.uID = 1
        return data
    }

    /// Stock Windows icons stand in for a Ballast icon for now: the app icon
    /// when calm, the warning sign under pressure, the error sign when critical.
    private func currentIcon() -> HICON? {
        let id: Int = switch monitor.sample?.pressure ?? .normal {
        case .normal: 32512
        case .warning: 32515
        case .critical: 32513
        }
        return LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: id))
    }

    private var tooltip: String {
        guard let sample = monitor.sample else { return "Ballast" }
        return "Ballast · \(Fmt.percent(monitor.usedFraction)) used · \(sample.pressure.label)"
    }

    private func addIcon() {
        var data = iconData()
        data.uFlags = UINT(NIF_MESSAGE) | UINT(NIF_ICON) | UINT(NIF_TIP)
        data.uCallbackMessage = trayCallbackMessage
        data.hIcon = currentIcon()
        writeWide(tooltip, to: &data.szTip)
        Shell_NotifyIconW(DWORD(NIM_ADD), &data)
    }

    private func updateIcon() {
        var data = iconData()
        data.uFlags = UINT(NIF_ICON) | UINT(NIF_TIP)
        data.hIcon = currentIcon()
        writeWide(tooltip, to: &data.szTip)
        Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
    }

    private func notify(title: String, body: String, warning: Bool) {
        guard monitor.prefs.notificationsEnabled else { return }
        var data = iconData()
        data.uFlags = UINT(NIF_INFO)
        data.dwInfoFlags = warning ? DWORD(NIIF_WARNING) : DWORD(NIIF_INFO)
        writeWide(title, to: &data.szInfoTitle)
        writeWide(body, to: &data.szInfo)
        Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
    }

    // MARK: Menu

    private func buildMenu() -> HMENU? {
        guard let menu = CreatePopupMenu() else { return nil }
        quitTargets = [:]

        func item(_ text: String, id: UInt16 = 0, enabled: Bool = true, checked: Bool = false) {
            var flags = UINT(MF_STRING)
            if !enabled { flags |= UINT(MF_DISABLED) }
            if checked { flags |= UINT(MF_CHECKED) }
            AppendMenuW(menu, flags, UINT_PTR(id), text.wide)
        }
        func separator() { AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil) }

        if let sample = monitor.sample {
            let vm = sample.vm
            item("\(Fmt.bytes(vm.usedBytes)) of \(Fmt.bytes(vm.totalBytes)) used · \(sample.pressure.label)", enabled: false)
            if sample.swap.used > 0 {
                item("\(Fmt.bytes(sample.swap.used)) pushed to the page file", enabled: false)
            }
        } else {
            item("Couldn't read memory", enabled: false)
        }
        if let lastOutcome { item(lastOutcome, enabled: false) }
        separator()

        item("The move", enabled: false)
        let suggestions = monitor.quitSuggestions
        if suggestions.isEmpty {
            item("    Nothing worth quitting rn", enabled: false)
        }
        for (index, suggestion) in suggestions.enumerated() {
            let id = Self.quitCommandBase + UInt16(index)
            quitTargets[id] = (suggestion.name, suggestion.pids)
            let waiting = pendingQuit?.name == suggestion.name
            item(
                "    Quit \(suggestion.name) · \(Fmt.bytes(suggestion.advice.reclaimBytes))"
                    + (waiting ? " (closing…)" : ""),
                id: id,
                enabled: pendingQuit == nil
            )
        }
        separator()

        item("Biggest apps", enabled: false)
        for group in monitor.listedGroups.prefix(6) {
            item("    \(group.name) · \(Fmt.bytes(group.memoryBytes))", enabled: false)
        }
        separator()

        item("Open Task Manager", id: Command.openTaskManager.rawValue)
        if let until = policy.snoozedUntil, until > Date() {
            item("Alerts paused until \(Fmt.shortTime(until))", enabled: false)
        } else {
            item("Pause alerts for an hour", id: Command.snooze.rawValue)
        }
        item("Start Ballast at login", id: Command.startAtLogin.rawValue, checked: WindowsLoginItem.isEnabled)
        item("Quit Ballast", id: Command.exit.rawValue)
        return menu
    }

    private func showMenu() {
        guard let window, let menu = buildMenu() else { return }
        defer { DestroyMenu(menu) }
        var point = POINT()
        GetCursorPos(&point)
        // Without these two calls the menu does not close when you click away.
        SetForegroundWindow(window)
        TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON) | UINT(TPM_BOTTOMALIGN), point.x, point.y, 0, window, nil)
        PostMessageW(window, UINT(WM_NULL), 0, 0)
    }

    private func run(_ id: UInt16) {
        if let target = quitTargets[id] {
            beginQuit(name: target.name, pids: target.pids)
            return
        }
        switch Command(rawValue: id) {
        case .openTaskManager:
            ShellExecuteW(nil, "open".wide, "taskmgr.exe".wide, nil, nil, SW_SHOWNORMAL)
        case .snooze:
            policy.snooze(for: 3600, now: Date())
        case .startAtLogin:
            WindowsLoginItem.setEnabled(!WindowsLoginItem.isEnabled)
        case .exit:
            stop()
            if let window { DestroyWindow(window) }
        case nil:
            break
        }
    }

    // MARK: Quitting

    private func beginQuit(name: String, pids: [pid_t]) {
        guard pendingQuit == nil, let window else { return }
        let identities = pids.compactMap(ProcessIdentity.of)
        WindowsQuitter.askToClose(Set(pids))
        pendingQuit = (name, identities)
        lastOutcome = "Asking \(name) to dip…"
        SetTimer(window, UINT_PTR(Self.quitTimer), 6000, nil)
    }

    private func finishQuit() {
        if let window { KillTimer(window, UINT_PTR(Self.quitTimer)) }
        guard let quit = pendingQuit else { return }
        pendingQuit = nil
        let outcome = WindowsQuitter.finish(name: quit.name, identities: quit.identities)
        lastOutcome = outcome.summary
        notify(title: "Ballast", body: outcome.summary, warning: outcome.stillOpen > 0)
        tick()
    }
}
