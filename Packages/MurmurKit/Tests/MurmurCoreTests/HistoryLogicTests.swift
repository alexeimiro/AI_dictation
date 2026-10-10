import Foundation
import Testing
@testable import MurmurCore

private func calendar(_ timeZone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone)!
    return calendar
}

/// UTC+3 all year (no DST since 2014).
private let moscow = calendar("Europe/Moscow")
/// PDT (UTC-7) until 2026-11-01 02:00, then PST (UTC-8).
private let losAngeles = calendar("America/Los_Angeles")
private let utc = calendar("UTC")

/// An instant written in UTC, e.g. "2026-10-09T22:30:00Z".
private func instant(_ iso8601: String) -> Date {
    try! Date(iso8601, strategy: .iso8601)
}

/// A wall-clock time in `calendar`'s time zone.
private func wallClock(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int,
                       _ hour: Int, _ minute: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func transcript(at createdAt: Date, text: String = "Hello there",
                        status: TranscriptStatus = .cleaned, cleaned: String? = nil,
                        insertedAt: Date? = nil) -> Transcript {
    Transcript(createdAt: createdAt, rawText: text, cleanedText: cleaned, status: status,
               metrics: TranscriptMetrics(audioSeconds: 4, words: 2), insertedAt: insertedAt)
}

struct DayBucketingTests {
    @Test func splitsAtLocalMidnightInMoscow() {
        let lateEvening = wallClock(moscow, 2026, 10, 9, 23, 59)
        let justAfterMidnight = wallClock(moscow, 2026, 10, 10, 0, 1)
        let groups = DayBucketing.group([transcript(at: lateEvening), transcript(at: justAfterMidnight)],
                                        calendar: moscow)
        #expect(groups.count == 2)
        #expect(groups[0].day == wallClock(moscow, 2026, 10, 10, 0, 0))
        #expect(groups[0].day == instant("2026-10-09T21:00:00Z"))
        #expect(groups[0].id == groups[0].day)
        #expect(groups[0].transcripts.map(\.createdAt) == [justAfterMidnight])
        #expect(groups[1].day == wallClock(moscow, 2026, 10, 9, 0, 0))
        #expect(groups[1].transcripts.map(\.createdAt) == [lateEvening])
    }

    @Test func theSameTwoMinutesAreOneAfternoonInLosAngeles() {
        // 23:59 and 00:01 Moscow time are 13:59 and 14:01 on 9 October in Los Angeles.
        let moscowSplit = [wallClock(moscow, 2026, 10, 9, 23, 59), wallClock(moscow, 2026, 10, 10, 0, 1)]
        let groups = DayBucketing.group(moscowSplit.map { transcript(at: $0) }, calendar: losAngeles)
        #expect(groups.count == 1)
        #expect(groups[0].day == wallClock(losAngeles, 2026, 10, 9, 0, 0))
        #expect(groups[0].transcripts.count == 2)
    }

    @Test func utcAndLocalDaysDisagree() {
        // 22:30 UTC on 9 October is already 10 October in Moscow and still 9 October in Los Angeles.
        let item = transcript(at: instant("2026-10-09T22:30:00Z"))
        #expect(DayBucketing.group([item], calendar: moscow).first?.day == wallClock(moscow, 2026, 10, 10, 0, 0))
        #expect(DayBucketing.group([item], calendar: losAngeles).first?.day == wallClock(losAngeles, 2026, 10, 9, 0, 0))
        #expect(DayBucketing.group([item], calendar: utc).first?.day == instant("2026-10-09T00:00:00Z"))
    }

    @Test func losAngelesDSTEndIsASingleTwentyFiveHourDay() {
        // DST ends on Sunday 2026-11-01 at 02:00 PDT, so 01:30 happens twice.
        let firstHalfHour = instant("2026-11-01T07:30:00Z")    // 00:30 PDT, 1 November
        let firstOneThirty = instant("2026-11-01T08:30:00Z")   // 01:30 PDT
        let secondOneThirty = instant("2026-11-01T09:30:00Z")  // 01:30 PST
        let lateEvening = instant("2026-11-02T07:30:00Z")      // 23:30 PST, still 1 November
        let nextDay = instant("2026-11-02T08:30:00Z")          // 00:30 PST, 2 November
        let shuffled = [firstHalfHour, nextDay, secondOneThirty, firstOneThirty, lateEvening]
        let groups = DayBucketing.group(shuffled.map { transcript(at: $0) }, calendar: losAngeles)

        #expect(groups.map(\.day) == [instant("2026-11-02T08:00:00Z"), instant("2026-11-01T07:00:00Z")])
        #expect(groups[1].day.distance(to: groups[0].day) == 25 * 3600)
        #expect(groups[0].transcripts.map(\.createdAt) == [nextDay])
        #expect(groups[1].transcripts.map(\.createdAt)
                == [lateEvening, secondOneThirty, firstOneThirty, firstHalfHour])
    }

    @Test func ordersDaysAndTranscriptsNewestFirstWhateverTheInputOrder() {
        let days = (0..<4).map { wallClock(moscow, 2026, 10, 7 + $0, 9, 0) }
        var items: [Transcript] = []
        for day in days {
            for minute in [0, 30, 45] {
                items.append(transcript(at: day.addingTimeInterval(Double(minute) * 60)))
            }
        }
        let groups = DayBucketing.group(items.shuffled(), calendar: moscow)
        #expect(groups.map(\.day) == days.reversed().map { moscow.startOfDay(for: $0) })
        for group in groups {
            let times = group.transcripts.map(\.createdAt)
            #expect(times == times.sorted(by: >))
            #expect(times.count == 3)
        }
    }

    @Test func emptyHistoryHasNoGroups() {
        #expect(DayBucketing.group([], calendar: moscow).isEmpty)
    }
}

