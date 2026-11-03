import SwiftUI

struct MemoryPane: View {
    @Bindable var monitor: Monitor
    var openStorage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if !monitor.advice.isEmpty {
                Hairline().padding(.vertical, 12)
                adviceSection
            }
            Hairline().padding(.vertical, 12)
            appList
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Memory") {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(monitor.pressure.label)
                        .font(Theme.caption)
                        .foregroundStyle(monitor.pressure == .normal ? .secondary : statusColor)
                }
            }

            if let vm = monitor.vm {
                HStack(alignment: .lastTextBaseline, spacing: 7) {
                    Text(Fmt.bytes(vm.usedBytes))
                        .font(Theme.display)
                        .foregroundStyle(.primary)
                    Text("of \(Fmt.bytes(vm.totalBytes)) in use")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }

                MeterBar(segments: [
                    .init(color: Theme.appMemory, fraction: fraction(vm.appBytes, vm)),
                    .init(color: Theme.wired, fraction: fraction(vm.wiredBytes, vm)),
                    .init(color: Theme.compressed, fraction: fraction(vm.compressedBytes, vm)),
                    .init(color: Theme.cached.opacity(0.45), fraction: fraction(vm.cachedBytes, vm)),
                ])

                Legend(items: [
                    (Theme.appMemory, "Apps", Fmt.bytes(vm.appBytes)),
                    (Theme.wired, "Wired", Fmt.bytes(vm.wiredBytes)),
                    (Theme.compressed, "Compressed", Fmt.bytes(vm.compressedBytes)),
                    (Theme.cached.opacity(0.45), "Cached", Fmt.bytes(vm.cachedBytes)),
                ])

                if let swap = monitor.swap, swap.used > 0 {
                    Text("Swap \(Fmt.bytes(swap.used)) of \(Fmt.bytes(swap.total))")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Reading memory statistics…")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fraction(_ value: UInt64, _ vm: Probes.VMSample) -> Double {
        vm.totalBytes == 0 ? 0 : Double(value) / Double(vm.totalBytes)
    }

    private var statusColor: Color {
        switch monitor.pressure {
        case .normal: Theme.positive
        case .warning: Theme.warning
        case .critical: Theme.critical
        }
    }

    // MARK: Advice

    private var adviceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader("What to do")
            ForEach(monitor.advice) { item in
                AdviceRow(advice: item, monitor: monitor, openStorage: openStorage)
            }
        }
    }

    // MARK: Apps

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "By app") {
                Text("\(monitor.listedGroups.count) over 50 MB")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }

            if monitor.listedGroups.isEmpty {
                Text("No processes read yet.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            } else {
                ListContainer(maxHeight: 232) {
                    ForEach(monitor.listedGroups.prefix(40)) { group in
                        GroupRow(group: group, monitor: monitor)
                    }
                }
            }
        }
    }
}

private struct AdviceRow: View {
    var advice: Advice
    var monitor: Monitor
    var openStorage: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.severityColor(advice.severity))
                .frame(width: 2)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(advice.headline)
                    .font(Theme.rowTitle)
                Text(advice.detail)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            switch advice.action {
            case .quit(let name, let pids):
                QuietButton(title: "Quit", tint: Theme.critical) {
                    Task { await monitor.quit(name: name, pids: pids) }
                }
            case .openStorage:
                QuietButton(title: "Storage", tint: Theme.appMemory, action: openStorage)
            case .none:
                EmptyView()
            }
        }
    }
}

private struct GroupRow: View {
    var group: AppGroup
    var monitor: Monitor
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            AppIcon(bundlePath: group.bundlePath)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(Theme.rowTitle)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if group.cpuPercent >= 15 {
                Text(String(format: "%.0f%% CPU", group.cpuPercent))
                    .font(Theme.caption)
                    .foregroundStyle(group.cpuPercent >= 90 ? Theme.warning : .secondary)
            }

            Text(Fmt.bytes(group.memoryBytes))
                .font(Theme.number)
                .foregroundStyle(.primary)

            if hovering && !Grouping.isEssential(group) {
                QuietButton(title: "Quit", tint: Theme.critical) {
                    Task { await monitor.quit(name: group.name, pids: group.pids) }
                }
            } else {
                Text(Grouping.isEssential(group) ? "system" : "")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Theme.fill : .clear)
        )
        .onHover { hovering = $0 }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if group.processCount > 1 { parts.append("\(group.processCount) processes") }
        if let project = group.projectPath {
            parts.append((project as NSString).lastPathComponent)
        }
        if group.isApproximate { parts.append("resident size") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
