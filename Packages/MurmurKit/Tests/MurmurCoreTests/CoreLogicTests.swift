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

    /// The insert time on the Debug screen is the claim marker's date.
    @Test func claimDateIsWhenTheResultWasClaimed() throws {
        let store = IPCPayloadStore(container: .temporary())
        let id = UUID()
        #expect(store.claimDate(id) == nil)
        let before = Date()
        store.claim(id)
        let claimed = try #require(store.claimDate(id))
        #expect(abs(claimed.timeIntervalSince(before)) < 2)
        #expect(store.claimDate(UUID()) == nil)
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

    /// The keyboard's ☰ menu queues words; the app takes them all at once, each word once.
    @Test func dictionaryAdditionsQueueOnceAndAreTakenTogether() throws {
        let store = IPCPayloadStore(container: .temporary())
        #expect(store.takeDictionaryAdditions().isEmpty)
        let now = Date()
        try store.append(dictionaryAddition: DictionaryAddition(term: "Mironenko", createdAt: now))
        try store.append(dictionaryAddition: DictionaryAddition(term: "mironenko", createdAt: now))
        try store.append(dictionaryAddition: DictionaryAddition(term: "Supabase", createdAt: now))
        #expect(store.takeDictionaryAdditions().map(\.term) == ["Mironenko", "Supabase"])
        #expect(store.takeDictionaryAdditions().isEmpty)
    }
}

struct DictionaryCandidateTests {
    @Test func theSelectionWinsWhenItFits() {
        #expect(DictionaryCandidate.word(selected: " Anton Mironenko ", before: "Hi Anton Mironenko") == "Anton Mironenko")
        #expect(DictionaryCandidate.word(selected: "two\nlines", before: "x") == nil)
        #expect(DictionaryCandidate.word(selected: String(repeating: "a", count: 60), before: "x") == nil)
    }

    @Test func otherwiseTheWordBeforeTheCursor() {
        #expect(DictionaryCandidate.word(selected: nil, before: "I met Mironenko. ") == "Mironenko")
        #expect(DictionaryCandidate.word(selected: "", before: "ping (Supabase)") == "Supabase")
        #expect(DictionaryCandidate.word(selected: nil, before: "it's Node.js") == "Node.js")
        #expect(DictionaryCandidate.word(selected: nil, before: "Привет, Валерио") == "Валерио")
        #expect(DictionaryCandidate.word(selected: nil, before: "call 555 ") == nil)
        #expect(DictionaryCandidate.word(selected: nil, before: "   ") == nil)
        #expect(DictionaryCandidate.word(selected: nil, before: nil) == nil)
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

    /// Chinese, Japanese and Thai put no space between words, or after their full-width marks.
    @Test func noSpaceInScriptsWrittenWithoutSpaces() {
        #expect(TextJoiner.prepare("明天见。", traits: .init(contextBefore: "好的", singleLine: false, language: "zh")) == "明天见。")
        #expect(TextJoiner.prepare("OK", traits: .init(contextBefore: "我们明天见。", singleLine: false)) == "OK")
        #expect(TextJoiner.prepare("また明日。", traits: .init(contextBefore: "了解です", singleLine: false, language: "ja")) == "また明日。")
        #expect(TextJoiner.prepare("ครับ", traits: .init(contextBefore: "สวัสดี", singleLine: false, language: "th")) == "ครับ")
        // Spaced scripts still get their space, and their own marks attach to the word before.
        #expect(TextJoiner.prepare("Merhaba.", traits: .init(contextBefore: "Selam", singleLine: false, language: "tr")) == " Merhaba.")
        #expect(TextJoiner.prepare("؟", traits: .init(contextBefore: "كيف حالك", singleLine: false, language: "ar")) == "؟")
    }
}

struct LocalFormatterTests {
    @Test func noSpaceBeforeOtherScriptsMarks() {
        #expect(LocalFormatter().format("你好 。") == "你好。")
        #expect(LocalFormatter().format("مرحبا ، كيف حالك ؟") == "مرحبا، كيف حالك؟")
        #expect(LocalFormatter().format("मैं कल आऊँगा ।") == "मैं कल आऊँगा।")
    }

