import SwiftUI

struct StoragePane: View {
    @Bindable var monitor: Monitor
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline().padding(.vertical, 12)
            content
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Storage") {
                if monitor.isScanning {
                    QuietButton(title: "Stop", tint: .secondary) { monitor.cancelScan() }
                } else if !monitor.isCleaning {
                    QuietButton(title: monitor.storageItems.isEmpty ? "Scan" : "Rescan",
                                tint: Theme.appMemory) { monitor.scan() }
                }
            }

            if let disk = monitor.disk {
                HStack(alignment: .lastTextBaseline, spacing: 7) {
                    Text(Fmt.bytes(headlineBytes(disk)))
                        .font(Theme.display)
                    Text(headlineCaption(disk))
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                MeterBar(segments: [
                    .init(color: Theme.wired, fraction: usedFraction(disk) - reclaimFraction(disk)),
                    .init(color: Theme.appMemory, fraction: reclaimFraction(disk)),
                ])
            }

            HStack(spacing: 7) {
                Switch(
                    isOn: Binding(
                        get: { monitor.prefs.includeDependencyFolders },
                        set: { monitor.prefs.includeDependencyFolders = $0 }
                    ),
                    enabled: !monitor.isScanning && !monitor.isCleaning
                )

                Text("Also measure node_modules")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Text("slow")
                    .font(Theme.font(9.5, 520))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }

            if let progress = monitor.scanProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                    Text(progress.total > 0
                         ? "\(progress.stage) · \(progress.completed) of \(progress.total)"
                         : progress.stage)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let status = monitor.statusLine {
                Text(status).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The number you read first should be the one you are about to act on:
    /// what is ticked, or what a scan found, or what is free before a scan.
    private func headlineBytes(_ disk: Probes.DiskSample) -> UInt64 {
        if monitor.storageItems.isEmpty { return disk.available }
        return monitor.selection.isEmpty ? monitor.reclaimableBytes : monitor.selectedBytes
    }

    private func headlineCaption(_ disk: Probes.DiskSample) -> String {
        if monitor.storageItems.isEmpty { return "free of \(Fmt.bytes(disk.total))" }
        if monitor.selection.isEmpty {
            return "can be cleared · \(Fmt.bytes(disk.available)) free now"
        }
        return "selected · \(Fmt.bytes(monitor.reclaimableBytes)) found"
    }

    private func usedFraction(_ disk: Probes.DiskSample) -> Double {
        disk.total == 0 ? 0 : Double(disk.used) / Double(disk.total)
    }

    private func reclaimFraction(_ disk: Probes.DiskSample) -> Double {
        disk.total == 0
            ? 0
            : min(Double(monitor.reclaimableBytes) / Double(disk.total), usedFraction(disk))
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if monitor.storageItems.isEmpty && !monitor.isScanning {
            VStack(alignment: .leading, spacing: 5) {
                Text("Nothing measured yet")
                    .font(Theme.rowTitle)
                Text("A scan measures developer and app caches, build output and the Trash. Nothing is deleted until you choose it.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                selectionBar
                ListContainer(maxHeight: 280) {
                    ForEach(groupedCategories, id: \.name) { category in
                        CategoryBlock(category: category, monitor: monitor)
                    }
                }
                footer
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Text(monitor.selection.isEmpty
                 ? "Nothing selected"
                 : "\(monitor.selection.count) of \(monitor.storageItems.filter(\.isSelectable).count) selected")
                .font(Theme.caption)
                .foregroundStyle(monitor.selection.isEmpty ? .secondary : .primary)
            Spacer(minLength: 4)
            QuietButton(title: "Safe only", tint: Theme.positive) {
                monitor.clearSelection()
                monitor.selectAll(risk: .safe)
            }
            if !monitor.selection.isEmpty {
                QuietButton(title: "Clear") { monitor.clearSelection() }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !monitor.protectedItems.isEmpty {
                Text(monitor.protectedItems.count == 1
                     ? "1 path left out because a running process is working inside it."
                     : "\(monitor.protectedItems.count) paths left out because running processes are working inside them.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if confirming {
                HStack(spacing: 8) {
                    Text("Delete \(Fmt.bytes(monitor.selectedBytes))?")
                        .font(Theme.caption)
                    Spacer(minLength: 4)
                    QuietButton(title: "Cancel") { confirming = false }
                    PrimaryButton(title: "Yes, clean", tint: Theme.critical) {
                        confirming = false
                        Task { await monitor.clean() }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if let report = monitor.lastReport {
                        Text(report.summary)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    PrimaryButton(
                        title: monitor.isCleaning ? "Cleaning…" : "Clean selected",
                        enabled: !monitor.selection.isEmpty && !monitor.isCleaning
                    ) { confirming = true }
                }
            }
        }
    }

    // MARK: Grouping

    struct Category {
        var name: String
        var items: [CleanupItem]
        var total: UInt64
    }

    private var groupedCategories: [Category] {
        Dictionary(grouping: monitor.storageItems, by: \.category)
            .map { Category(name: $0.key, items: $0.value, total: $0.value.reduce(0) { $0 + $1.sizeBytes }) }
            .sorted { $0.total > $1.total }
    }
}

private struct CategoryBlock: View {
    var category: StoragePane.Category
    var monitor: Monitor
    @State private var expanded = true

    private var visible: [CleanupItem] {
        expanded ? category.items : Array(category.items.prefix(0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 8)
                    Text(category.name).font(Theme.font(11, 560)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(Fmt.bytes(category.total)).font(Theme.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            ForEach(visible) { item in
                ItemRow(item: item, monitor: monitor)
            }
        }
    }
}

private struct ItemRow: View {
    var item: CleanupItem
    var monitor: Monitor
    @State private var hovering = false

    private var isSelected: Bool { monitor.selection.contains(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button { monitor.toggle(item) } label: {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(isSelected ? Theme.appMemory : Theme.track)
                    .frame(width: 14, height: 14)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        } else if !item.isSelectable {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!item.isSelectable)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(item.title).font(Theme.rowTitle).lineLimit(1)
                    Text(item.risk.label)
                        .font(Theme.font(9.5, 560))
                        .foregroundStyle(Theme.riskColor(item.risk))
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.riskColor(item.risk).opacity(0.12))
                        )
                }
                Text(item.heldBy.map { "In use by \($0). Left alone." } ?? item.reason)
                    .font(Theme.caption)
                    .foregroundStyle(item.isProtected ? Theme.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hovering {
                    Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.font(9.5, 400))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.bytes(item.sizeBytes)).font(Theme.number)
                if hovering {
                    QuietButton(title: "Reveal") { monitor.revealInFinder(item.path) }
                }
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
}
