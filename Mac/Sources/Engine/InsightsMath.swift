import Foundation
import MurmurCore

/// The numbers on Home and Insights, from this Mac's history. Pure, so tests can pin them.
enum InsightsMath {
    /// "Time saved compares your speaking speed with typing at 40 words a minute."
    static let typingWordsPerMinute = 40.0

    enum Range: String, CaseIterable, Identifiable {
        case week, month, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .week: "This week"
            case .month: "This month"
            case .all: "All time"
            }
        }
    }

    struct Summary: Equatable {
        var words = 0
        var audioSeconds = 0.0
        var dictations = 0

        /// Words per spoken minute; nil before there's a minute's worth of anything to go on.
        var wordsPerMinute: Int? {
            guard audioSeconds >= 10, words > 0 else { return nil }
            return Int((Double(words) / (audioSeconds / 60)).rounded())
        }

        /// Typing the same words at 40 a minute, minus the time spent saying them.
        var minutesSaved: Double {
            max(0, Double(words) / InsightsMath.typingWordsPerMinute - audioSeconds / 60)
        }
    }

    /// Dictations that wrote something (failed and empty ones don't count).
    static func counted(_ transcripts: [Transcript]) -> [Transcript] {
        transcripts.filter { $0.metrics.words > 0 }
    }

    static func summary(_ transcripts: [Transcript], in range: Range, now: Date = Date(),
                        calendar: Calendar = .current) -> Summary {
        let start = self.start(of: range, now: now, calendar: calendar)
        var summary = Summary()
        for transcript in counted(transcripts) where start.map({ transcript.createdAt >= $0 }) ?? true {
            summary.words += transcript.metrics.words
            summary.audioSeconds += transcript.metrics.audioSeconds
            summary.dictations += 1
        }
        return summary
    }

    /// The previous week's words, for "+18% on last week".
    static func previousWeekWords(_ transcripts: [Transcript], now: Date = Date(),
                                  calendar: Calendar = .current) -> Int {
        guard let thisWeek = start(of: .week, now: now, calendar: calendar),
              let lastWeek = calendar.date(byAdding: .day, value: -7, to: thisWeek) else { return 0 }
        return counted(transcripts)
            .filter { $0.createdAt >= lastWeek && $0.createdAt < thisWeek }
            .reduce(0) { $0 + $1.metrics.words }
    }

    static func start(of range: Range, now: Date, calendar: Calendar) -> Date? {
        switch range {
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: calendar.dateInterval(of: .month, for: now)?.start
        case .all: nil
        }
    }

    /// Days in a row with a dictation, ending today (or yesterday, so the streak isn't lost before
    /// the day's first dictation), and the longest run.
    static func streak(_ transcripts: [Transcript], now: Date = Date(),
                       calendar: Calendar = .current) -> (current: Int, best: Int) {
        let days = Set(counted(transcripts).map { calendar.startOfDay(for: $0.createdAt) })
        guard !days.isEmpty else { return (0, 0) }
        let today = calendar.startOfDay(for: now)
        var current = 0
        var cursor = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while days.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        var best = 0
        var run = 0
        var previous: Date?
        for day in days.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return (current, max(best, current))
    }

    /// The last `weeks` weeks as columns of seven days (oldest first), each 0…4 by how many words
    /// were dictated that day; days after today are nil.
    static func heatmap(_ transcripts: [Transcript], weeks: Int = 15, now: Date = Date(),
                        calendar: Calendar = .current) -> [[Int?]] {
        var wordsByDay: [Date: Int] = [:]
        for transcript in counted(transcripts) {
            wordsByDay[calendar.startOfDay(for: transcript.createdAt), default: 0] += transcript.metrics.words
        }
        let today = calendar.startOfDay(for: now)
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let first = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: weekStart) else { return [] }
        let busiest = max(1, wordsByDay.values.max() ?? 1)
        return (0..<weeks).map { week in
            (0..<7).map { day -> Int? in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day, to: first),
                      date <= today else { return nil }
                guard let words = wordsByDay[date], words > 0 else { return 0 }
                return min(4, 1 + Int(Double(words) / Double(busiest) * 3.99))
            }
        }
    }

    /// Share of words per app, the top four and then "Other apps".
    static func apps(_ transcripts: [Transcript], log: [UUID: DictationAppLog.Entry],
                     in range: Range, now: Date = Date(), calendar: Calendar = .current) -> [(name: String, share: Double)] {
        let start = self.start(of: range, now: now, calendar: calendar)
        var words: [String: Int] = [:]
        var total = 0
        for transcript in counted(transcripts) where start.map({ transcript.createdAt >= $0 }) ?? true {
            let name = log[transcript.id]?.app ?? "Other apps"
            words[name, default: 0] += transcript.metrics.words
            total += transcript.metrics.words
        }
        guard total > 0 else { return [] }
        let ranked = words.filter { $0.key != "Other apps" }.sorted { $0.value > $1.value }
        var rows = ranked.prefix(4).map { (name: $0.key, share: Double($0.value) / Double(total)) }
        let rest = total - ranked.prefix(4).reduce(0) { $0 + $1.value }
        if rest > 0 { rows.append((name: "Other apps", share: Double(rest) / Double(total))) }
        return rows
    }

    /// Share of words per language (the language each dictation was heard in).
    static func languages(_ transcripts: [Transcript], in range: Range, now: Date = Date(),
                          calendar: Calendar = .current) -> [(name: String, share: Double)] {
        let start = self.start(of: range, now: now, calendar: calendar)
        var words: [String: Int] = [:]
        var total = 0
        for transcript in counted(transcripts) where start.map({ transcript.createdAt >= $0 }) ?? true {
            let code = transcript.language.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
            guard let code else { continue }
            words[code, default: 0] += transcript.metrics.words
            total += transcript.metrics.words
        }
        guard total > 0 else { return [] }
        return words.sorted { $0.value > $1.value }.prefix(4).map { code, count in
            let name = Locale(identifier: code).localizedString(forLanguageCode: code)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? code
            // Each language in its own name, as the mock writes Русский.
            let own = Locale(identifier: code).localizedString(forLanguageCode: code) ?? name
            return (name: own.prefix(1).uppercased() + own.dropFirst(), share: Double(count) / Double(total))
        }
    }

    static func formatMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return "\(total) min" }
        return "\(total / 60) h \(total % 60) min"
    }

    static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}
