import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Settings › Languages: the summary on the Settings row, search, and picking.
@MainActor
struct LanguagePickerTests {
    @Test func theRowSummarizesThePickedLanguages() {
        #expect(LanguagePickerSheet.summary([]) == "Auto-detect")
        #expect(LanguagePickerSheet.summary(["ru-RU"]) == "Russian")
        #expect(LanguagePickerSheet.summary(["en-US", "ru-RU"]) == "English, Russian")
        #expect(LanguagePickerSheet.summary(["en-US", "ru-RU", "de-DE", "fr-FR"]) == "English, Russian +2")
    }

    @Test func searchMatchesEitherName() {
        #expect(LanguagePickerSheet.matching("russ").map(\.languageCode) == ["ru"])
        #expect(LanguagePickerSheet.matching("Русск").map(\.languageCode) == ["ru"])
        #expect(LanguagePickerSheet.matching("  ").count == DictationLanguage.cloudLanguages.count)
        #expect(LanguagePickerSheet.matching("zzz").isEmpty)
    }

    @Test func pickedLanguagesLeaveTheList() {
        let rest = LanguagePickerSheet.unpicked([DictationLanguage(tag: "ru-RU")])
        #expect(!rest.contains { $0.languageCode == "ru" })
        #expect(rest.count == DictationLanguage.cloudLanguages.count - 1)
    }

    /// A tap picks a language, a second tap (or a regional variant) unpicks it; it's saved at once.
    @Test func togglingPicksAndUnpicksByLanguage() throws {
        let suite = "test.murmur.languages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shared = SharedSettings(defaults: defaults)
        let settings = SettingsModel(settings: shared)
        settings.toggleDictationLanguage("en-US")
        settings.toggleDictationLanguage("ru-RU")
        #expect(shared.dictationLanguages == ["en-US", "ru-RU"])
        settings.toggleDictationLanguage("en-GB")
        #expect(settings.dictationLanguages == ["ru-RU"])
        settings.dictationLanguages = []
        #expect(shared.dictationLanguages.isEmpty)
    }
}

/// The mic in a note puts the text in at the cursor, as the keyboard would.
struct NoteInsertionTests {
    @Test func appendsWithASpaceAndLowercasesMidSentence() {
        let result = NoteInsertion.insert("And then lunch.", into: "Call mom", at: nil, language: "en-US")
        #expect(result.body == "Call mom and then lunch.")
        #expect(result.cursor == result.body.endIndex)
    }

    @Test func insertsAtTheCursorAndSpacesTheTextAfter() {
        let body = "Buy milk eggs"
        let cursor = body.range(of: " eggs")!.lowerBound
        let result = NoteInsertion.insert("And bread", into: body, at: cursor..<cursor, language: "en-US")
        #expect(result.body == "Buy milk and bread eggs")
        #expect(body.distance(from: body.startIndex, to: cursor) + " and bread".count
                == result.body.distance(from: result.body.startIndex, to: result.cursor))
        // Names keep their capital, as the keyboard leaves them.
        #expect(NoteInsertion.insert("Valerio", into: body, at: cursor..<cursor, language: "en-US").body
                == "Buy milk Valerio eggs")
    }

    @Test func replacesTheSelection() {
        let body = "Meet at noon today"
        let selection = body.range(of: "noon")!
        #expect(NoteInsertion.insert("The cafe", into: body, at: selection, language: "en-US").body
                == "Meet at the cafe today")
    }

    @Test func anEmptyNoteTakesTheTextAsIs() {
        #expect(NoteInsertion.insert("Hello there.", into: "", at: nil, language: nil).body == "Hello there.")
    }
}