    @Test func removesFillersAndCapitalizes() {
        let formatter = LocalFormatter()
        #expect(formatter.format("um so, uh, we should ship it") == "So, we should ship it")
        #expect(formatter.format("I think, um, yes") == "I think, yes")
        #expect(formatter.format("uh, okay hmm let's go") == "Okay let's go")
    }

    /// Smart formatting off: the hesitations stay; the dictionary and snippets still apply.
    @Test func keepsFillersWithoutSmartFormatting() {
        let formatter = LocalFormatter(dictionary: [DictionaryTerm(term: "Valerio", misspelling: "valeria")],
                                       removesFillers: false)
        #expect(formatter.format("um so, uh, ask valeria") == "Um so, uh, ask Valerio")
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

struct CleanupGateTests {
    /// Word for word keeps hedges, self-corrections, repeats, numbers and lists as spoken, so none
    /// of those is worth a model call.
    @Test func wordForWordSkipsTheModelForWhatItKeepsAnyway() {
        for text in [
            "Can you send me the report by Friday?",
            "I think we should ship it on Monday, after the review.",
            "Let's meet at 3, no, wait, 4 PM on Thursday.",
            "We could, like, meet tomorrow.",
            "The the meeting moved.",
            "The budget got cut to twenty five thousand dollars.",
            "Things to do today: first, run the laundry, second, buy groceries.",
            "Можешь скинуть отчёт до пятницы? Спасибо большое!",
            "Давай в три, нет, подожди, в четыре.",
            "Ну, короче, я завтра приду.",
            "Во-первых, запустить стирку, во-вторых, купить продукты.",
        ] {
            #expect(!CleanupGate.needsModel(text, style: .verbatim), "\(text)")
        }
    }

    @Test func wordForWordNeedsTheModelForCommandsAddressesAndMissingPunctuation() {
        for text in [
            "Hey, can you send me the report by Friday question mark thanks",
            "Send it today comma please.",
            "Reach me at john dot smith at gmail dot com.",
            "Можешь скинуть отчёт до пятницы вопросительный знак спасибо",
            "Пиши на иван собака яндекс, пожалуйста.",
            "can you send me the report by friday",
            "i don't know",
        ] {
            #expect(CleanupGate.needsModel(text, style: .verbatim), "\(text)")
        }
    }

    /// A grammar mistake doesn't show in the text, so Improve my grammar always asks the model.
    @Test func grammarAlwaysNeedsTheModel() {
        #expect(CleanupGate.needsModel("Can you send me the report by Friday?", style: .grammar))
        #expect(CleanupGate.needsModel("Me and him was going to the store.", style: .grammar))
    }

    /// Recognizers punctuate CJK, Arabic and Hindi with their own marks.
    @Test func punctuationInOtherScriptsCounts() {
        for text in ["你明天能把报告发给我吗？谢谢。", "明日、会議があります。", "هل يمكنك إرسال التقرير؟", "मैं कल आऊँगा।", "Γεια σου\u{037E}"] {
            #expect(!CleanupGate.needsModel(text, style: .verbatim), "\(text)")
        }
    }

    /// Smart formatting off: Word for word goes in as recognized, cues and all; grammar still asks.
    @Test func wordForWordSkipsTheModelWithoutSmartFormatting() {
        #expect(!CleanupGate.needsModel("Send it today comma please.", style: .verbatim, smartFormatting: false))
        #expect(!CleanupGate.needsModel("can you send me the report by friday", style: .verbatim, smartFormatting: false))
        #expect(CleanupGate.needsModel("Me and him was going.", style: .grammar, smartFormatting: false))
    }

    @Test func cuesAreWholeWords() {
        #expect(!CleanupGate.needsModel("Check the dashboard and the dotted line.", style: .verbatim))
        #expect(!CleanupGate.needsModel("Стоит купить сорочку.", style: .verbatim))
    }
}

struct StylePresetTests {
    @Test func wordForWordComesFirstAndIsTheFallback() {
        #expect(StylePreset.allCases == [.verbatim, .grammar])
        #expect(StylePreset(stored: "grammar") == .grammar)
        for removed in ["formal", "casual", "veryCasual", "excited", "shouty", ""] {
            #expect(StylePreset(stored: removed) == .verbatim, "\(removed)")
        }
    }

    /// An IPC file or record written by an older build must not fail to decode over its style.
    @Test func decodesARemovedStyleAsWordForWord() throws {
        let decoded = try JSONDecoder().decode([StylePreset].self, from: Data(#"["excited","grammar"]"#.utf8))
        #expect(decoded == [.verbatim, .grammar])
        #expect(String(decoding: try JSONEncoder().encode([StylePreset.grammar]), as: UTF8.self) == #"["grammar"]"#)

        let legacy = """
        {"id":"\(UUID().uuidString)","requestId":"\(UUID().uuidString)","kind":"start","createdAt":0,"styleOverride":"casual"}
        """
        let command = try JSONDecoder().decode(KeyboardCommand.self, from: Data(legacy.utf8))
        #expect(command.styleOverride == .verbatim)
    }

    @Test func settingsReadARemovedStyleAsWordForWord() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        #expect(settings.defaultStyle == .verbatim)
        defaults.set("excited", forKey: "defaultStyle")
        #expect(settings.defaultStyle == .verbatim)
        settings.defaultStyle = .grammar
        #expect(SharedSettings(defaults: defaults).defaultStyle == .grammar)
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

    /// The language lists: the name in the UI language, then the language's own where it differs.
    @Test func pickerNamesAddTheNativeName() {
        #expect(DictationLanguage(tag: "ru-RU").nativeName == "Русский")
        #expect(DictationLanguage(tag: "ru-RU").pickerName == "Russian (Русский)")
        #expect(DictationLanguage.englishUS.pickerName == "English")
        #expect(DictationLanguage.automatic.nativeName == nil)
        #expect(DictationLanguage.automatic.pickerName == "Auto-detect")
    }

    @Test func cloudLanguagesAreUniqueAndSortedByName() {
        let codes = DictationLanguage.cloudLanguages.map(\.languageCode)
        #expect(Set(codes).count == codes.count)
        #expect(codes.contains("ru") && codes.contains("en") && !codes.contains("und"))
        let names = DictationLanguage.cloudLanguagesByName.map(\.localizedName)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}

struct KeyboardLanguageDefaultsTests {
    private let available = ["en-US", "ru-RU", "uk-UA", "tr-TR", "es-ES", "zh-CN", "de-DE"].map(DictationLanguage.init(tag:))

    /// A language saved before Auto became the default was the old default, not a choice.
    @Test func listensForAnyLanguageUntilTheUserPicksOne() {
        #expect(KeyboardLanguageDefaults.source(saved: nil, autoDetectApplied: false).isAutomatic)
        #expect(KeyboardLanguageDefaults.source(saved: "ru-RU", autoDetectApplied: false).isAutomatic)
        #expect(KeyboardLanguageDefaults.source(saved: nil, autoDetectApplied: true).isAutomatic)
        #expect(KeyboardLanguageDefaults.source(saved: "ru-RU", autoDetectApplied: true).tag == "ru-RU")
        #expect(KeyboardLanguageDefaults.source(saved: "und", autoDetectApplied: true).isAutomatic)
    }

    @Test func theLettersFollowTheIPhoneUnderAuto() {
        let russian = KeyboardLanguageDefaults.interfaceLanguage(preferred: ["ru-RU", "en-RU"], available: available)
        #expect(russian?.tag == "ru-RU")
        #expect(KeyboardLanguageDefaults.typingLanguage(source: .automatic, interface: russian) == "ru")
        #expect(KeyboardLanguageDefaults.typingLanguage(source: .automatic, interface: nil) == "en")
        #expect(KeyboardLanguageDefaults.typingLanguage(source: DictationLanguage(tag: "uk-UA"), interface: russian) == "uk")
        #expect(KeyboardLanguageDefaults.interfaceLanguage(preferred: ["xx-YY"], available: available) == nil)
    }

    @Test func translationTypesInTheIPhonesLanguage() {
        func target(_ source: String, phone: [String], saved: String? = nil, recent: [String] = []) -> String {
            KeyboardLanguageDefaults.target(
                saved: saved.map(DictationLanguage.init(tag:)), source: DictationLanguage(tag: source), preferred: phone,
                available: available, recent: recent.map(DictationLanguage.init(tag:))).tag
        }
        #expect(target("und", phone: ["ru-RU"]) == "ru-RU", "Auto → Russian on a Russian iPhone")
        #expect(target("und", phone: ["en-US"]) == "en-US")
        #expect(target("ru-RU", phone: ["ru-RU"]) == "en-US", "Russian → English when the iPhone speaks the source")
        #expect(target("tr-TR", phone: ["ru-RU"]) == "ru-RU")
        // English spoken on an English iPhone: its other language, a recent one, else Spanish (not Afrikaans).
        #expect(target("en-US", phone: ["en-US", "de-DE"]) == "de-DE")
        #expect(target("en-US", phone: ["en-US"], recent: ["tr-TR"]) == "tr-TR")
        #expect(target("en-US", phone: ["en-US"]) == "es-ES")
        // A saved pick wins, unless it is the source itself.
        #expect(target("und", phone: ["ru-RU"], saved: "tr-TR") == "tr-TR")
        #expect(target("tr-TR", phone: ["ru-RU"], saved: "tr-TR") == "ru-RU")
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

        #expect(!settings.translationEnabled)
        settings.translationEnabled = true
        settings.translationSourceLanguage = "ru_RU"
        settings.translationTargetLanguage = "tr_TR"
        settings.recentTranslationLanguages = ["tr_TR", "en_US", "tr-TR"]
        #expect(settings.translationEnabled)
        #expect(settings.translationSourceLanguage == "ru-RU")
        #expect(settings.translationTargetLanguage == "tr-TR")
        #expect(settings.recentTranslationLanguages == ["tr-TR", "en-US"])

        let record = VerifiedEngineRecord(engine: "speech", osVersion: "26.6.1", verifiedAt: Date())
        settings.verifiedEngines = ["ru-RU": record]
        #expect(settings.verifiedEngines["ru-RU"]?.engine == "speech")
        #expect(settings.transcriberEngine == nil)
    }

    /// Settings › Languages: normalized, one per language, and empty is Auto-detect.
    @Test func dictationLanguagesAreNormalizedAndDeduplicatedByLanguage() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SharedSettings(defaults: defaults)
        #expect(settings.dictationLanguages.isEmpty)
        settings.dictationLanguages = ["en_US", "ru-RU", "en-GB"]
        #expect(SharedSettings(defaults: defaults).dictationLanguages == ["en-US", "ru-RU"])
        settings.dictationLanguages = []
        #expect(defaults.object(forKey: "dictationLanguages") == nil)
    }

    /// Smart formatting and recordings start on; low data mode and Auto open note start off.
    @Test func newSettingsDefaults() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SharedSettings(defaults: defaults)
        #expect(settings.smartFormatting && settings.keepRecordings)
        #expect(!settings.lowDataMode && !settings.autoOpenNote)
        settings.lowDataMode = true
        settings.smartFormatting = false
        #expect(SharedSettings(defaults: defaults).lowDataMode)
        #expect(!SharedSettings(defaults: defaults).smartFormatting)
    }

    @Test func readyHapticAndTheVoiceLayoutAreDefaultsAndAPickedLayoutPersists() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SharedSettings(defaults: defaults)
        #expect(settings.readyHaptic)
        #expect(settings.keyboardLayout == .voice)
        settings.readyHaptic = false
        settings.keyboardLayout = .qwerty
        let reread = SharedSettings(defaults: defaults)
        #expect(!reread.readyHaptic)
        #expect(reread.keyboardLayout == .qwerty)
    }

    @Test func abcSwitchesKeyboardsUntilFullQwertyIsOn() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SharedSettings(defaults: defaults)
        #expect(!settings.keyboardFullQwerty)
        settings.keyboardFullQwerty = true
        #expect(SharedSettings(defaults: defaults).keyboardFullQwerty)
    }

    @Test func keyboardAppearanceFollowsTheFieldUntilPicked() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SharedSettings(defaults: defaults)
        #expect(settings.keyboardAppearance == .automatic)
        settings.keyboardAppearance = .dark
        #expect(SharedSettings(defaults: defaults).keyboardAppearance == .dark)
        defaults.set("sepia", forKey: "keyboardAppearance")
        #expect(SharedSettings(defaults: defaults).keyboardAppearance == .automatic)
    }

