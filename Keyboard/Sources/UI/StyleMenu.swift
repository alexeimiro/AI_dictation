import MurmurBrand
import MurmurCore
import SwiftUI

/// The style pill: a solid ink capsule with the style's name, as tall as the bar's disc. While a
/// dictation runs, whose style is already fixed, it is grey; while the style page is open it is
/// the reverse of rest, an ink outline, so open and closed differ.
struct StylePill: View {
    let model: KeyboardModel
    /// The touch target's height; the capsule is `BarMetrics.disc`.
    var height: CGFloat = 46

    var body: some View {
        let open = model.overlay == .style
        let locked = model.locksSessionOptions
        Button {
            open ? model.actions.hideOverlay() : model.actions.showOverlay(.style)
        } label: {
            ZStack(alignment: .trailing) {
                // The outlined pill this one replaced, unseen: it keeps the width the pill always
                // had, so the touch area is the same and nothing beside it in the bar moves. The
                // capsule is a little narrower and keeps the trailing edge.
                HStack(spacing: 3) {
                    Text(model.style.shortTitle)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .hidden()

                Text(model.style.shortTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(locked ? KeyboardChrome.muted
                                     : open ? KeyboardChrome.primary : KeyboardChrome.primaryGlyph)
                    .padding(.horizontal, 14)
                    .frame(height: BarMetrics.of(model).disc)
                    .background {
                        if locked {
                            KeyboardSurface(shape: Capsule(style: .circular), fill: KeyboardChrome.disabled)
                        } else if !open {
                            Capsule(style: .circular).fill(KeyboardChrome.primary)
                        }
                    }
                    .overlay {
                        if open, !locked {
                            Capsule(style: .circular).strokeBorder(KeyboardChrome.primary, lineWidth: 1.5)
                        }
                    }
            }
            .frame(height: height)
            .padding(.horizontal, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .disabled(locked)
        .accessibilityLabel("Style: \(model.style.title)")
        .accessibilityHint("Shows the writing styles")
    }
}

/// The style page, in place of the pad or the keys: Word for word across the top and the styles
/// the model writes two to a row below it, each with a short line and the mark on the current
/// one. All five fit under the toolbar without scrolling. Picking a style sets the style for
/// every dictation and closes the page.
struct StylePage: View {
    let model: KeyboardModel

    var body: some View {
        let written = StylePreset.allCases.filter(\.usesModel)
        VStack(alignment: .leading, spacing: 8) {
            Text("Writing style")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KeyboardChrome.muted)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(StylePreset.allCases.filter { !$0.usesModel }) { style in
                tile(style)
            }
            ForEach(Array(stride(from: 0, to: written.count, by: 2)), id: \.self) { first in
                HStack(spacing: 8) {
                    ForEach(written[first..<min(first + 2, written.count)]) { style in
                        tile(style)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func tile(_ style: StylePreset) -> some View {
        let selected = style == model.style
        return Button {
            model.actions.setStyle(style)
            model.actions.hideOverlay()
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    // 14 pt: "Improve my grammar" fits half the width of an iPhone 17 unscaled.
                    Text(style.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KeyboardChrome.primary)
                        .minimumScaleFactor(0.8)
                    Text(style.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(KeyboardChrome.muted)
                        .minimumScaleFactor(0.85)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                // The mark when it is chosen, an empty ring when it isn't.
                BrandMark(ring: selected ? KeyboardChrome.primary : KeyboardChrome.muted,
                          dot: selected ? KeyboardChrome.primary : .clear)
                    .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 50)
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
