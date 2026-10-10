import Foundation
import Testing
@testable import MurmurCore

struct HotStateTests {
    @Test func packsAndUnpacksEveryField() {
        let state = HotState(status: .recording, level: 201, requestTag: 0xBEEF, sequence: 123_456_789)
        #expect(HotState(packed: state.packed) == state)
    }

    @Test func zeroIsOff() {
        #expect(HotState(packed: 0).status == .off)
    }

    @Test func requestTagIsNeverZero() {
        let zeroPrefixed = UUID(uuid: (0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14))
        #expect(zeroPrefixed.tag16 != 0)
    }
}

struct PayloadStoreTests {
    @Test func claimSucceedsExactlyOnce() {
        let store = IPCPayloadStore(container: .temporary())
        let id = UUID()
        #expect(store.claim(id))
        #expect(!store.claim(id))
        #expect(store.isClaimed(id))
    }

    @Test func launchTokenIsSingleUseAndExpires() throws {
        let store = IPCPayloadStore(container: .temporary())
        let now = Date()
        let token = LaunchToken(requestId: UUID(), createdAt: now)
        try store.write(launchToken: token)
        #expect(store.consumeLaunchToken("wrong", maxAge: 10, now: now) == nil)

        try store.write(launchToken: token)
        #expect(store.consumeLaunchToken(token.token, maxAge: 10, now: now.addingTimeInterval(11)) == nil)

        try store.write(launchToken: token)
        #expect(store.consumeLaunchToken(token.token, maxAge: 10, now: now.addingTimeInterval(1))?.requestId
                == token.requestId)
        #expect(store.consumeLaunchToken(token.token, maxAge: 10, now: now.addingTimeInterval(1)) == nil)
    }

    @Test func resultsRoundTripAndLatestIsTracked() throws {
        let store = IPCPayloadStore(container: .temporary())
        let result = DictationResult(requestId: UUID(), documentIdentifier: UUID(), text: "Hello",
                                     status: .cleaned, createdAt: Date())
        try store.write(result: result)
        #expect(store.readResult(result.requestId)?.text == "Hello")
        #expect(store.latestResult()?.requestId == result.requestId)
    }
}

struct TextJoinerTests {
    @Test func addsLeadingSpaceAfterAWord() {
        let traits = InsertionTraits(contextBefore: "Hello", singleLine: false)
        #expect(TextJoiner.prepare("How are you?", traits: traits) == " How are you?")
    }

    @Test func noLeadingSpaceAtStartOrAfterWhitespace() {
        #expect(TextJoiner.prepare("Hi.", traits: .init(contextBefore: nil, singleLine: false)) == "Hi.")
        #expect(TextJoiner.prepare("Hi.", traits: .init(contextBefore: "Yes. ", singleLine: false)) == "Hi.")
    }

    @Test func lowercasesCommonWordMidSentence() {
        let traits = InsertionTraits(contextBefore: "I went home", singleLine: false)
        #expect(TextJoiner.prepare("And then I slept.", traits: traits) == " and then I slept.")
    }

    @Test func keepsProperNounsAndAcronyms() {
        let traits = InsertionTraits(contextBefore: "I called", singleLine: false)
        #expect(TextJoiner.prepare("Valerio today.", traits: traits) == " Valerio today.")
        #expect(TextJoiner.prepare("NASA today.", traits: traits) == " NASA today.")
    }

    @Test func flattensListsForSingleLineFields() {
        let text = "Things to buy:\n- milk\n- eggs\n- bread"
        let traits = InsertionTraits(contextBefore: nil, singleLine: true)
        #expect(TextJoiner.prepare(text, traits: traits) == "Things to buy: milk, eggs, bread")
    }
}

struct LocalFormatterTests {
    @Test func removesFillersAndCapitalizes() {
        let formatter = LocalFormatter()
        #expect(formatter.format("um so, uh, we should ship it") == "So, we should ship it")
        #expect(formatter.format("I think, um, yes") == "I think, yes")
        #expect(formatter.format("uh, okay hmm let's go") == "Okay let's go")
    }