    /// The keyboard shows a notice as a title and a line.
    @Test func keyboardNoticeSplitsIntoATitleAndALine() {
        let heard = KeyboardNotice.parts(of: "We didn't catch anything. Try again a little closer.")
        #expect(heard.title == "We didn't catch anything")
        #expect(heard.detail == "Try again a little closer.")
        let limit = KeyboardNotice.parts(of: Brand.limitReachedMessage)
        #expect(limit.title == "Dictation limit reached")
        #expect(limit.detail == "Get unlimited access in Murmur.")
        let question = KeyboardNotice.parts(of: "Still there? Tap the mic to go on.")
        #expect(question.title == "Still there?")
        #expect(question.detail == "Tap the mic to go on.")
        // One sentence stays whole, with or without its full stop.
        #expect(KeyboardNotice.parts(of: "No internet connection.").title == "No internet connection.")
        #expect(KeyboardNotice.parts(of: "No internet connection.").detail == nil)
        #expect(KeyboardNotice.parts(of: "  Murmur 1.0 is ready  ").title == "Murmur 1.0 is ready")
    }

    @Test func keyboardDemoRoundTripsAndLapses() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(KeyboardDemo("listening@numbers") == KeyboardDemo(state: .listening, layout: .numbers))
        #expect(KeyboardDemo("style")?.layout == nil)
        #expect(KeyboardDemo("menu@voice") == KeyboardDemo(state: .menu, layout: .voice))
        #expect(KeyboardDemo("off")?.state == .off)
        #expect(KeyboardDemo("limit@numbers") == KeyboardDemo(state: .limit, layout: .numbers))
        #expect(KeyboardDemo("settings") == nil)
        #expect(KeyboardDemo("listening@dvorak") == nil)
        #expect(KeyboardDemo("dancing") == nil)

