import MurmurCore
import MurmurUI
import SwiftUI

/// Home's "Try it now": three things to dictate, each opening the app to do it in, as in Wispr
/// Flow's "How would you like to try Flow?".
struct TryItSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    struct Example: Identifiable {
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
        let url: String
        var id: String { title }
    }

    static let examples = [
        Example(title: "Jot down my to-dos", detail: "Say them one by one. With Improve my grammar they come out as a numbered list.",
                symbol: "checklist", tint: Palette.cream, url: "mobilenotes://"),
        Example(title: "Send a quick message", detail: "\(Brand.name) drops the um's and spells the names in your dictionary right.",
                symbol: "bubble.left.and.text.bubble.right", tint: Palette.lavender, url: "sms:"),
        Example(title: "Write an email", detail: "Say \u{201C}new paragraph\u{201D} or \u{201C}comma\u{201D} and \(Brand.name) types it out.",
                symbol: "envelope", tint: Palette.toggleGreenSoft, url: "mailto:"),
    ]

    var body: some View {
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.fraction(0.8), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    private var content: some View {
        VStack(spacing: 0) {
            SerifTitle("How would you like to try \(Brand.name)?", size: 32, color: Palette.ink)
                .padding(.horizontal, 30)
                .padding(.top, 34)
            Text("Pick one, then switch to the \(Brand.name) keyboard and tap the mic.")
                .font(.ui(16))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.top, 10)
            VStack(spacing: 14) {
                ForEach(Self.examples) { example in
                    Button {
                        dismiss()
                        if let url = URL(string: example.url) { openURL(url) }
                    } label: {
                        card(example)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
    }

    private func card(_ example: Example) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(example.title)
                    .font(.ui(18, .semibold))
                    .foregroundStyle(Palette.text)
                Text(example.detail)
                    .font(.ui(15))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: example.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Palette.ink)
                .frame(width: 64, height: 64)
                .background(example.tint, in: .circle)
                .accessibilityHidden(true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.paper, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Palette.cardBorder, lineWidth: 1.5) }
        .contentShape(.rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
