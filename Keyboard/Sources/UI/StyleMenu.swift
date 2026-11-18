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

/// The style page, in place of the pad or the keys: Word for word across the top and the styles
/// the model writes two to a row below it, each with its icon and a short line. The current one's
/// icon is solid ink. All five fit under the toolbar without scrolling. Picking a style sets the
/// style for every dictation and closes the page.
struct StylePage: View {
    let model: KeyboardModel
    /// The page's width. Under Display Zoom a half-width card has no room for "Improve my grammar".
    @State private var width: CGFloat = 0

    var body: some View {
        let written = StylePreset.allCases.filter(\.usesModel)
        let narrow = width > 0 && width < 340
        VStack(alignment: .leading, spacing: 8) {
            Text("Writing style")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KeyboardChrome.muted)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(StylePreset.allCases.filter { !$0.usesModel }) { style in
                card(style, narrow: narrow)
            }
            ForEach(Array(stride(from: 0, to: written.count, by: 2)), id: \.self) { first in
                HStack(spacing: 8) {
                    ForEach(written[first..<min(first + 2, written.count)]) { style in
                        card(style, narrow: narrow)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func card(_ style: StylePreset, narrow: Bool) -> some View {
        let selected = style == model.style
        return Button {
            model.actions.setStyle(style)
            model.actions.hideOverlay()
        } label: {
            HStack(spacing: 10) {
                icon(style, selected: selected)
                VStack(alignment: .leading, spacing: 1) {
                    // 14 pt, scaling to 0.75: "Improve my grammar" fits beside the icon on a 375 pt
                    // iPhone. Display Zoom leaves too little room, so there it's "Grammar".
                    Text(narrow ? style.shortTitle : style.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KeyboardChrome.primary)
                        .minimumScaleFactor(0.75)
                    Text(style.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(KeyboardChrome.muted)
                        .minimumScaleFactor(0.75)
                }
                .lineLimit(1)
                // The text takes the rest of the row: one gap in the stack, and no spacer to add another.
                .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The style's icon in a rounded tile: solid ink on the current style, a muted outline on the
    /// others. Muted, unlike the Translate tile's ink outline, so the one chosen among five stands out.
    private func icon(_ style: StylePreset, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Image(systemName: style.symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(selected ? KeyboardChrome.primaryGlyph : KeyboardChrome.muted)
            .frame(width: 30, height: 30)
            .background(selected ? KeyboardChrome.primary : .clear, in: shape)
            .overlay {
                if !selected {
                    shape.strokeBorder(KeyboardChrome.muted, lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
    }
}