    @Test func appliesDictionaryReplacementsAndCasing() {
        let formatter = LocalFormatter(dictionary: [
            DictionaryTerm(term: "Valerio", misspelling: "valeria"),
            DictionaryTerm(term: "iOS"),
        ])
        #expect(formatter.format("ask valeria about ios builds") == "Ask Valerio about iOS builds")
    }

    @Test func expandsSnippetsAsWholePhrases() {
        let formatter = LocalFormatter(snippets: [
            SnippetDefinition(trigger: "my calendar link", expansion: "https://cal.example/me"),
        ])
        #expect(formatter.format("book here my calendar link thanks")
                == "Book here https://cal.example/me thanks")
    }

    @Test func substitutesSnippetPlaceholders() {
        let snippet = SnippetDefinition(trigger: "my address", expansion: "1 Infinite Loop")
        let text = "Send it to \(SnippetPlaceholders.token(for: snippet)) please ⟦s:deadbeef⟧"
        #expect(SnippetPlaceholders.substitute(in: text, snippets: [snippet])
                == "Send it to 1 Infinite Loop please ")
    }

    @Test func countsWords() {
        #expect(WordCounter.count("Hello there, how are you?") == 5)
        #expect(WordCounter.wordsPerMinute(words: 30, seconds: 12) == 150)
    }
}

struct DictationLanguageTests {
    @Test func normalizesIdentifiers() {
        #expect(DictationLanguage(normalizing: "ru_RU").tag == "ru-RU")
        #expect(DictationLanguage(normalizing: "ru-RU").tag == "ru-RU")
        #expect(DictationLanguage(normalizing: "en_US").tag == "en-US")
        let russian = DictationLanguage(tag: "ru-RU")
        #expect(russian.languageCode == "ru")
        #expect(russian.shortCode == "RU")
        #expect(russian.isRussian)
        #expect(!DictationLanguage.englishUS.isRussian)
    }
}

struct SharedSettingsTests {
    @Test func migratesTheLegacyLanguageKeyAndNormalizesTags() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ru_RU", forKey: "dictationLocale")

        let settings = SharedSettings(defaults: defaults)
        #expect(settings.primaryLanguage == "ru-RU")
        #expect(defaults.string(forKey: "dictationLocale") == nil)

        settings.secondaryLanguage = "en_US"
        #expect(settings.secondaryLanguage == "en-US")
        settings.secondaryLanguage = nil
        #expect(settings.secondaryLanguage == nil)

        let record = VerifiedEngineRecord(engine: "speech", osVersion: "26.6.1", verifiedAt: Date())
        settings.verifiedEngines = ["ru-RU": record]
        #expect(settings.verifiedEngines["ru-RU"]?.engine == "speech")
        #expect(settings.transcriberEngine == nil)
    }
}

struct IPCMessageTests {
    @Test func commandLanguageOverrideRoundTripsAndLegacyJSONStillDecodes() throws {
        let command = KeyboardCommand(requestId: UUID(), kind: .start, createdAt: Date(), languageOverride: "ru-RU")
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(KeyboardCommand.self, from: data).languageOverride == "ru-RU")

        let legacy = """
        {"id":"\(UUID().uuidString)","requestId":"\(UUID().uuidString)","kind":"start","createdAt":0}
        """
        let decoded = try JSONDecoder().decode(KeyboardCommand.self, from: Data(legacy.utf8))
        #expect(decoded.languageOverride == nil)
        #expect(decoded.styleOverride == nil)
    }

    @Test func resultLanguageAndSessionFailureRoundTrip() throws {
        let store = IPCPayloadStore(container: .temporary())
        let result = DictationResult(requestId: UUID(), documentIdentifier: nil, text: "Привет",
                                     status: .cleaned, createdAt: Date(), language: "ru-RU")
        try store.write(result: result)
        #expect(store.readResult(result.requestId)?.language == "ru-RU")

        let failure = SessionFailure(message: "Russian needs a one-time download.", createdAt: Date())
        try store.write(sessionFailure: failure)
        #expect(store.readSessionFailure()?.message == failure.message)
        store.clearSessionFailure()
        #expect(store.readSessionFailure() == nil)
    }

    @Test func errorStatusPacks() {
        let state = HotState(status: .error, sequence: 7)
        #expect(HotState(packed: state.packed) == state)
    }
}

