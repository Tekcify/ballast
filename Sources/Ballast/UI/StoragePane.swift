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
                } else if !monitor.isCleaning, !monitor.storageItems.isEmpty {
                    QuietButton(title: "Rescan", tint: Theme.appMemory) { monitor.scan() }
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
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                        Text(progress.total > 1
                             ? "\(progress.stage) · \(progress.completed) of \(progress.total)"
                             : progress.stage)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if progress.total > 1 {
                        MeterBar(segments: [
                            .init(color: Theme.appMemory,
                                  fraction: Double(progress.completed) / Double(progress.total)),
                        ], height: 3)
                    }
                }
            } else if let status = monitor.statusLine {
                Text(status)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            return "up for grabs · \(Fmt.bytes(disk.available)) free rn"
        }
        return "picked · \(Fmt.bytes(monitor.reclaimableBytes)) found"
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
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Haven't scanned yet")
                        .font(Theme.rowTitle)
                    Text("A scan checks dev caches, build junk, app caches and the Trash, then ranks them by size. Nothing gets deleted unless you pick it.")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PrimaryButton(title: "Scan now", enabled: !monitor.isCleaning) { monitor.scan() }
            }
            .padding(.bottom, 4)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                selectionBar
                if monitor.storageItems.isEmpty {
                    Text("Results drop in here as they're measured, biggest first.")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ListContainer(maxHeight: 280) {
                        if monitor.prefs.rankStorageBySize {
                            let largest = monitor.storageItems.first?.sizeBytes ?? 1
                            ForEach(monitor.storageItems) { item in
                                ItemRow(item: item, monitor: monitor,
                                        rank: Double(item.sizeBytes) / Double(max(largest, 1)))
                            }
                        } else {
                            ForEach(groupedCategories, id: \.name) { category in
                                CategoryBlock(category: category, monitor: monitor)
                            }
                        }
                    }
                }
                footer
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Segmented(
                options: [(true, "Biggest"), (false, "By type")],
                selection: Binding(
                    get: { monitor.prefs.rankStorageBySize },
                    set: { monitor.prefs.rankStorageBySize = $0 }
                )
            )
            Spacer(minLength: 4)
            QuietButton(title: "Smart pick", tint: Theme.positive) { monitor.smartPick() }
                .help("Safe caches plus rebuildable ones you haven't touched in 30 days. Skips anything in use.")
            if !monitor.selection.isEmpty {
                QuietButton(title: "Clear") { monitor.clearSelection() }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !monitor.protectedItems.isEmpty {
                Text(monitor.protectedItems.count == 1
                     ? "Left 1 spot alone since something's running in there."
                     : "Left \(monitor.protectedItems.count) spots alone since stuff is running in there.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if confirming {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Clear \(Fmt.bytes(monitor.selectedBytes)) for real?")
                            .font(Theme.font(11.5, 560))
                        Spacer(minLength: 4)
                        QuietButton(title: "Nah") { confirming = false }
                        PrimaryButton(title: "Yes, clear it", tint: Theme.critical) {
                            confirming = false
                            Task { await monitor.clean() }
                        }
                    }
                    if let note = confirmNote {
                        Text(note)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text(footerCaption)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    PrimaryButton(
                        title: monitor.isCleaning
                            ? "Clearing…"
                            : monitor.selection.isEmpty ? "Clear" : "Clear \(Fmt.bytes(monitor.selectedBytes))",
                        enabled: !monitor.selection.isEmpty && !monitor.isCleaning && !monitor.isScanning
                    ) { confirming = true }
                }
            }
        }
    }

    private var footerCaption: String {
        if monitor.selection.isEmpty {
            return monitor.lastReport?.summary ?? "Nothing picked"
        }
        let total = monitor.storageItems.filter(\.isSelectable).count
        return "\(monitor.selection.count) of \(total) picked"
    }

    /// Says where things end up, because only the safe tier frees space straight away.
    private var confirmNote: String? {
        let picked = monitor.storageItems.filter { monitor.selection.contains($0.id) }
        let trashed = picked.filter { $0.risk.usesTrash && $0.path != NSHomeDirectory() + "/.Trash" }
        guard !trashed.isEmpty else { return nil }
        let bytes = trashed.reduce(0) { $0 + $1.sizeBytes }
        return trashed.count == picked.count
            ? "These go to the Trash, so the space comes back once you empty it."
            : "Safe stuff gets deleted. \(Fmt.bytes(bytes)) goes to the Trash and frees up once you empty it."
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
    /// Share of the largest item, drawn as a small bar when ranking by size.
    var rank: Double?
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
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

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
                Text(item.heldBy.map { "\($0) is using this rn, so hands off." } ?? item.reason)
                    .font(Theme.caption)
                    .foregroundStyle(item.isProtected ? Theme.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let meta {
                    Text(meta)
                        .font(Theme.font(9.5, 440))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if hovering {
                    Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.font(9.5, 400))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.bytes(item.sizeBytes)).font(Theme.number)
                if let rank {
                    Capsule()
                        .fill(Theme.track)
                        .frame(width: 44, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Theme.riskColor(item.risk).opacity(item.isSelectable ? 0.75 : 0.35))
                                .frame(width: max(44 * rank, 3), height: 3)
                        }
                        .accessibilityHidden(true)
                }
                if hovering {
                    QuietButton(title: "Reveal") { monitor.revealInFinder(item.path) }
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .opacity(item.isSelectable ? 1 : 0.7)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Theme.fill : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onTapGesture { monitor.toggle(item) }
        .onHover { hovering = $0 }
    }

    /// Category when the list is ranked across all of them, and how long the
    /// folder has sat untouched when that is worth knowing.
    private var meta: String? {
        var parts: [String] = []
        if rank != nil { parts.append(item.category) }
        let now = Date()
        if item.isBusy(at: now) {
            parts.append("busy rn, skipped by smart pick")
        } else if let idle = item.idle(at: now), idle >= 14 * 86_400 {
            parts.append("untouched for \(Fmt.duration(idle))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
