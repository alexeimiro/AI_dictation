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

/// The style page, in place of the pad or the keys: the four modes two to a row, each with its
/// symbol, name and a short line. The one in use is solid, like the pill, so it reads at a glance.
/// All four fit under the toolbar without scrolling. Picking a mode sets it for every dictation
/// from the next one and closes the page.
struct StylePage: View {
    let model: KeyboardModel

    var body: some View {
        let styles = StylePreset.allCases
        VStack(alignment: .leading, spacing: 8) {
            Text("Writing style")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KeyboardChrome.muted)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(stride(from: 0, to: styles.count, by: 2)), id: \.self) { first in
                HStack(spacing: 8) {
                    ForEach(styles[first..<min(first + 2, styles.count)]) { style in
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
        let ink = selected ? KeyboardChrome.primaryGlyph : KeyboardChrome.primary
        return Button {
            model.actions.setStyle(style)
            model.actions.hideOverlay()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: style.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(ink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ink)
                        .minimumScaleFactor(0.8)
                    Text(style.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? ink.opacity(0.7) : KeyboardChrome.muted)
                        .minimumScaleFactor(0.85)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(KeyboardChrome.primary)
                } else {
                    KeyboardSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                    fill: KeyboardChrome.card)
                }
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.keyboardPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.title)
        .accessibilityHint(style.subtitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