struct RelativeDayTests {
    @Test func todayYesterdayAndOther() {
        let now = wallClock(moscow, 2026, 10, 10, 12, 0)
        func relative(_ date: Date) -> RelativeDay {
            DayBucketing.relativeDay(for: date, now: now, calendar: moscow)
        }
        #expect(relative(wallClock(moscow, 2026, 10, 10, 0, 0)) == .today)
        #expect(relative(wallClock(moscow, 2026, 10, 10, 23, 59)) == .today)
        #expect(relative(wallClock(moscow, 2026, 10, 9, 23, 59)) == .yesterday)
        #expect(relative(wallClock(moscow, 2026, 10, 9, 0, 0)) == .yesterday)
        #expect(relative(wallClock(moscow, 2026, 10, 8, 23, 59)) == .other)
        #expect(relative(wallClock(moscow, 2026, 10, 11, 0, 0)) == .other)
    }

    @Test func dependsOnTheCalendarsTimeZone() {
        let now = instant("2026-10-10T12:00:00Z")
        let date = instant("2026-10-09T22:30:00Z")
        #expect(DayBucketing.relativeDay(for: date, now: now, calendar: moscow) == .today)
        #expect(DayBucketing.relativeDay(for: date, now: now, calendar: losAngeles) == .yesterday)
    }

    @Test func yesterdayAcrossTheDSTChange() {
        // Now is 00:30 PST on 2 November; the 25-hour 1 November is yesterday from its first minute.
        let now = instant("2026-11-02T08:30:00Z")
        func relative(_ date: Date) -> RelativeDay {
            DayBucketing.relativeDay(for: date, now: now, calendar: losAngeles)
        }
        #expect(relative(instant("2026-11-01T07:00:00Z")) == .yesterday)  // 00:00 PDT, 1 November
        #expect(relative(instant("2026-11-02T07:59:00Z")) == .yesterday)  // 23:59 PST, 1 November
        #expect(relative(instant("2026-11-01T06:59:00Z")) == .other)      // 23:59 PDT, 31 October
    }
}

struct RetentionPolicyTests {
    @Test func neverKeepsEverything() {
        #expect(RetentionPolicy.cutoff(now: Date(), retention: .never, calendar: utc) == nil)
        #expect(TranscriptRetention.never.days == nil)
        #expect(!RetentionPolicy.isExpired(createdAt: .distantPast, cutoff: nil))
    }

    @Test func cutoffIsExactlyTheRetentionPeriodBeforeNow() {
        let now = instant("2026-10-10T12:00:00Z")
        #expect(RetentionPolicy.cutoff(now: now, retention: .week, calendar: utc) == instant("2026-10-03T12:00:00Z"))
        #expect(RetentionPolicy.cutoff(now: now, retention: .month, calendar: utc) == instant("2026-09-10T12:00:00Z"))
        #expect(RetentionPolicy.cutoff(now: now, retention: .quarter, calendar: utc) == instant("2026-07-12T12:00:00Z"))
    }

