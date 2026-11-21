import MurmurBrand
import SwiftUI

// The mock's building blocks, shared by the window, Settings, onboarding and the sheets.

/// The black capsule: the main action.
struct InkButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Mac.Font.label)
            .foregroundStyle(Mac.Palette.canvas)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(Capsule(style: .circular).fill(Mac.Palette.ink.opacity(isEnabled ? 1 : 0.35)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule(style: .circular))
    }
}

/// The outlined capsule: the other action.
struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Mac.Font.label)
            .foregroundStyle(Mac.Palette.ink.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Capsule(style: .circular).strokeBorder(Mac.Palette.ink.opacity(isEnabled ? 1 : 0.3),
                                                             lineWidth: 1.5))
            .background(Capsule(style: .circular).fill(configuration.isPressed ? Mac.Palette.fill : .clear))
            .contentShape(Capsule(style: .circular))
    }
}

/// A 28–30 pt borderless icon button (copy, more, edit, delete, dismiss).
struct IconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 28
    var iconSize: CGFloat = 15
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Mac.Palette.ink)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Mac.Palette.line : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The grey search box at the top of a page.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var width: CGFloat = 240

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Mac.Font.small)
                .foregroundStyle(Mac.Palette.ink)
        }
        .foregroundStyle(Mac.Palette.third)
        .padding(.horizontal, 10)
        .frame(width: width, height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Mac.Palette.fill))
    }
}

/// A small outlined pill: the plan badge, "Copied, not inserted".
struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Mac.Font.badge)
            .foregroundStyle(Mac.Palette.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .overlay(Capsule(style: .circular).strokeBorder(Mac.Palette.ink, lineWidth: 1.5))
    }
}

/// A page's title and the line under it.
struct PageHeader: View {
    let title: String
    var lede: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Mac.Font.pageTitle).tracking(-0.5).foregroundStyle(Mac.Palette.ink)
            if let lede {
                Text(lede).font(Mac.Font.lede).foregroundStyle(Mac.Palette.second).lineSpacing(2)
            }
        }
    }
}

/// The grey intro card at the top of a page, with ✕ to put it away for good.
struct IntroCard<Leading: View, Trailing: View>: View {
    let title: String
    let text: String
    let dismiss: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 20) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Mac.Font.cardTitle)
                Text(text).font(Mac.Font.lede).foregroundStyle(Mac.Palette.second).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .foregroundStyle(Mac.Palette.ink)
        .padding(.leading, 20)
        .padding(.vertical, 16)
        .padding(.trailing, 52)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Mac.Palette.fill))
        .overlay(alignment: .topTrailing) {
            IconButton(symbol: "xmark", label: "Dismiss", iconSize: 13, action: dismiss).padding(10)
        }
    }
}

extension IntroCard where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, text: String, dismiss: @escaping () -> Void) {
        self.init(title: title, text: text, dismiss: dismiss, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A section's small grey heading ("Today", "Your words (5)").
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text).font(Mac.Font.label).foregroundStyle(Mac.Palette.third)
    }
}

/// "Synced with your iPhone".
struct SyncedNote: View {
    var body: some View {
        Label("Synced with your iPhone", systemImage: "arrow.triangle.2.circlepath")
            .font(Mac.Font.caption)
            .foregroundStyle(Mac.Palette.third)
            .labelStyle(.titleAndIcon)
    }
}

/// Redmic's mark: the ring in `color` and the red dot.
struct MarkView: View {
    var size: CGFloat = 20
    var color: Color = Mac.Palette.ink

    var body: some View {
        BrandMark(ring: color).frame(width: size, height: size)
    }
}

/// The black switch from the mock (ink when on, light grey track when off).
struct InkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule(style: .circular)
                        .fill(configuration.isOn ? Mac.Palette.ink : Mac.Palette.track)
                        .frame(width: 38, height: 22)
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        .padding(2)
                }
                .animation(.snappy(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A labelled text field in a dialog: the focused one has an ink border.
struct DialogField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Mac.Font.label)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Mac.Font.body)
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(focused ? Mac.Palette.ink : Mac.Palette.track, lineWidth: focused ? 1.5 : 1))
        }
    }
}

/// The dialog chrome: title, content, and the buttons on the right.
struct DialogChrome<Content: View, Buttons: View>: View {
    let title: String
    var width: CGFloat = 460
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(Mac.Font.dialogTitle).tracking(-0.3)
            content
            HStack(spacing: 10) {
                Spacer()
                buttons
            }
            .padding(.top, 4)
        }
        .foregroundStyle(Mac.Palette.ink)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: width)
        .background(Mac.Palette.canvas)
    }
}

/// A row that shows its actions on hover, as the mock's lists do.
struct HoverRow<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Mac.Palette.fill : .clear))
            .onHover { hovering = $0 }
    }
}
