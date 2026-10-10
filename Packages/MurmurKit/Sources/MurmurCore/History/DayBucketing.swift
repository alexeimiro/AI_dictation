import Foundation

/// One section of the history list: a local calendar day and its transcripts, newest first.
public struct DayGroup: Identifiable, Sendable, Hashable {
    /// Start of the day in the calendar the group was built with.
    public let day: Date
    public let transcripts: [Transcript]

    public var id: Date { day }

    public init(day: Date, transcripts: [Transcript]) {
        self.day = day
        self.transcripts = transcripts
    }
}

public enum RelativeDay: Sendable, Hashable {
    case today
    case yesterday
    case other
}

/// Splits history into calendar days. Everything is relative to the given calendar (and its time
/// zone), so a 22:30 UTC dictation lands on the next day in Moscow and on the same day in
/// Los Angeles, and days around a DST change keep their 23- or 25-hour length.
public enum DayBucketing {
    public typealias DayGroup = MurmurCore.DayGroup
    public typealias RelativeDay = MurmurCore.RelativeDay

    /// Groups by local day, newest day first and newest transcript first within a day, whatever
    /// the input order.
    public static func group(_ transcripts: [Transcript], calendar: Calendar = .current) -> [DayGroup] {
        var buckets: [Date: [Transcript]] = [:]
        for transcript in transcripts {
            buckets[calendar.startOfDay(for: transcript.createdAt), default: []].append(transcript)
        }
        return buckets
            .sorted { $0.key > $1.key }
            .map { DayGroup(day: $0.key, transcripts: $0.value.sorted { $0.createdAt > $1.createdAt }) }
    }

    public static func relativeDay(for date: Date, now: Date = Date(),
                                   calendar: Calendar = .current) -> RelativeDay {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .other
    }
}