    @Test func cutoffKeepsTheWallClockTimeAcrossDST() {
        // A week before noon PST on 5 November is noon PDT on 29 October: 169 hours, not 168.
        let now = instant("2026-11-05T20:00:00Z")
        #expect(RetentionPolicy.cutoff(now: now, retention: .week, calendar: losAngeles)
                == instant("2026-10-29T19:00:00Z"))
    }

    @Test func onlyStrictlyOlderThanTheCutoffExpires() {
        let cutoff = instant("2026-10-03T12:00:00Z")
        #expect(RetentionPolicy.isExpired(createdAt: cutoff.addingTimeInterval(-1), cutoff: cutoff))
        #expect(!RetentionPolicy.isExpired(createdAt: cutoff, cutoff: cutoff))
        #expect(!RetentionPolicy.isExpired(createdAt: cutoff.addingTimeInterval(1), cutoff: cutoff))
    }

    @Test func titlesAndDays() {
        #expect(TranscriptRetention.allCases.map(\.title) == ["Never", "1 week", "1 month", "3 months"])
        #expect(TranscriptRetention.allCases.map(\.days) == [nil, 7, 30, 90])
        #expect(TranscriptRetention.allCases.map(\.id) == ["never", "week", "month", "quarter"])
    }

    @Test func settingDefaultsToOneMonthAndPersists() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SharedSettings(defaults: defaults)
        #expect(settings.transcriptRetention == .month)
        settings.transcriptRetention = .never
        #expect(defaults.string(forKey: "transcriptRetention") == "never")
        #expect(SharedSettings(defaults: defaults).transcriptRetention == .never)
    }
}

struct MetricsSummaryTests {
    @Test func emptyHasACountOfZeroAndNoPercentiles() {
        #expect(MetricsSummary.summarize([]) == MetricsSummary(count: 0, median: nil, p95: nil))
    }

    @Test func aSingleValueIsEveryPercentile() {
        #expect(MetricsSummary.summarize([420]) == MetricsSummary(count: 1, median: 420, p95: 420))
    }

    @Test func oddCountUsesTheMiddleValue() {
        #expect(MetricsSummary.summarize([900, 100, 500]) == MetricsSummary(count: 3, median: 500, p95: 900))
    }

    @Test func evenCountUsesTheNearestRankNotAnAverage() {
        #expect(MetricsSummary.summarize([400, 100, 300, 200]) == MetricsSummary(count: 4, median: 200, p95: 400))
    }

    @Test func p95IsTheNinetyFifthRank() {
        #expect(MetricsSummary.summarize(Array(1...20).shuffled()) == MetricsSummary(count: 20, median: 10, p95: 19))
        #expect(MetricsSummary.summarize(Array(1...100).shuffled()) == MetricsSummary(count: 100, median: 50, p95: 95))
        #expect(MetricsSummary.summarize(Array(1...21).shuffled()) == MetricsSummary(count: 21, median: 11, p95: 20))
    }
}

struct InsertStateTests {
    private let createdAt = instant("2026-10-10T10:00:00Z")

    @Test func pendingForTwoMinutesThenNotInserted() {
        let item = transcript(at: createdAt)
        #expect(item.insertState(now: createdAt, claimed: false) == .pending)
        #expect(item.insertState(now: createdAt.addingTimeInterval(119.5), claimed: false) == .pending)
        #expect(item.insertState(now: createdAt.addingTimeInterval(120), claimed: false) == .notInserted)
        #expect(item.insertState(now: createdAt.addingTimeInterval(3600), claimed: false) == .notInserted)
        #expect(Transcript.insertWindow == 120)
    }

    @Test func aClaimOrInsertedAtMeansInsertedAtAnyAge() {
        let item = transcript(at: createdAt)
        #expect(item.insertState(now: createdAt.addingTimeInterval(5), claimed: true) == .inserted)
        #expect(item.insertState(now: createdAt.addingTimeInterval(3600), claimed: true) == .inserted)
        let inserted = transcript(at: createdAt, insertedAt: createdAt.addingTimeInterval(2))
        #expect(inserted.insertState(now: createdAt.addingTimeInterval(3600), claimed: false) == .inserted)
    }

    @Test func everyInsertableStatusIsOffered() {
        for status in [TranscriptStatus.cleaned, .raw, .limitReached] {
            let item = transcript(at: createdAt, status: status)
            #expect(item.insertState(now: createdAt.addingTimeInterval(1), claimed: false) == .pending)
        }
    }

    @Test func nonInsertableTranscriptsHaveNoInsertState() {
        for status in [TranscriptStatus.failed, .empty, .processing] {
            let item = transcript(at: createdAt, status: status)
            #expect(item.insertState(now: createdAt.addingTimeInterval(5), claimed: false) == .none)
            // The keyboard claims failed/empty results too, only to acknowledge the notice.
            #expect(item.insertState(now: createdAt.addingTimeInterval(5), claimed: true) == .none)
        }
        let blank = transcript(at: createdAt, text: "", status: .cleaned)
        #expect(blank.insertState(now: createdAt, claimed: false) == .none)
    }
}

