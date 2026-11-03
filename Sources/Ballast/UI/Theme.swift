import AppKit
import CoreText
import SwiftUI

enum Theme {
    static let panelWidth: CGFloat = 404
    static let gutter: CGFloat = 16

    // MARK: Type

    private static let weightAxis = 0x77676874
    private static let family = "AspektaVariable-Regular"
    private static let hasAspekta = NSFont(name: family, size: 12) != nil

    /// Aspekta is a variable font, so weight comes from the wght axis rather than
    /// a synthesised bold. Falls back to the system face if the font is missing.
    static func font(_ size: CGFloat, _ weight: CGFloat, tabular: Bool = false) -> Font {
        guard hasAspekta else {
            return .system(size: size, weight: systemWeight(weight))
        }
        var attributes: [CFString: Any] = [
            kCTFontNameAttribute: family,
            kCTFontVariationAttribute: [weightAxis: weight],
        ]
        if tabular {
            attributes[kCTFontFeatureSettingsAttribute] = [[
                kCTFontOpenTypeFeatureTag: "tnum",
                kCTFontOpenTypeFeatureValue: 1,
            ]]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }

    private static func systemWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }

    static let display = font(32, 600, tabular: true)
    static let sectionTitle = font(11, 580)
    static let rowTitle = font(12.5, 520)
    static let body = font(11.5, 400)
    static let number = font(12, 520, tabular: true)
    static let caption = font(10.5, 480, tabular: true)

    /// Registers the copy bundled with the app so it does not depend on the
    /// font staying installed in the user's Fonts folder.
    static func registerBundledFont() {
        guard let url = Bundle.main.url(forResource: "AspektaVF", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    // MARK: Colour

    /// Data colours stay fixed so the legend means the same thing in either theme.
    static let appMemory = Color(red: 0.357, green: 0.424, blue: 0.839)
    static let wired = Color(red: 0.541, green: 0.565, blue: 0.608)
    static let compressed = Color(red: 0.831, green: 0.525, blue: 0.247)
    static let cached = Color(red: 0.420, green: 0.608, blue: 0.561)

    static let warning = Color(red: 0.776, green: 0.478, blue: 0.180)
    static let critical = Color(red: 0.741, green: 0.286, blue: 0.251)
    static let positive = Color(red: 0.325, green: 0.557, blue: 0.396)

    static let track = Color.primary.opacity(0.09)
    static let hairline = Color.primary.opacity(0.08)
    static let fill = Color.primary.opacity(0.045)

    static func severityColor(_ severity: Advice.Severity) -> Color {
        switch severity {
        case .info: .secondary
        case .warning: warning
        case .critical: critical
        }
    }

    static func riskColor(_ risk: Risk) -> Color {
        switch risk {
        case .safe: positive
        case .review: appMemory
        case .caution: warning
        case .reportOnly: .secondary
        }
    }
}

// MARK: Shared pieces

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.sectionTitle)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// One thin bar showing how memory is actually divided, instead of several
/// large numbers spread across the panel.
struct MeterBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        var color: Color
        var fraction: Double
    }

    var segments: [Segment]
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(proxy.size.width * segment.fraction, 0))
                }
                Rectangle().fill(Color.clear)
            }
        }
        .frame(height: height)
        .background(Theme.track)
        .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
    }
}

/// Two columns rather than one row: at the panel's width four labelled values
/// on one line forces "Compressed" to wrap mid-word.
struct Legend: View {
    var items: [(color: Color, label: String, value: String)]

    private let columns = [
        GridItem(.flexible(), spacing: 10, alignment: .leading),
        GridItem(.flexible(), spacing: 10, alignment: .leading),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(spacing: 5) {
                    Circle().fill(item.color).frame(width: 6, height: 6)
                    Text(item.label).font(Theme.caption).foregroundStyle(.secondary)
                    Text(item.value).font(Theme.caption)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Compact switch matching the panel's scale. The system switch is built for a
/// settings window and sits oversized next to this type.
struct Switch: View {
    @Binding var isOn: Bool
    var enabled: Bool = true

    var body: some View {
        Button { if enabled { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.appMemory : Theme.track)
                    .frame(width: 26, height: 15)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .frame(width: 11, height: 11)
                    .padding(.horizontal, 2)
            }
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// One label on the left, one control on the right, so switches and steppers
/// line up in the same column.
struct SettingRow<Control: View>: View {
    var label: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.body).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            control
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

/// Quiet text button. Deliberately not a filled pill: the panel only has one
/// primary action at a time.
struct QuietButton: View {
    var title: String
    var tint: Color = .secondary
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(hovering ? tint : tint.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? tint.opacity(0.13) : Theme.fill)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Two or three short options in one quiet track, for switching a view mode.
struct Segmented<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(Theme.font(10.5, selected ? 560 : 460))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                                .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 0.5, y: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(1.5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill))
    }
}

struct PrimaryButton: View {
    var title: String
    var tint: Color = Theme.appMemory
    var enabled: Bool = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(11.5, 560))
                .foregroundStyle(enabled ? Color.white : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(enabled ? tint.opacity(hovering ? 1 : 0.9) : Theme.track)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
    }
}

struct AppIcon: View {
    var bundlePath: String?
    var size: CGFloat = 16

    var body: some View {
        if let bundlePath, FileManager.default.fileExists(atPath: bundlePath) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(Theme.track)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "terminal")
                        .font(.system(size: size * 0.55, weight: .medium))
                        .foregroundStyle(.secondary)
                )
        }
    }
}


/// ImageRenderer does not draw the contents of a ScrollView, so the offscreen
/// layout previews ask the panes to lay their lists out in full instead.
private struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var staticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

/// Scrolls normally in the app, lays out in full when rendering a preview.
struct ListContainer<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        if staticRender {
            VStack(spacing: 0) { content }
        } else {
            ScrollView {
                VStack(spacing: 0) { content }
            }
            .frame(maxHeight: maxHeight)
            .scrollIndicators(.automatic)
        }
    }
}
