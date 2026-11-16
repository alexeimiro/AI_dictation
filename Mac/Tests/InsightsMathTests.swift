import Foundation
import MurmurCore
import Testing

@MainActor
struct InsightsMathTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// Wednesday 18 November 2026, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_003_200)

    private func dictation(daysAgo: Int, words: Int, seconds: Double, language: String = "en", id: UUID = UUID()) -> Transcript {
        Transcript(id: id, createdAt: now.addingTimeInterval(Double(-daysAgo) * 86_400), language: language,
                   rawText: "x", status: .cleaned, metrics: TranscriptMetrics(audioSeconds: seconds, words: words))
    }

    @Test func streakCountsBackFromToday() {
        let history = [0, 1, 2, 4, 5, 6, 7].map { dictation(daysAgo: $0, words: 10, seconds: 5) }
        let streak = InsightsMath.streak(history, now: now, calendar: calendar)
        #expect(streak.current == 3)
        #expect(streak.best == 4)
    }

    @Test func streakSurvivesUntilTodaysFirstDictation() {
        let history = [1, 2].map { dictation(daysAgo: $0, words: 10, seconds: 5) }
        #expect(InsightsMath.streak(history, now: now, calendar: calendar).current == 2)
    }

    @Test func emptyAndFailedDictationsDontCount() {
        let history = [dictation(daysAgo: 0, words: 0, seconds: 3)]
        #expect(InsightsMath.streak(history, now: now, calendar: calendar).current == 0)
        #expect(InsightsMath.summary(history, in: .all, now: now, calendar: calendar).words == 0)
    }

    @Test func summaryKeepsToTheWeek() {
        // Monday the 16th is this week's first day; Sunday the 15th is last week.
        let history = [dictation(daysAgo: 0, words: 120, seconds: 60), dictation(daysAgo: 2, words: 60, seconds: 30),
                       dictation(daysAgo: 3, words: 500, seconds: 200)]
        let week = InsightsMath.summary(history, in: .week, now: now, calendar: calendar)
        #expect(week.words == 180)
        #expect(week.wordsPerMinute == 120)
        #expect(InsightsMath.previousWeekWords(history, now: now, calendar: calendar) == 500)
    }

    @Test func timeSavedComparesWithTypingAtForty() {
        let summary = InsightsMath.Summary(words: 400, audioSeconds: 120, dictations: 1)
        #expect(summary.minutesSaved == 8)
        #expect(InsightsMath.formatMinutes(89) == "1 h 29 min")
        #expect(InsightsMath.formatMinutes(22) == "22 min")
    }

    @Test func appsKeepTheTopFourAndPutTheRestTogether() {
        let names = ["Slack", "Mail", "Messages", "Notes", "Safari", "Xcode"]
        var log: [UUID: DictationAppLog.Entry] = [:]
        var history: [Transcript] = []
        for (index, name) in names.enumerated() {
            let id = UUID()
            history.append(dictation(daysAgo: 0, words: 60 - index * 10, seconds: 20, id: id))
            log[id] = DictationAppLog.Entry(app: name, bundleID: nil, copied: false)
        }
        let rows = InsightsMath.apps(history, log: log, in: .all, now: now, calendar: calendar)
        #expect(rows.map(\.name) == ["Slack", "Mail", "Messages", "Notes", "Other apps"])
        #expect(abs(rows.reduce(0) { $0 + $1.share } - 1) < 0.0001)
    }

    @Test func heatmapHasFifteenWeeksAndNothingAfterToday() {
        let weeks = InsightsMath.heatmap([dictation(daysAgo: 0, words: 50, seconds: 20)], now: now, calendar: calendar)
        #expect(weeks.count == 15)
        #expect(weeks.last?[2] == 4)
        #expect(weeks.last?[3] == nil)
    }
}
