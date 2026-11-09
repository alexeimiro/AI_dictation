import MurmurCore
import SwiftUI

/// The style pill, Wispr Flow's: a white (light: ink) capsule with only the style's name. It dims
/// while a dictation runs, whose style is already fixed, and opens the style page.
struct StylePill: View {
    let model: KeyboardModel
    var height: CGFloat = 46

    var body: some View {
        let open = model.overlay == .style
        let locked = model.locksSessionOptions
        Button {
            open ? model.actions.hideOverlay() : model.actions.showOverlay(.style)
        } label: {
            Text(model.style.shortTitle)
                .font(.system(size: 17, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(locked ? KeyboardChrome.disabledGlyph : KeyboardChrome.primaryGlyph)
                .padding(.horizontal, 20)
                .frame(height: height)
                .background(locked ? KeyboardChrome.disabled : KeyboardChrome.primary, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.keyboardPress)
        .disabled(locked)
        .accessibilityLabel("Style: \(model.style.title)")
        .accessibilityHint("Shows the writing styles")
    }
}

/// The style page, in place of the pad or the keys: one row per style with its subtitle and a
/// check on the current one. Picking a style sets the Default style and closes the page.
struct StylePage: View {
    let model: KeyboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WRITING STYLE")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(KeyboardChrome.muted)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(StylePreset.allCases) { style in
                row(style)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ style: StylePreset) -> some View {
        let selected = style == model.style
        return Button {
            model.actions.setStyle(style)
            model.actions.hideOverlay()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(style.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(KeyboardChrome.muted)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(KeyboardChrome.primaryGlyph)
                        .frame(width: 26, height: 26)
                        .background(KeyboardChrome.primary, in: .circle)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                          fill: KeyboardChrome.card) }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.keyboardPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.title)
        .accessibilityValue(style.subtitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
