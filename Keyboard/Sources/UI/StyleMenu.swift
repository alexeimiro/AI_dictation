import MurmurBrand
import MurmurCore
import SwiftUI

/// The style pill: an outlined capsule with the style's name and ⌄. It fades while a dictation
/// runs, whose style is already fixed, and opens the style page, where it turns solid.
struct StylePill: View {
    let model: KeyboardModel
    var height: CGFloat = 46

    var body: some View {
        let open = model.overlay == .style
        let locked = model.locksSessionOptions
        Button {
            open ? model.actions.hideOverlay() : model.actions.showOverlay(.style)
        } label: {
            OutlineChip(filled: open) {
                HStack(spacing: 3) {
                    Text(model.style.shortTitle)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .frame(height: height)
            .padding(.horizontal, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .disabled(locked)
        .opacity(locked ? 0.4 : 1)
        .accessibilityLabel("Style: \(model.style.title)")
        .accessibilityHint("Shows the writing styles")
    }
}

/// The style page, in place of the pad or the keys: one row per style with its subtitle and the
/// mark on the current one. Picking a style sets the Default style and closes the page.
struct StylePage: View {
    let model: KeyboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Writing style")
                .font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(KeyboardChrome.primary)
                    Text(style.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(KeyboardChrome.muted)
                }
                Spacer(minLength: 0)
                // The mark when it is chosen, an empty ring when it isn't.
                BrandMark(ring: selected ? KeyboardChrome.primary : KeyboardChrome.muted,
                          dot: selected ? KeyboardChrome.primary : .clear)
                    .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 14)
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
