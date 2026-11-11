import SwiftUI

/// Small capsule label for a transcript's state ("Not cleaned", "Pending"): an ink outline, or
/// solid ink for a failure. Never red, which is kept for an open microphone.
public struct StatusBadge: View {
    public enum Tone: Sendable {
        case neutral, accent, danger, success
    }

    let text: String
    let tone: Tone

    public init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(verbatim: text)
            .font(.murmur(.caption, weight: .semibold))
            .foregroundStyle(tone == .danger ? Theme.onInk : Theme.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone == .danger ? Theme.ink : .clear, in: .roundCapsule)
            .overlay {
                Capsule(style: .circular).strokeBorder(Theme.ink, lineWidth: 1.5)
            }
            .lineLimit(1)
    }
}