        let settings = SharedSettings(defaults: defaults)
        #expect(settings.debugKeyboardDemo == nil)
        settings.debugKeyboardDemo = KeyboardDemo(state: .processing, layout: .voice)
        #expect(settings.debugKeyboardDemo?.value == "processing@voice")
        defaults.set(Date().addingTimeInterval(-1), forKey: "debugKeyboardDemoUntil")
        #expect(settings.debugKeyboardDemo == nil)
        settings.debugKeyboardDemo = nil
        #expect(defaults.string(forKey: "debugKeyboardDemo") == nil)
    }
}

struct IPCMessageTests {
    @Test func commandLanguageOverrideRoundTripsAndLegacyJSONStillDecodes() throws {
        let command = KeyboardCommand(requestId: UUID(), kind: .start, createdAt: Date(), languageOverride: "ru-RU",
                                      translationTargetLanguage: "tr-TR")
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(KeyboardCommand.self, from: data).languageOverride == "ru-RU")
        #expect(try JSONDecoder().decode(KeyboardCommand.self, from: data).translationTargetLanguage == "tr-TR")

        let legacy = """
        {"id":"\(UUID().uuidString)","requestId":"\(UUID().uuidString)","kind":"start","createdAt":0}
        """
        let decoded = try JSONDecoder().decode(KeyboardCommand.self, from: Data(legacy.utf8))
        #expect(decoded.languageOverride == nil)
        #expect(decoded.translationTargetLanguage == nil)
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
