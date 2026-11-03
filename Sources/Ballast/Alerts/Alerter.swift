import AppKit
import Foundation
import UserNotifications

/// Posts alerts through UserNotifications, falling back to the scripting
/// bridge when a locally built, ad-hoc signed bundle is refused authorization.
@MainActor
final class Alerter: NSObject {
    static let category = "ballast.advice"
    static let quitAction = "ballast.quit"

    private var lastPosted: [String: Date] = [:]
    private var authorized = false
    private var useFallback = false
    private var onQuit: ((String, [pid_t]) -> Void)?

    /// Which delivery path is in use, for the diagnostic and the settings note.
    private(set) var deliveryPath = "not started"
    private(set) var lastError: String?

    func start(onQuit: @escaping (String, [pid_t]) -> Void) {
        self.onQuit = onQuit

        guard Bundle.main.bundleIdentifier != nil else {
            useFallback = true
            deliveryPath = "scripting bridge (no bundle identifier)"
            return
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [UNNotificationAction(
                    identifier: Self.quitAction,
                    title: "Quit it",
                    options: [.foreground]
                )],
                intentIdentifiers: [],
                options: []
            )
        ])

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.authorized = granted
                self?.useFallback = !granted
                self?.lastError = error?.localizedDescription
                self?.deliveryPath = granted
                    ? "UserNotifications"
                    : "scripting bridge (authorization refused)"
            }
        }
    }

    /// `subject` groups repeat alerts so the same problem is not announced twice
    /// inside the cooldown window.
    func post(
        title: String,
        body: String,
        subject: String,
        cooldown: TimeInterval,
        quit: (name: String, pids: [pid_t])? = nil
    ) {
        if let last = lastPosted[subject], Date().timeIntervalSince(last) < cooldown { return }
        lastPosted[subject] = Date()

        guard authorized, !useFallback else {
            postViaScripting(title: title, body: body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let quit {
            content.categoryIdentifier = Self.category
            content.userInfo = ["name": quit.name, "pids": quit.pids.map(Int.init)]
        }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.useFallback = true
                self?.deliveryPath = "scripting bridge (delivery failed)"
                self?.postViaScripting(title: title, body: body)
            }
        }
    }

    func resetCooldown(for subject: String) { lastPosted[subject] = nil }

    func describePath() -> String {
        lastError.map { "\(deliveryPath) · \($0)" } ?? deliveryPath
    }

    private func postViaScripting(title: String, body: String) {
        let escape = { (text: String) in
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        Task.detached { _ = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10) }
    }
}

extension Alerter: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.quitAction else { return }
        let info = response.notification.request.content.userInfo
        guard let name = info["name"] as? String, let raw = info["pids"] as? [Int] else { return }
        onQuit?(name, raw.map(pid_t.init))
    }
}
