import SwiftUI

/// A Settings section: its grey heading and the rounded, outlined box of rows.
struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(Mac.Font.label).foregroundStyle(Mac.Palette.third).padding(.leading, 4)
            }
            VStack(spacing: 0) {
                Group { content }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Mac.Palette.line, lineWidth: 1))
        }
    }
}

/// A row: its name and what it does on the left, its control on the right; a line above all but
/// the first.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var first = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let detail {
                    Text(detail).font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 54)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Mac.Palette.line).frame(height: 1) }
        }
    }
}

/// Keys drawn as keycaps: "fn", "⌃", "⌘", "V".
struct Keycaps: View {
    let keys: [String]
    var prefix: String?

    var body: some View {
        HStack(spacing: 4) {
            if let prefix { Text(prefix).font(Mac.Font.small).foregroundStyle(Mac.Palette.second) }
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 7)
                    .frame(minWidth: 26, minHeight: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Mac.Palette.track, lineWidth: 1)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Mac.Palette.track).frame(height: 1).padding(.horizontal, 4)
                            }
                    )
            }
        }
    }
}

/// The small outlined button: "Change", "Sync now", "Test".
struct SmallOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Mac.Palette.ink.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule(style: .circular).strokeBorder(Mac.Palette.ink.opacity(isEnabled ? 1 : 0.3), lineWidth: 1.5))
            .background(Capsule(style: .circular).fill(configuration.isPressed ? Mac.Palette.fill : .clear))
            .contentShape(Capsule(style: .circular))
    }
}

/// The mock's pop-up button: a white, outlined box with the choice and a chevron, opening a menu.
struct PopupMenu<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 8) {
                Text(title).font(Mac.Font.small).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Mac.Palette.third)
            }
            .padding(.leading, 10).padding(.trailing, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Mac.Palette.canvas))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Mac.Palette.track, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// Ten bars for the microphone's level, lit from the left.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<10, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Float(index) / 10 < level ? Mac.Palette.ink : Mac.Palette.line)
                    .frame(width: 6, height: 14)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("Input level")
    }
}
