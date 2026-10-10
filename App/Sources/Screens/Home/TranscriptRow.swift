import MurmurCore
import MurmurUI
import SwiftUI

struct TranscriptRow: View {
    let transcript: Transcript
    let insertState: InsertState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: transcript.displayText.isEmpty ? (transcript.errorReason ?? "—") : transcript.displayText)
                .font(.transcript())
                .foregroundStyle(transcript.displayText.isEmpty ? Palette.textSecondary : Palette.text)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(transcript.createdAt, style: .time)
                Text("\(Self.duration(transcript.metrics.audioSeconds)) · \(transcript.metrics.words) words")
                Spacer()
                if let badge {
                    StatusBadge(badge.text, tone: badge.tone)
                }
            }
            .font(.ui(12))
            .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var badge: (text: String, tone: StatusBadge.Tone)? {
        switch transcript.status {
        case .failed, .empty: ("Failed", .danger)
        case .raw: ("Not cleaned", .accent)
        case .limitReached: ("Limit reached", .accent)
        case .processing: ("Processing", .neutral)
        case .cleaned:
            switch insertState {
            case .pending: ("Pending", .neutral)
            case .notInserted: ("Not inserted", .neutral)
            case .inserted, .none: nil
            }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
