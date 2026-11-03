import SwiftUI

struct SettingsPane: View {
    @Bindable var monitor: Monitor

    private var prefs: Preferences { monitor.prefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Alerts")
                .padding(.bottom, 9)

            VStack(alignment: .leading, spacing: 9) {
                SettingRow(label: "Notify me") {
                    Switch(isOn: Binding(get: { prefs.notificationsEnabled },
                                         set: { prefs.notificationsEnabled = $0 }))
                }
                if prefs.notificationsEnabled {
                    Text("Delivering through \(monitor.alerter.describePath()).")
                        .font(Theme.font(9.5, 400))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingRow(label: "Pop up when memory gets cooked") {
                    Switch(isOn: Binding(get: { prefs.headsUpEnabled },
                                         set: { prefs.headsUpEnabled = $0 }))
                }

                ValueStepper(
                    label: "Warn when one app passes",
                    value: Binding(get: { prefs.perAppThresholdGB }, set: { prefs.perAppThresholdGB = $0 }),
                    range: 1...20, step: 1, format: { "\(Int($0)) GB" }
                )
                ValueStepper(
                    label: "Warn when swap passes",
                    value: Binding(get: { prefs.swapThresholdGB }, set: { prefs.swapThresholdGB = $0 }),
                    range: 1...32, step: 1, format: { "\(Int($0)) GB" }
                )
                ValueStepper(
                    label: "Call it a leak above",
                    value: Binding(get: { prefs.growthMBPerMinute }, set: { prefs.growthMBPerMinute = $0 }),
                    range: 20...1000, step: 20, format: { "\(Int($0)) MB/min" }
                )
                ValueStepper(
                    label: "Warn when free disk drops under",
                    value: Binding(get: { prefs.lowDiskGB }, set: { prefs.lowDiskGB = $0 }),
                    range: 5...200, step: 5, format: { "\(Int($0)) GB" }
                )
                ValueStepper(
                    label: "Treat an app as idle after",
                    value: Binding(get: { prefs.idleMinutes }, set: { prefs.idleMinutes = $0 }),
                    range: 5...180, step: 5, format: { "\(Int($0)) min" }
                )
                ValueStepper(
                    label: "Repeat the same alert at most every",
                    value: Binding(get: { prefs.cooldownMinutes }, set: { prefs.cooldownMinutes = $0 }),
                    range: 5...180, step: 5, format: { "\(Int($0)) min" }
                )
            }

            Hairline().padding(.vertical, 12)
            SectionHeader("Upkeep").padding(.bottom, 9)

            VStack(alignment: .leading, spacing: 9) {
                SettingRow(label: "Measure storage in the background") {
                    Switch(isOn: Binding(get: { prefs.autoScanEnabled },
                                         set: { prefs.autoScanEnabled = $0 }))
                }

                ValueStepper(
                    label: "Measure every",
                    value: Binding(get: { prefs.autoScanHours }, set: { prefs.autoScanHours = $0 }),
                    range: 6...168, step: 6, format: { "\(Int($0)) h" }
                )
                ValueStepper(
                    label: "Refresh memory every",
                    value: Binding(get: { prefs.refreshSeconds }, set: { prefs.refreshSeconds = $0 }),
                    range: 2...60, step: 1, format: { "\(Int($0)) s" }
                )
                SettingRow(label: "Show the percentage in the menu bar") {
                    Switch(isOn: Binding(get: { prefs.showPercentInMenuBar },
                                         set: { prefs.showPercentInMenuBar = $0 }))
                }

                SettingRow(label: "Start at login") {
                    Switch(isOn: Binding(get: { LoginItem.isEnabled },
                                         set: { LoginItem.setEnabled($0) }))
                }
            }

            Hairline().padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    QuietButton(title: "Activity Monitor") { monitor.openActivityMonitor() }
                    QuietButton(title: "Cleanup log") {
                        monitor.revealInFinder(Cleaner.logURL.path)
                    }
                    Spacer(minLength: 0)
                }
                Text(footnote)
                    .font(Theme.font(9.5, 400))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footnote: String {
        var lines = [
            "Per app figures are physical footprint, the same measure Activity Monitor shows. They are summed per app, so shared framework pages are counted once per process and the totals read higher than the system figure above.",
        ]
        if monitor.approximateCount > 0 {
            lines.append("\(monitor.approximateCount) system owned apps report resident size instead, because footprint needs elevated privileges.")
        }
        return lines.joined(separator: " ")
    }
}

/// Small labelled stepper. Built here rather than using a native control so the
/// label, value and buttons sit on one aligned row at the panel's width.
private struct ValueStepper: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.body).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(format(value)).font(Theme.number)
            HStack(spacing: 2) {
                stepButton("minus") { value = max(range.lowerBound, value - step) }
                stepButton("plus") { value = min(range.upperBound, value + step) }
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.fill)
                )
        }
        .buttonStyle(.plain)
    }
}
