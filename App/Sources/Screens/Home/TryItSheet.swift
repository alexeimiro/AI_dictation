import MurmurCore
import MurmurUI
import SwiftUI

/// Home's "Try it": three things to dictate, each opening the app to do it in.
struct TryItSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    struct Example: Identifiable {
        let title: String
        let detail: String
        let symbol: String
        let url: String
        var id: String { title }
    }

    static let examples = [
        Example(title: "Jot down my to-dos", detail: "Say them one by one. With Improve my grammar they come out as a numbered list.",
                symbol: "checklist", url: "mobilenotes://"),
        Example(title: "Send a quick message", detail: "\(Brand.name) drops the um’s and spells the names in your dictionary right.",
                symbol: "bubble.left", url: "sms:"),
        Example(title: "Write an email", detail: "Say “new paragraph” or “comma” and \(Brand.name) types it out.",
                symbol: "envelope", url: "mailto:"),
    ]

    var body: some View {
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.canvas)
        .presentationBackground(Theme.canvas)
        .presentationDetents([.fraction(0.8), .large])
        .presentationDragIndicator(.visible)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Pick something to dictate")
                .padding(.top, 36)
            Text("Pick one, then switch to the \(Brand.name) keyboard and tap the mic.")
                .font(.murmur(.subhead))
                .foregroundStyle(Theme.second)
                .padding(.top, 8)
            VStack(spacing: 10) {
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
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    private func card(_ example: Example) -> some View {
        HStack(spacing: 14) {
            Image(systemName: example.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 1.5) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(example.title)
                    .font(.murmur(.headline))
                    .foregroundStyle(Theme.ink)
                Text(example.detail)
                    .font(.murmur(.subhead))
                    .foregroundStyle(Theme.second)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.third)
                .accessibilityHidden(true)
        }
        .softCard()
        .contentShape(.rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
