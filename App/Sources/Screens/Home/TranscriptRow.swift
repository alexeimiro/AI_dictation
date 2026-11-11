import MurmurCore
import MurmurUI
import SwiftUI

/// One dictation in Home's history: when it was said, what was written, how long it took to say,
/// and a chip when something is left to do with it.
struct TranscriptRow: View {
    let transcript: Transcript
    let insertState: InsertState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the largest text sizes the time moves under the text, which gets the row's width.
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !stacked {
                // Every row's text starts at the same place: the column is as wide as the widest time.
                Text(Self.widestTime, style: .time)
                    .font(.murmur(.footnote))
                    .monospacedDigit()
                    .hidden()
                    .overlay(alignment: .leading) { time.fixedSize() }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: transcript.displayText.isEmpty ? (transcript.errorReason ?? "—") : transcript.displayText)
                    .font(.transcript())
                    .lineSpacing(2)
                    .foregroundStyle(transcript.displayText.isEmpty ? Theme.second : Theme.ink)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    if stacked { time }
                    Text(Self.meta(seconds: transcript.metrics.audioSeconds, words: transcript.metrics.words))
                        .font(.murmur(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(Theme.third)
                    if let badge {
                        StatusBadge(badge.text, tone: badge.tone)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var time: some View {
        Text(transcript.createdAt, style: .time)
            .font(.murmur(.footnote))
            .monospacedDigit()
            .foregroundStyle(Theme.third)
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

    /// 22:58, or 10:58 PM where the clock has twelve hours: as wide as a time gets.
    private static let widestTime = Calendar.current.date(
        bySettingHour: 22, minute: 58, second: 0, of: Date(timeIntervalSinceReferenceDate: 0)) ?? Date()

    /// "9 s · 13 words": how long the dictation took to say, and how much it came to.
    static func meta(seconds: Double, words: Int) -> String {
        "\(spoken(seconds)) · \(words == 1 ? "1 word" : "\(words) words")"
    }

    /// "9 s", "1 min 12 s".
    static func spoken(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total) s" : "\(total / 60) min \(total % 60) s"
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
