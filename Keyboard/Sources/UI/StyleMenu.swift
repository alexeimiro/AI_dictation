import MurmurCore
import SwiftUI

/// The style pill from Anton's keyboard mock: an accent disc with sparkles, "Style" over the
/// current style, and a chevron that turns while the menu is open. `compact` fits the key layouts'
/// 50 pt toolbar; `showsDisc` false is for the narrowest phones.
struct StylePill: View {
    let model: KeyboardModel
    var compact = false
    var showsDisc = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = model.overlay == .style
        Button {
            open ? model.actions.hideOverlay() : model.actions.showOverlay(.style)
        } label: {
            HStack(spacing: compact ? 6 : 8) {
                if showsDisc {
                    Image(systemName: "sparkles")
                        .font(.system(size: compact ? 12 : 15, weight: .semibold))
                        .foregroundStyle(KeyboardChrome.accentGlyph)
                        .frame(width: compact ? 26 : 32, height: compact ? 26 : 32)
                        .background(KeyboardChrome.accent, in: .circle)
                }
                VStack(alignment: .leading, spacing: 1) {
                    if !compact {
                        Text("Style")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(KeyboardChrome.muted)
                    }
                    Text(model.style.shortTitle)
                        .font(.system(size: compact ? 14 : 15, weight: .semibold))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: compact ? 10 : 12, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: open)
            }
            .padding(.leading, showsDisc ? (compact ? 5 : 6) : 12)
            .padding(.trailing, compact ? 11 : 14)
            .frame(height: compact ? 36 : 44)
            .background { KeyboardSurface(shape: Capsule()) }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .disabled(model.locksSessionOptions)
        .accessibilityLabel("Style: \(model.style.title)")
        .accessibilityHint("Shows the writing styles")
    }
}

/// The style menu's card, under the toolbar: a header, then one row per style with its tile,
/// subtitle and a check on the current one. Picking a style sets the Default style and closes it.
struct StyleMenuCard: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("REWRITE STYLE")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.7)
                Spacer()
                Text("AI")
                    .font(.system(size: 12))
            }
            .foregroundStyle(KeyboardChrome.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rewrite style")
            .accessibilityAddTraits(.isHeader)

            ForEach(Array(StylePreset.allCases.enumerated()), id: \.element) { index, style in
                if index > 0 {
                    Rectangle()
                        .fill(KeyboardChrome.border)
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                row(style)
            }
        }
        .padding(8)
        .background(KeyboardChrome.panel, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(KeyboardChrome.border, lineWidth: 1)
        }
        .shadow(color: KeyboardChrome.shadow.opacity(0.18), radius: 20, y: 18)
        .shadow(color: KeyboardChrome.shadow.opacity(0.08), radius: 3, y: 2)
    }

    private func row(_ style: StylePreset) -> some View {
        let selected = style == model.style
        return Button {
            model.actions.setStyle(style)
            model.actions.hideOverlay()
        } label: {
            HStack(spacing: 12) {
                StyleGlyph(style: style)
                    .foregroundStyle(selected ? KeyboardChrome.accentGlyph : KeyboardChrome.tileGlyph)
                    .frame(width: 36, height: 36)
                    .background(selected ? KeyboardChrome.accent : KeyboardChrome.tile,
                                in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(style.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(KeyboardChrome.muted)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(KeyboardChrome.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .background(selected ? KeyboardChrome.selectedRow : .clear, in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.keyboardPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.title)
        .accessibilityValue(style.subtitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A style's tile glyph: the mock's T for Word for word, a checked text for grammar.
private struct StyleGlyph: View {
    let style: StylePreset

    var body: some View {
        switch style {
        case .verbatim:
            TypeGlyph()
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
        case .grammar:
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 15, weight: .semibold))
        }
    }
}

/// The mock's "exact text" glyph on a 24 pt grid: a T with a foot.
private struct TypeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        path.addLines([point(4, 7), point(4, 5), point(20, 5), point(20, 7)])
        path.move(to: point(12, 5))
        path.addLine(to: point(12, 19))
        path.move(to: point(9, 19))
        path.addLine(to: point(15, 19))
        return path
    }
}
