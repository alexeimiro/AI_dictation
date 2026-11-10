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
            VStack(spacing: 0) {
                SerifTitle("Your default style", accent: "default style", accentStyle: .purple, size: 32.5,
                           color: Palette.ink, tracking: -0.3)
                    .padding(.top, 20)
                Text("\(Brand.name) uses this style for all your dictations. You can change it anytime from the keyboard.")
                    .font(.ui(16))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                YouSayRow(text: Self.spoken)
                    .padding(.top, 24)
                VStack(spacing: 16) {
                    ForEach(StylePreset.allCases) { style in
                        StyleCard(style: style, isSelected: settings.defaultStyle == style) {
                            settings.defaultStyle = style
                            model.syncStyle()
                        }
                    }
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Palette.canvas)
        .navigationTitle("Style")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { MenuButton() }
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(style.title)
                            .font(.ui(20, .semibold, relativeTo: .title3))
                            .foregroundStyle(Palette.text)
                        Text(style.subtitle)
                            .font(.ui(15))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(isSelected ? Palette.proBadge : Palette.cardBorder)
                }
                HStack(alignment: .top, spacing: 12) {
                    Text("M")
                        .font(.ui(14, .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(isSelected ? Palette.proBadge : Palette.lockGray, in: .circle)
                    Text(example)
                        .font(.transcript(.callout))
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Palette.canvas, in: .rect(cornerRadius: 14))
            }
            .padding(18)
            .background(Palette.paper, in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? Palette.proBadge : .clear, lineWidth: 2)
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

/// The sentence both examples start from.
private struct YouSayRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(Palette.muted)
            Text("You say: “\(text)”")
                .font(.transcript(.footnote))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
