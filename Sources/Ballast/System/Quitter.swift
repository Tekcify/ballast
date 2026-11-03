import AppKit
import Foundation

struct QuitOutcome: Sendable {
    var name: String
    var requested: Int
    var stillRunning: Int
    var forced: Bool

    var summary: String {
        if stillRunning == 0 {
            return forced ? "\(name) was force quit." : "\(name) quit."
        }
        return "\(name) did not quit. \(stillRunning) process\(stillRunning == 1 ? "" : "es") still running."
    }
}

enum Quitter {
    /// Asks an application to quit the way the Dock does, so it gets the chance to
    /// save open work. Falls back to SIGTERM for plain command line processes, and
    /// only escalates after the grace period.
    static func quit(name: String, pids: [pid_t], grace: Duration = .seconds(6)) async -> QuitOutcome {
        let apps = NSWorkspace.shared.runningApplications.filter { pids.contains($0.processIdentifier) }
        var handled: Set<pid_t> = []

        for app in apps {
            app.terminate()
            handled.insert(app.processIdentifier)
        }
        for pid in pids where !handled.contains(pid) {
            kill(pid, SIGTERM)
        }

        try? await Task.sleep(for: grace)

        var forced = false
        var remaining = pids.filter { isAlive($0) }
        if !remaining.isEmpty {
            forced = true
            for app in NSWorkspace.shared.runningApplications where remaining.contains(app.processIdentifier) {
                app.forceTerminate()
            }
            for pid in remaining { kill(pid, SIGKILL) }
            try? await Task.sleep(for: .seconds(1))
            remaining = pids.filter { isAlive($0) }
        }

        return QuitOutcome(name: name, requested: pids.count, stillRunning: remaining.count, forced: forced)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