/// iOS's rating prompt: enough good dictations, over a few days, once per version.
struct RatingPromptTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func dictations(_ count: Int, days: Int, words: Int = 8, status: TranscriptStatus = .cleaned) -> [Transcript] {
        (0..<count).map { index in
            Transcript(id: UUID(), createdAt: now.addingTimeInterval(-Double(index % days) * 86_400 - 60),
                       language: "en-US", style: .verbatim, rawText: "text", cleanedText: "Text.", status: status,
                       metrics: TranscriptMetrics(audioSeconds: 3, words: words))
        }
    }

    @Test func asksAfterTenGoodDictationsOnThreeDays() {
        let record = RatingPrompt.Record()
        #expect(RatingPrompt.shouldAsk(history: dictations(10, days: 3), record: record, version: "1.0", now: now))
        #expect(!RatingPrompt.shouldAsk(history: dictations(9, days: 3), record: record, version: "1.0", now: now))
        #expect(!RatingPrompt.shouldAsk(history: dictations(20, days: 2), record: record, version: "1.0", now: now))
        #expect(!RatingPrompt.shouldAsk(history: dictations(20, days: 4, words: 2), record: record, version: "1.0", now: now))
        #expect(!RatingPrompt.shouldAsk(history: dictations(20, days: 4, status: .failed), record: record, version: "1.0", now: now))
    }

    @Test func oncePerVersionAndNotTooSoon() {
        let history = dictations(12, days: 4)
        let asked = RatingPrompt.Record(askedVersion: "1.0", askedAt: now.addingTimeInterval(-200 * 86_400))
        #expect(!RatingPrompt.shouldAsk(history: history, record: asked, version: "1.0", now: now))
        #expect(RatingPrompt.shouldAsk(history: history, record: asked, version: "1.1", now: now))
        let recently = RatingPrompt.Record(askedVersion: "1.0", askedAt: now.addingTimeInterval(-30 * 86_400))
        #expect(!RatingPrompt.shouldAsk(history: history, record: recently, version: "1.1", now: now))
    }
}

/// 👍/👎 given on this iPhone come back on the transcript, the newest few hundred kept.
@MainActor
struct TranscriptRatingsTests {
    @Test func ratingsPersistAndTheOldestGo() throws {
        let suite = "test.murmur.ratings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID()
        let start = Date()
        TranscriptRatings.set(-1, for: first, now: start, defaults: defaults)
        #expect(TranscriptRatings.rating(for: first, defaults: defaults) == -1)
        for index in 1...TranscriptRatings.limit {
            TranscriptRatings.set(1, for: UUID(), now: start.addingTimeInterval(Double(index)), defaults: defaults)
        }
        #expect(TranscriptRatings.rating(for: first, defaults: defaults) == nil)
    }
}

/// Recordings go with their transcripts: one by one, all at once, or when they age out.
@MainActor
struct RecordingStoreTests {
    @Test func recordingsGoWithTheirTranscripts() throws {
        let recordings = RecordingStore.temporary()
        defer { recordings.deleteAll() }
        let suite = "test.murmur.recordings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = try HistoryStore(inMemory: true, settings: SharedSettings(defaults: defaults), recordings: recordings)
        let kept = UUID(), deleted = UUID()
        for id in [kept, deleted] {
            history.record(Transcript(id: id, createdAt: Date(), language: "en-US", style: .verbatim, rawText: "hi",
                                      cleanedText: "Hi.", status: .cleaned, metrics: TranscriptMetrics(audioSeconds: 1, words: 1)))
            recordings.save(EncodedAudio(data: Data("audio".utf8), format: .m4a), for: id)
        }
        #expect(recordings.url(for: kept)?.pathExtension == "m4a")

        history.delete(deleted)
        #expect(recordings.url(for: deleted) == nil)
        #expect(recordings.url(for: kept) != nil)

        recordings.prune(olderThan: Date().addingTimeInterval(-60))
        #expect(recordings.url(for: kept) != nil)
        recordings.prune(olderThan: Date().addingTimeInterval(60))
        #expect(recordings.url(for: kept) == nil)

        recordings.save(EncodedAudio(data: Data("audio".utf8), format: .wav), for: kept)
        history.deleteAll()
        #expect(recordings.url(for: kept) == nil)
    }
}