struct TranscriptTests {
    @Test func statusMapsFromResultStatus() {
        #expect(TranscriptStatus(.cleaned) == .cleaned)
        #expect(TranscriptStatus(.raw) == .raw)
        #expect(TranscriptStatus(.empty) == .empty)
        #expect(TranscriptStatus(.limitReached) == .limitReached)
        #expect(TranscriptStatus(.failed) == .failed)
        #expect(TranscriptStatus(.cancelled) == .failed)
    }

    @Test func displayTextPrefersCleanedText() {
        #expect(transcript(at: .now, text: "raw words").displayText == "raw words")
        #expect(transcript(at: .now, text: "raw words", cleaned: "Raw words.").displayText == "Raw words.")
    }

    @Test func canRegenerateNeedsRawTextAndAFinishedStatus() {
        #expect(transcript(at: .now, status: .cleaned).canRegenerate)
        #expect(transcript(at: .now, status: .raw).canRegenerate)
        #expect(transcript(at: .now, status: .limitReached).canRegenerate)
        #expect(!transcript(at: .now, status: .failed).canRegenerate)
        #expect(!transcript(at: .now, status: .empty).canRegenerate)
        #expect(!transcript(at: .now, status: .processing).canRegenerate)
        #expect(!transcript(at: .now, text: "", status: .cleaned).canRegenerate)
    }

    @Test func isInsertableMirrorsDictationResult() {
        let statuses: [ResultStatus] = [.cleaned, .raw, .empty, .limitReached, .cancelled, .failed]
        for status in statuses {
            for text in ["", "Hello"] {
                let result = DictationResult(requestId: UUID(), documentIdentifier: nil, text: text,
                                             status: status, createdAt: .now)
                let item = Transcript(rawText: text, status: TranscriptStatus(status))
                #expect(item.isInsertable == result.isInsertable, "\(status) with \"\(text)\"")
            }
        }
        #expect(!Transcript(rawText: "Hello", status: .processing).isInsertable)
        #expect(Transcript(rawText: "", cleanedText: "Hello", status: .cleaned).isInsertable)
    }

    @Test func metricsMapFromDictationMetrics() {
        let metrics = TranscriptMetrics(DictationMetrics(audioSeconds: 12, stopToTranscriptMs: 300,
                                                         cleanupMs: 900, stopToResultMs: 1250, words: 30))
        #expect(metrics == TranscriptMetrics(audioSeconds: 12, words: 30, asrMs: 300, cleanupMs: 900,
                                             totalMs: 1250))
        #expect(metrics.ttftMs == nil)
        #expect(metrics.wpm == 150)
        #expect(TranscriptMetrics(audioSeconds: 0.2, words: 1).wpm == 0)
    }

    @Test func defaultsAreNilOrNow() {
        let before = Date()
        let item = Transcript(rawText: "Hi", status: .raw)
        #expect(item.createdAt >= before && item.createdAt <= Date())
        #expect(item.language == nil && item.cleanedText == nil && item.errorReason == nil)
        #expect(item.cleanupModel == nil && item.insertedAt == nil && item.regeneratedAt == nil)
        #expect(item.style == .casual && item.source == .keyboard)
        #expect(item.metrics == TranscriptMetrics(audioSeconds: 0, words: 0))
    }

    @Test func codableRoundTripKeepsEveryField() throws {
        let created = instant("2026-10-10T10:00:00Z")
        let original = Transcript(
            id: UUID(), createdAt: created, language: "ru-RU", style: .formal,
            rawText: "привет как дела", cleanedText: "Привет, как дела?", status: .limitReached,
            errorReason: "Monthly limit reached.",
            metrics: TranscriptMetrics(audioSeconds: 3.5, words: 3, asrMs: 210, cleanupMs: 640,
                                       ttftMs: 180, totalMs: 900),
            cleanupModel: "cleanup-model-id", insertedAt: created.addingTimeInterval(4),
            regeneratedAt: created.addingTimeInterval(60), source: .inApp
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Transcript.self, from: data) == original)

        // Enums travel as their raw strings, the form the SwiftData record stores for #Predicate.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"status\":\"limitReached\""))
        #expect(json.contains("\"style\":\"formal\""))
        #expect(json.contains("\"source\":\"inApp\""))
    }
}

struct BrandURLTests {
    @Test func settingsURLUsesTheSchemeAndTheSettingsHost() {
        let url = Brand.settingsURL
        #expect(url.scheme == Brand.urlScheme)
        #expect(url.host() == "settings")
        #expect(url.absoluteString == "\(Brand.urlScheme)://settings")
        #expect(url.absoluteString == "murmur://settings")
    }
}
