import MurmurCore
import MurmurUI
import SwiftUI

/// The default style for every dictation, with what each one does to the same sentence. The
/// keyboard's style pill changes the same setting.
struct StyleView: View {
    @Environment(AppModel.self) private var model

    /// One spoken sentence and what each style writes from it (see the server's style rules: Word
    /// for word drops only sound fillers).
    static let spoken = "um me and him was thinking we could meet friday at 4"

    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("How Murmur writes")
                    .padding(.top, 6)
                    .accessibilityIdentifier(AccessibilityID.screen("style"))
                Text("Used for every dictation. You can switch from the keyboard any time.")
                    .font(.murmur(.subhead))
                    .foregroundStyle(Theme.second)
                    .padding(.top, 8)
                SectionLabel("You say")
                    .padding(.top, 22)
                Text(verbatim: "“\(Self.spoken)”")
                    .font(.transcript(.body))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 4)
                VStack(spacing: 12) {
                    ForEach(StylePreset.allCases) { style in
                        StyleCard(style: style, isSelected: settings.defaultStyle == style) {
                            settings.defaultStyle = style
                            model.syncStyle()
                        }
                    }
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Theme.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MenuToolbarItem()
        }
        .sensoryFeedback(.selection, trigger: settings.defaultStyle)
    }
}

/// A style with its example: what Murmur writes from `StyleView.spoken`.
private struct StyleCard: View {
    let style: StylePreset
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(style.title)
                        .font(.murmur(.headline))
                        .foregroundStyle(Theme.ink)
                    Text(style.subtitle)
                        .font(.murmur(.subhead))
                        .foregroundStyle(Theme.second)
                    Text("Murmur writes")
                        .font(.murmur(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.third)
                        .padding(.top, 10)
                    Text(example)
                        .font(.transcript(.callout))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SelectionMark(isOn: isSelected)
            }
            .padding(16)
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(isSelected ? Theme.ink : Theme.line, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var example: String {
        switch style {
        case .verbatim: "Me and him was thinking we could meet Friday at 4."
        case .grammar: "He and I were thinking we could meet Friday at 4."
        }
    }
}
