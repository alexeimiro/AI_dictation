import Foundation

/// "Auto-delete transcripts" — how long history is kept on the device.
public enum TranscriptRetention: String, Codable, Sendable, CaseIterable, Identifiable {
    case never
    case week
    case month
    case quarter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .never: "Never"
        case .week: "1 week"
        case .month: "1 month"
        case .quarter: "3 months"
        }
    }

    /// Age after which a transcript is deleted; nil means keep forever.
    public var days: Int? {
        switch self {
        case .never: nil
        case .week: 7
        case .month: 30
        case .quarter: 90
        }
    }
}

public enum RetentionPolicy {
    /// Transcripts created before this instant are deleted; nil means nothing expires. Calendar
    /// arithmetic keeps the wall-clock time across DST changes ("a week ago at noon").
    public static func cutoff(now: Date = Date(), retention: TranscriptRetention,
                              calendar: Calendar = .current) -> Date? {
        guard let days = retention.days else { return nil }
        return calendar.date(byAdding: .day, value: -days, to: now)
            ?? now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// The boundary rule the store's delete predicate must agree with: strictly older than the
    /// cutoff expires, exactly at the cutoff is kept.
    public static func isExpired(createdAt: Date, cutoff: Date?) -> Bool {
        guard let cutoff else { return false }
        return createdAt < cutoff
    }
}