struct RussianTextJoinerTests {
    private let russian = "ru-RU"

    @Test func lowercasesCommonWordsMidSentenceIncludingYa() {
        let traits = InsertionTraits(contextBefore: "Я пошёл домой", singleLine: false, language: russian)
        #expect(TextJoiner.prepare("И потом я уснул.", traits: traits) == " и потом я уснул.")
        let afterComma = InsertionTraits(contextBefore: "Я сказал,", singleLine: false, language: russian)
        #expect(TextJoiner.prepare("Я приду.", traits: afterComma) == " я приду.")
    }

    @Test func keepsProperNounsAndAcronyms() {
        let traits = InsertionTraits(contextBefore: "Я позвонил", singleLine: false, language: russian)
        #expect(TextJoiner.prepare("Валерий сегодня.", traits: traits) == " Валерий сегодня.")
        #expect(TextJoiner.prepare("МГУ сегодня.", traits: traits) == " МГУ сегодня.")
    }

    @Test func spacesAroundRussianQuotes() {
        #expect(TextJoiner.prepare("«Привет»", traits: .init(contextBefore: "Он сказал:", singleLine: false, language: russian))
                == " «Привет»")
        #expect(TextJoiner.prepare("Привет»", traits: .init(contextBefore: "Он сказал: «", singleLine: false, language: russian))
                == "Привет»")
        #expect(TextJoiner.prepare("» — сказал он.", traits: .init(contextBefore: "«Привет", singleLine: false, language: russian))
                == "» — сказал он.")
    }

    @Test func flattensDashLists() {
        let traits = InsertionTraits(contextBefore: nil, singleLine: true, language: russian)
        #expect(TextJoiner.prepare("Купить:\n— молоко\n— хлеб", traits: traits) == "Купить: молоко, хлеб")
    }

    @Test func englishRulesStillApplyWithoutALanguage() {
        let traits = InsertionTraits(contextBefore: "I went home", singleLine: false)
        #expect(TextJoiner.prepare("And then I slept.", traits: traits) == " and then I slept.")
        // "Я" is not an English common word, so it keeps its capital under English rules.
        #expect(TextJoiner.prepare("Я приду.", traits: traits) == " Я приду.")
    }
}

struct RussianLocalFormatterTests {
    @Test func removesVocalizedHesitationsOnly() {
        let formatter = LocalFormatter(language: "ru-RU")
        #expect(formatter.format("э-э, мы должны это сделать") == "Мы должны это сделать")
        #expect(formatter.format("ну вот, мы идём, эм, домой") == "Ну вот, мы идём, домой")
        #expect(formatter.format("um так, мм, ладно") == "Так, ладно")
        #expect(formatter.format("Эмма купила граммов двести") == "Эмма купила граммов двести")
    }

    @Test func russianHesitationsStayInEnglishDictations() {
        #expect(LocalFormatter().format("эм, okay") == "Эм, okay")
    }

    @Test func dictionaryMatchesRegardlessOfYo() {
        let formatter = LocalFormatter(dictionary: [
            DictionaryTerm(term: "Артём"),
            DictionaryTerm(term: "Валерий", misspelling: "валера"),
        ], language: "ru-RU")
        #expect(formatter.format("позвони артем и валера") == "Позвони Артём и Валерий")
        #expect(formatter.format("Артёму привет") == "Артёму привет")
    }

    @Test func countsCyrillicWords() {
        #expect(WordCounter.count("Привет, как дела?") == 3)
    }
}
