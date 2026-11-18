import MurmurCore
import MurmurUI
import SwiftUI

/// The default style for every dictation, with what each one does to the same sentence. The
/// keyboard's style pill changes the same setting.
struct StyleView: View {
    @Environment(AppModel.self) private var model

    /// One spoken sentence and what each style writes from it (see the server's style rules: Word
    /// for word drops only sound fillers).
    static let spoken = "um so me and him was thinking maybe we could like meet on friday at 4 if that works for you guys"

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
                SectionLabel("As you said it")
                    .padding(.top, 22)
                cards(StylePreset.allCases.filter { !$0.usesModel }, settings: settings)
                SectionLabel("Rewritten by AI")
                    .padding(.top, 22)
                cards(StylePreset.allCases.filter(\.usesModel), settings: settings)
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
        // The keyboard's pill may have changed the style while Murmur stayed in front (a note),
        // and the copy this screen reads is otherwise refreshed only when the app comes forward.
        .onAppear {
            settings.reloadFromKeyboard()
            model.syncStyle()
        }
    }

    private func cards(_ styles: [StylePreset], settings: SettingsModel) -> some View {
        VStack(spacing: 12) {
            ForEach(styles) { style in
                StyleCard(style: style, isSelected: settings.defaultStyle == style) {
                    settings.defaultStyle = style
                    model.syncStyle()
                }
            }
        }
        .padding(.top, 8)
    }
}

/// A style with its icon and its example: what Murmur writes from `StyleView.spoken`. The icon is
/// the one on the keyboard's style page, solid ink on the chosen style. Onboarding's style page
/// shows the same cards.
struct StyleCard: View {
    let style: StylePreset
    let isSelected: Bool
    let select: () -> Void

    /// The icon's tile grows with the title, up to 48 pt (the XXXL size, where onboarding stops).
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 36
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                // At the accessibility sizes the words need the width; the outline and the mark
                // still show the choice.
                if !dynamicTypeSize.isAccessibilitySize {
                    icon
                }
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

    /// The style's icon in a rounded tile: solid ink when chosen, an outline in the empty mark's
    /// grey when not.
    private var icon: some View {
        let side = min(tile, 48)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Image(systemName: style.symbolName)
            .font(.system(size: side * 0.44, weight: .medium))
            .foregroundStyle(isSelected ? Theme.onInk : Theme.second)
            .frame(width: side, height: side)
            .background(isSelected ? Theme.ink : .clear, in: shape)
            .overlay {
                if !isSelected {
                    shape.strokeBorder(Theme.graphic, lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
    }

    /// What the deployed model wrote from `StyleView.spoken` in each style (live check, 2026-11-13).
    private var example: String {
        switch style {
        case .verbatim: "So me and him was thinking maybe we could, like, meet on Friday at 4 if that works for you guys."
        case .grammar: "He and I were thinking maybe we could meet on Friday at 4 if that works for you guys."
        case .professional: "He and I would like to meet on Friday at 4, if that works for you."
        case .casual: "so me and him was thinking maybe we could meet on friday at 4 if that works for you guys"
        case .concise: "He and I could meet on Friday at 4, if that works for you guys."
        }
    }
}
