import BallastCore
import Foundation
import WinSDK

/// A process pinned down by more than its pid. Windows reuses pids, so before
/// forcing anything Ballast checks the pid still runs the same exe it started
/// with at the same time.
package nonisolated struct ProcessIdentity: Sendable, Equatable {
    package var pid: pid_t
    package var path: String?
    package var startedAt: Date?

    package static func of(_ pid: pid_t) -> ProcessIdentity? {
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else {
            return nil
        }
        defer { CloseHandle(handle) }
        return of(handle, pid: pid)
    }

    /// The identity of the process behind an open handle.
    package static func of(_ handle: HANDLE, pid: pid_t) -> ProcessIdentity? {
        var exitCode: DWORD = 0
        guard GetExitCodeProcess(handle, &exitCode), exitCode == WindowsQuitter.stillActive else { return nil }

        var created = FILETIME()
        var exited = FILETIME()
        var kernel = FILETIME()
        var user = FILETIME()
        let started = GetProcessTimes(handle, &created, &exited, &kernel, &user)
            ? Probes.date(fromFileTime: Probes.ticks(created))
            : nil
        return ProcessIdentity(pid: pid, path: Probes.imagePath(handle), startedAt: started)
    }

    /// Still running, and still the same process.
    package var isRunning: Bool { ProcessIdentity.of(pid) == self }
}

package nonisolated struct QuitOutcome: Sendable {
    package var name: String
    package var forced: Int
    package var stillOpen: Int

    package var summary: String {
        if stillOpen > 0 {
            return "\(name) is still open, probably asking you to save something. Check on it."
        }
        return forced > 0 ? "\(name) got force quit." : "\(name) has left the chat."
    }
}

/// Quitting the way Windows itself asks apps to close: post `WM_CLOSE` to the
/// app's windows so it can save, then, after a grace period, end only the
/// processes that are still running and show no window.
package nonisolated enum WindowsQuitter {
    /// `STILL_ACTIVE` is a C macro Swift cannot import.
    package static let stillActive: DWORD = 259

    private nonisolated final class Collector {
        let pids: Set<pid_t>
        var windows: [HWND] = []
        init(pids: Set<pid_t>) { self.pids = pids }
    }

    /// Visible top-level windows that belong to any of `pids`.
    private static func windows(of pids: Set<pid_t>) -> [HWND] {
        let collector = Collector(pids: pids)
        withExtendedLifetime(collector) {
            let context = LPARAM(Int(bitPattern: Unmanaged.passUnretained(collector).toOpaque()))
            EnumWindows({ hwnd, context in
                guard let hwnd, let raw = UnsafeRawPointer(bitPattern: Int(context)) else { return true }
                let collector = Unmanaged<Collector>.fromOpaque(raw).takeUnretainedValue()
                guard IsWindowVisible(hwnd), GetWindow(hwnd, UINT(GW_OWNER)) == nil else { return true }
                var pid: DWORD = 0
                GetWindowThreadProcessId(hwnd, &pid)
                if collector.pids.contains(pid_t(bitPattern: pid)) { collector.windows.append(hwnd) }
                return true
            }, context)
        }
        return collector.windows
    }

    /// Asks every window of the app to close. Returns how many were asked.
    @discardableResult
    package static func askToClose(_ pids: Set<pid_t>) -> Int {
        let targets = windows(of: pids)
        for window in targets { PostMessageW(window, UINT(WM_CLOSE), 0, 0) }
        return targets.count
    }

    /// Runs after the grace period. A process still showing a window is most
    /// likely asking to save, so it is left alone; windowless leftovers end.
    package static func finish(name: String, identities: [ProcessIdentity]) -> QuitOutcome {
        let survivors = identities.filter(\.isRunning)
        let open = Set(windows(of: Set(survivors.map(\.pid))).map { window -> pid_t in
            var pid: DWORD = 0
            GetWindowThreadProcessId(window, &pid)
            return pid_t(bitPattern: pid)
        })

        var forced = 0
        for identity in survivors where !open.contains(identity.pid) {
            if terminate(identity) { forced += 1 }
        }
        return QuitOutcome(name: name, forced: forced, stillOpen: open.count)
    }

    private static func terminate(_ identity: ProcessIdentity) -> Bool {
        let access = DWORD(PROCESS_TERMINATE) | DWORD(PROCESS_QUERY_LIMITED_INFORMATION)
        guard let handle = OpenProcess(access, false, DWORD(bitPattern: identity.pid)) else { return false }
        defer { CloseHandle(handle) }
        // Re-check through the handle we are about to use, so the pid cannot be
        // reused between the check and the terminate.
        guard ProcessIdentity.of(handle, pid: identity.pid) == identity else { return false }
        return TerminateProcess(handle, 1)
    }
}
