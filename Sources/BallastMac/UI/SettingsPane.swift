import BallastCore
import SwiftUI

/// The switches you reach for often. Everything else is in the settings window.
struct SettingsPane: View {
    @Bindable var monitor: Monitor

    private var prefs: Preferences { monitor.prefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Quick settings")
                .padding(.bottom, 9)

            VStack(alignment: .leading, spacing: 9) {
                SettingRow(label: "Pop up when memory gets cooked") {
                    Switch(isOn: Binding(
                        get: { prefs.headsUpEnabled },
                        set: { prefs.headsUpEnabled = $0; monitor.applyHeadsUpSettings() }
                    ))
                }
                SettingRow(label: "Heads-up look") {
                    Segmented(
                        options: Preferences.HeadsUpStyle.allCases.map { ($0, $0.label) },
                        selection: Binding(
                            get: { prefs.headsUpStyle },
                            set: { prefs.headsUpStyle = $0; monitor.applyHeadsUpSettings() }
                        )
                    )
                }
                SettingRow(label: "Send banners") {
                    Switch(isOn: Binding(get: { prefs.notificationsEnabled },
                                         set: { prefs.notificationsEnabled = $0 }))
                }
                SettingRow(label: "Show the percentage in the menu bar") {
                    Switch(isOn: Binding(get: { prefs.showPercentInMenuBar },
                                         set: { prefs.showPercentInMenuBar = $0 }))
                }
                SettingRow(label: "Start at login") {
                    Switch(isOn: Binding(get: { LoginItem.status != .off },
                                         set: { LoginItem.setEnabled($0) }))
                }
                if LoginItem.status == .needsApproval {
                    Text("Waiting on your OK in System Settings, Login Items.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warning)
                }
            }

            Hairline().padding(.vertical, 12)

            HStack(spacing: 8) {
                PrimaryButton(title: "All settings…") {
                    SettingsWindowController.shared.show(monitor: monitor)
                }
                QuietButton(title: "Preview heads-up") { monitor.previewHeadsUp() }
                Spacer(minLength: 0)
                QuietButton(title: prefs.headsUpStyle == .island ? "Customize island" : "Customize look") {
                    SettingsWindowController.shared.show(monitor: monitor, section: .headsUp)
                }
            }
        }
    }
}
