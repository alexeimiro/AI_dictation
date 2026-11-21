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

    /// The words of the dictation being recorded have a directory of their own, which goes whole
    /// when the dictation ends.
    @Test func theLivePreviewRoundTripsAndClearingRemovesItsDirectory() throws {
        let container = SharedContainer.temporary()
        let store = IPCPayloadStore(container: container)
        #expect(store.readLivePreview() == nil)

        let preview = LivePreview(requestId: UUID(), settled: "Hello there,", unsettled: " how are")
        try store.write(livePreview: preview)
        #expect(store.readLivePreview() == preview)

        store.clearLivePreview()
        #expect(store.readLivePreview() == nil)
        #expect(!FileManager.default.fileExists(atPath: container.directory("live").path))
        // Clearing what is already gone is harmless.
        store.clearLivePreview()
        #expect(store.readLivePreview() == nil)

        let next = LivePreview(requestId: UUID(), settled: "Привет", unsettled: "")
        try store.write(livePreview: next)
        #expect(store.readLivePreview() == next)
    }

    /// A write is staged inside `live/` and renamed over the file, so nothing is left beside it,
    /// and what a write that was cut short leaves goes with the directory. Backups skip it.
    @Test func aLivePreviewWriteLeavesNothingBesideTheFile() throws {
        let container = SharedContainer.temporary()
        let store = IPCPayloadStore(container: container)
        let live = container.directory("live")
        let id = UUID()
        try store.write(livePreview: LivePreview(requestId: id, settled: "One"))
        try store.write(livePreview: LivePreview(requestId: id, settled: "One", unsettled: " two"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: live.path) == ["preview.json"])
        #expect(store.readLivePreview()?.text == "One two")
        #expect(try live.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // What a write that was cut short would leave.
        let cutShort = live.appendingPathComponent("preview.tmp")
        try Data("{\"requestId\":".utf8).write(to: cutShort)
        #expect(try FileManager.default.contentsOfDirectory(atPath: live.path).count == 2)
        // The next write is staged in that very place and takes it along.
        try store.write(livePreview: LivePreview(requestId: id, settled: "One two", unsettled: " three"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: live.path) == ["preview.json"])
        #expect(store.readLivePreview()?.text == "One two three")
        // And the end of the dictation takes whatever is there.
        try Data("{\"requestId\":".utf8).write(to: cutShort)
        #expect(try FileManager.default.contentsOfDirectory(atPath: live.path).count == 2)
        store.clearLivePreview()
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(store.readLivePreview() == nil)
    }

    /// What "Type as I speak" typed has a directory of its own too. It outlives the preview,
    /// which goes when the recording ends: the final text has yet to replace the typed words.
    @Test func theLiveTypedRecordRoundTripsAndOutlivesThePreview() throws {
        let container = SharedContainer.temporary()
        let store = IPCPayloadStore(container: container)
        let typed = container.directory("typed")
        #expect(store.readLiveTyped() == nil)

        let id = UUID()
        var record = LiveTypedRecord(
            requestId: id, typed: " и\u{0306}од", settledConsumed: 4, settledText: "И\u{0306}од", contextTail: "а,",
            language: "ru-RU", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.write(liveTyped: record)
        #expect(store.readLiveTyped() == record)
        // To the scalar: the accent is still a mark of its own.
        #expect(store.readLiveTyped()?.typed.unicodeScalars.count == 5)
        record.typed += " и ещё"
        record.frozen = true
        try store.write(liveTyped: record)
        #expect(store.readLiveTyped() == record)
        #expect(try FileManager.default.contentsOfDirectory(atPath: typed.path) == ["record.json"])
        #expect(try typed.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        try store.write(livePreview: LivePreview(requestId: id, settled: "Йод"))
        store.clearLivePreview()
        #expect(store.readLivePreview() == nil)
        #expect(store.readLiveTyped() == record)

        // With it goes a write that was cut short.
        try Data("{\"requestId\":".utf8).write(to: typed.appendingPathComponent("record.tmp"))
        store.clearLiveTyped()
        #expect(store.readLiveTyped() == nil)
        #expect(!FileManager.default.fileExists(atPath: typed.path))
        store.clearLiveTyped()
    }

    /// The app's daily clean-up takes a record a day old: its words are ordinary text by then.
    @Test func aLiveTypedRecordADayOldIsPruned() throws {
        let store = IPCPayloadStore(container: .temporary())
        let now = Date()
        store.prune(olderThan: 24 * 3600, now: now)
        try store.write(liveTyped: LiveTypedRecord(requestId: UUID(), typed: "So I was", updatedAt: now))
        store.prune(olderThan: 24 * 3600, now: now.addingTimeInterval(23 * 3600))
        #expect(store.readLiveTyped()?.typed == "So I was")
        store.prune(olderThan: 24 * 3600, now: now.addingTimeInterval(25 * 3600))
        #expect(store.readLiveTyped() == nil)
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

    /// "Uh-huh" and "mm-hmm" are words, and so are UM, HM and a Mr Uhm in mid-sentence.
    @Test func keepsWordsThatOnlyLookLikeHesitations() {
        let formatter = LocalFormatter(language: "en-US")
        for text in [
            "Uh-huh, that works for me.",
            "Uh-oh, I forgot the keys.",
            "Mm-hmm, sounds good.",
            "Uh-uh, no way.",
            "I went to UM and then worked at HM Treasury.",
            "Call Uhm Jung-ah tomorrow.",
        ] {
            #expect(formatter.format(text) == text, "\(text)")
        }
    }

    /// A hesitation that is a sentence of its own goes with its mark, and none leaves a comma
    /// in front of a full stop.
    @Test func hesitationsLeaveNoStrayPunctuation() {
        let formatter = LocalFormatter(language: "en-US")
        #expect(formatter.format("Um. So I think we should go.") == "So I think we should go.")
        #expect(formatter.format("Um... me and him was thinking.") == "Me and him was thinking.")
        #expect(formatter.format("Yes. Um, so I think.") == "Yes. So I think.")
        #expect(formatter.format("Yes. Hmm. Okay.") == "Yes. Okay.")
        #expect(formatter.format("We could meet tomorrow, uh.") == "We could meet tomorrow.")
        #expect(formatter.format("I was thinking, um...") == "I was thinking...")
        #expect(formatter.format("We could meet tomorrow uh") == "We could meet tomorrow")
        #expect(formatter.format("Hmm.") == "")
    }

    /// "um" is a word in German, Portuguese and Croatian: English hesitations go only where they
    /// can't be words (English, an unknown language, a language not written in Latin letters).
    @Test func englishHesitationsStayInLanguagesWhereTheyAreWords() {
        #expect(LocalFormatter(language: "de-DE").format("Wir treffen uns um acht Uhr.") == "Wir treffen uns um acht Uhr.")
        #expect(LocalFormatter(language: "de").format("Es geht um das neue Projekt, um ehrlich zu sein.")
                == "Es geht um das neue Projekt, um ehrlich zu sein.")
        #expect(LocalFormatter(language: "pt-BR").format("Eu tenho um carro e um cachorro.") == "Eu tenho um carro e um cachorro.")
        #expect(LocalFormatter(language: "hr-HR").format("Zdrav um u zdravom tijelu.") == "Zdrav um u zdravom tijelu.")
        // Auto-detect that found no language still tidies as English does.
        #expect(LocalFormatter(language: "und").format("um so we should go") == "So we should go")
        #expect(LocalFormatter(language: "en-GB").format("um so we should go") == "So we should go")
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

/// A snippet's text goes in exactly as the user typed it, wherever its name was said.
struct SnippetTests {
    private let email = SnippetDefinition(trigger: "my email address", expansion: "anton@example.com")
    private let link = SnippetDefinition(trigger: "my calendar link", expansion: "https://cal.example/me")
    private let signature = SnippetDefinition(trigger: "my signature", expansion: "Best regards,\nAnton")
    private let address = SnippetDefinition(trigger: "my home address", expansion: "12 Garden Road. London N1.")

    private func expanded(_ reply: String, _ snippets: [SnippetDefinition]) -> String {
        SnippetPlaceholders.substitute(in: SnippetPlaceholders.repair(reply, snippets: snippets), snippets: snippets)
    }

    /// The commonest use: the snippet's name and nothing else. The recognizer writes it as a
    /// sentence ("My email address."); what goes in is the snippet's text, with no capital and no
    /// full stop added.
    @Test func aDictationThatIsOneSnippetIsItsTextAlone() {
        let formatter = LocalFormatter(snippets: [email, link, signature])
        #expect(formatter.format("My email address.") == "anton@example.com")
        #expect(formatter.format("my email address") == "anton@example.com")
        #expect(formatter.format("My calendar link?") == "https://cal.example/me")
        #expect(formatter.format("Um, my signature.") == "Best regards,\nAnton")
        let russian = LocalFormatter(
            snippets: [SnippetDefinition(trigger: "моя почта", expansion: "anton@example.com")], language: "ru-RU")
        #expect(russian.format("Моя почта.") == "anton@example.com")
    }

    /// A snippet that opens the text keeps the first letter the user typed; the speaker's own
    /// first word still gets its capital.
    @Test func aSnippetAtTheStartKeepsItsOwnFirstLetter() {
        let formatter = LocalFormatter(snippets: [email, link])
        #expect(formatter.format("My calendar link is the easiest way to book.")
                == "https://cal.example/me is the easiest way to book.")
        #expect(formatter.format("my email address works best") == "anton@example.com works best")
        #expect(formatter.format("send it to my email address") == "Send it to anton@example.com")
    }

    /// The spaces and marks inside a snippet's text are the user's.
    @Test func aSnippetsTextGoesInAsTyped() {
        let table = SnippetDefinition(trigger: "my table", expansion: "Name:    Anton\nRole:    Founder")
        let greeting = SnippetDefinition(trigger: "my greeting", expansion: "Bonjour ! Ça va ?")
        let formatter = LocalFormatter(snippets: [table, greeting])
        #expect(formatter.format("Here it is, my table, thanks.") == "Here it is, Name:    Anton\nRole:    Founder, thanks.")
        #expect(formatter.format("Start with my greeting and wait.") == "Start with Bonjour ! Ça va ? and wait.")
    }

    /// The sentence's full stop doesn't double the expansion's own, and doesn't sign a block of
    /// lines; after an address or a link it ends the sentence as after any word.
    @Test func noFullStopAfterAnExpansionThatEndsItsOwnSentence() {
        let formatter = LocalFormatter(snippets: [address, signature, email])
        #expect(formatter.format("Send the parcel to my home address.") == "Send the parcel to 12 Garden Road. London N1.")
        #expect(formatter.format("Thanks for the call. My signature.") == "Thanks for the call. Best regards,\nAnton")
        #expect(formatter.format("Send it to my email address.") == "Send it to anton@example.com.")
        #expect(formatter.format("Send it to my email address...") == "Send it to anton@example.com...")
    }

    /// A shorter snippet's name inside a longer snippet's text is text, not a cue.
    @Test func aSnippetNeverFiresInsideAnothersText() {
        let line = SnippetDefinition(trigger: "my booking line", expansion: "Book a slot in my calendar: https://cal.example/me")
        let calendar = SnippetDefinition(trigger: "my calendar", expansion: "https://cal.example/me")
        #expect(LocalFormatter(snippets: [calendar, line]).format("Use my booking line today")
                == "Use Book a slot in my calendar: https://cal.example/me today")
    }

    @Test func theLongerOfTwoTriggersWins() {
        let work = SnippetDefinition(trigger: "my work email", expansion: "anton@work.example")
        let home = SnippetDefinition(trigger: "my email", expansion: "anton@home.example")
        #expect(LocalFormatter(snippets: [home, work]).format("Write to my work email, not my email.")
                == "Write to anton@work.example, not anton@home.example.")
    }

    /// The model usually returns the placeholder, but not every time (live check, November 2026:
    /// «на мой адрес» came back as words from two styles). The trigger is the cue either way.
    @Test func aTriggerTheModelLeftAsWordsIsStillExpanded() {
        let courier = SnippetDefinition(trigger: "мой адрес", expansion: "ул. Садовая, д. 12")
        #expect(expanded("Скинь договор на мою почту и пришли курьера на мой адрес.", [courier])
                == "Скинь договор на мою почту и пришли курьера на ул. Садовая, д. 12.")
        // One it did mark is expanded once.
        let reply = "Write to \(SnippetPlaceholders.token(for: email)) or use my calendar link."
        #expect(expanded(reply, [email, link]) == "Write to anton@example.com or use https://cal.example/me.")
    }

    /// "My ⟦…⟧" for "my home address" (the same live check, five times of five when the sentence
    /// began with the trigger): the part of the trigger the model left beside its own placeholder
    /// goes; any other word stays.
    @Test func aTriggerTheModelHalfReplacedLeavesNoStrayWords() {
        let token = SnippetPlaceholders.token(for: address)
        #expect(SnippetPlaceholders.repair("My \(token) is where the parcel should go.", snippets: [address])
                == "\(token) is where the parcel should go.")
        #expect(SnippetPlaceholders.repair("Send it to my home \(token) today.", snippets: [address]) == "Send it to \(token) today.")
        #expect(SnippetPlaceholders.repair("Send it to \(token) address today.", snippets: [address]) == "Send it to \(token) today.")
        #expect(SnippetPlaceholders.repair("Send it to our \(token) today.", snippets: [address]) == "Send it to our \(token) today.")
        #expect(SnippetPlaceholders.repair("Is that my, \(token)?", snippets: [address]) == "Is that my, \(token)?")
    }

    /// «на мой адрес ⟦…⟧»: the model kept the trigger's words and added its placeholder. The
    /// snippet goes in once, in their place.
    @Test func aTriggerTheModelKeptBesideItsPlaceholderIsExpandedOnce() {
        let courier = SnippetDefinition(trigger: "мой адрес", expansion: "ул. Садовая, д. 12")
        let token = SnippetPlaceholders.token(for: courier)
        #expect(expanded("Пришли курьера на мой адрес \(token) до пятницы, пожалуйста.", [courier])
                == "Пришли курьера на ул. Садовая, д. 12 до пятницы, пожалуйста.")
        #expect(expanded("Пришли курьера на \(token) мой адрес до пятницы.", [courier])
                == "Пришли курьера на ул. Садовая, д. 12 до пятницы.")
        let sign = SnippetDefinition(trigger: "sig", expansion: "Best, Anton")
        #expect(expanded("Thanks, sig \(SnippetPlaceholders.token(for: sign))", [sign]) == "Thanks, Best, Anton")
    }

    /// A placeholder already in a reply stays as it is, also when a snippet's name is inside it.
    @Test func markingLeavesPlaceholdersAlone() {
        let letter = SnippetDefinition(trigger: "s", expansion: "sincerely")
        let token = SnippetPlaceholders.token(for: email)
        #expect(SnippetPlaceholders.mark(in: "Write to \(token).", snippets: [email, letter]) == "Write to \(token).")
        #expect(SnippetPlaceholders.mark(in: "No snippet here.", snippets: []) == "No snippet here.")
    }
}

struct CleanupGateTests {
    /// Word-to-Word keeps hedges, self-corrections, repeats, numbers and lists as spoken, so none
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

    /// What Rewrite, Email and Funny change doesn't show in the text, so they always ask the model.
    @Test func theModelsStylesAlwaysNeedTheModel() {
        #expect(CleanupGate.needsModel("Me and him was going to the store.", style: .rewrite))
        for style in StylePreset.allCases where style.usesModel {
            #expect(CleanupGate.needsModel("Can you send me the report by Friday?", style: style), "\(style)")
            #expect(CleanupGate.needsModel("Can you send me the report by Friday?", style: style, smartFormatting: false),
                    "\(style)")
        }
    }

    /// Recognizers punctuate CJK, Arabic and Hindi with their own marks.
    @Test func punctuationInOtherScriptsCounts() {
        for text in ["你明天能把报告发给我吗？谢谢。", "明日、会議があります。", "هل يمكنك إرسال التقرير؟", "मैं कल आऊँगा।", "Γεια σου\u{037E}"] {
            #expect(!CleanupGate.needsModel(text, style: .verbatim), "\(text)")
        }
    }

    /// Smart formatting off: Word-to-Word goes in as recognized, cues and all; Rewrite still asks.
    @Test func wordForWordSkipsTheModelWithoutSmartFormatting() {
        #expect(!CleanupGate.needsModel("Send it today comma please.", style: .verbatim, smartFormatting: false))
        #expect(!CleanupGate.needsModel("can you send me the report by friday", style: .verbatim, smartFormatting: false))
        #expect(CleanupGate.needsModel("Me and him was going.", style: .rewrite, smartFormatting: false))
    }

    @Test func cuesAreWholeWords() {
        #expect(!CleanupGate.needsModel("Check the dashboard and the dotted line.", style: .verbatim))
        #expect(!CleanupGate.needsModel("Стоит купить сорочку.", style: .verbatim))
    }
}

struct StylePresetTests {
    /// The four modes in the order the pickers show them, Word-to-Word first.
    @Test func theFourModesInOrder() {
        #expect(StylePreset.allCases == [.verbatim, .rewrite, .email, .funny])
        #expect(StylePreset.allCases.map(\.rawValue) == ["verbatim", "rewrite", "email", "funny"])
        #expect(StylePreset.allCases.map(\.title) == ["Word-to-Word", "Rewrite", "Email", "Funny"])
        for style in StylePreset.allCases {
            #expect(StylePreset(stored: style.rawValue) == style, "\(style)")
        }
    }

    /// A style an older build saved (on this iPhone, in the account, in history) becomes the mode
    /// closest to it, so nobody's choice is reset without need: Improve my grammar and Concise
    /// were rewrites, Professional was for email. Casual kept the speaker's words, so it keeps
    /// them in Word-to-Word rather than gaining jokes and emoji.
    @Test func olderStylesBecomeTheClosestMode() {
        #expect(StylePreset(stored: "grammar") == .rewrite)
        #expect(StylePreset(stored: "concise") == .rewrite)
        #expect(StylePreset(stored: "professional") == .email)
        #expect(StylePreset(stored: "chat") == .verbatim)
        for removed in ["formal", "casual", "veryCasual", "excited", "shouty", "", "Rewrite", "EMAIL"] {
            #expect(StylePreset(stored: removed) == .verbatim, "\(removed)")
        }
    }

    @Test func onlyWordToWordGoesWithoutTheModel() {
        #expect(StylePreset.allCases.filter { !$0.usesModel } == [.verbatim])
    }

    /// The pill and the keyboard's tiles have room for one short line each; every mode has a
    /// symbol and three promises for the Style screen.
    @Test func everyModeHasItsWords() {
        for style in StylePreset.allCases {
            #expect(!style.title.isEmpty && !style.subtitle.isEmpty, "\(style)")
            #expect(style.shortTitle.count <= 13, "\(style)")
            #expect(style.hint.count <= 18, "\(style)")
            #expect(!style.symbol.isEmpty, "\(style)")
            #expect(style.promises.count == 3, "\(style)")
        }
        #expect(Set(StylePreset.allCases.map(\.symbol)).count == StylePreset.allCases.count)
    }

    /// The Style screens show a different text in every mode, from the same sentence.
    @Test func theSampleDiffersInEveryMode() {
        let written = StylePreset.allCases.map(StyleSample.written)
        #expect(Set(written).count == StylePreset.allCases.count)
        #expect(written.allSatisfy { !$0.isEmpty })
        #expect(StyleSample.written(.email).contains("\n\n"))
    }

    /// An IPC file or record written by an older build must not fail to decode over its style.
    @Test func decodesAnOlderStyleAsTheClosestMode() throws {
        let decoded = try JSONDecoder().decode(
            [StylePreset].self, from: Data(#"["excited","grammar","professional","chat","funny"]"#.utf8))
        #expect(decoded == [.verbatim, .rewrite, .email, .verbatim, .funny])
        #expect(String(decoding: try JSONEncoder().encode([StylePreset.rewrite, .email]), as: UTF8.self)
                == #"["rewrite","email"]"#)

        let legacy = """
        {"id":"\(UUID().uuidString)","requestId":"\(UUID().uuidString)","kind":"start","createdAt":0,"styleOverride":"casual"}
        """
        let command = try JSONDecoder().decode(KeyboardCommand.self, from: Data(legacy.utf8))
        #expect(command.styleOverride == .verbatim)
    }

    /// The saved mode survives a relaunch (a new `SharedSettings` on the same defaults); with
    /// nothing saved it is Word-to-Word, and an older build's saved style reads as its mode.
    @Test func theSavedModeSurvivesARelaunch() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        #expect(settings.defaultStyle == .verbatim)
        defaults.set("excited", forKey: "defaultStyle")
        #expect(settings.defaultStyle == .verbatim)
        defaults.set("professional", forKey: "defaultStyle")
        #expect(SharedSettings(defaults: defaults).defaultStyle == .email)
        for style in StylePreset.allCases {
            settings.defaultStyle = style
            #expect(SharedSettings(defaults: defaults).defaultStyle == style, "\(style)")
        }
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

    @Test func theListsAreUniqueAndSortedByName() {
        for list in [DictationLanguage.speechLanguages, DictationLanguage.translationLanguages] {
            let codes = list.map(\.languageCode)
            #expect(Set(codes).count == codes.count)
            #expect(codes.contains("ru") && codes.contains("en") && !codes.contains("und"))
        }
        for list in [DictationLanguage.speechLanguagesByName, DictationLanguage.translationLanguagesByName] {
            let names = list.map(\.localizedName)
            #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
        #expect(DictationLanguage.speechLanguagesByName.count == DictationLanguage.speechLanguages.count)
        #expect(DictationLanguage.translationLanguagesByName.count == DictationLanguage.translationLanguages.count)
    }

    /// Every language that can be spoken can be typed in; the text-only ones can't be spoken.
    @Test func speechIsASubsetOfTranslation() {
        #expect(DictationLanguage.speechLanguages.count == 65)
        #expect(DictationLanguage.translationLanguages.count == 91)
        #expect(DictationLanguage.speechLanguages.allSatisfy { $0.supportsSpeech && $0.supportsTranslation })
        #expect(DictationLanguage.textOnlyLanguages.allSatisfy { !$0.supportsSpeech && $0.supportsTranslation })
        #expect(!DictationLanguage.automatic.supportsSpeech && !DictationLanguage.automatic.supportsTranslation)
    }

    /// The languages asked for first, each one recognized and translated.
    @Test func thePriorityLanguagesCanBeSpokenAndTypedIn() {
        let priority = ["en", "ru", "tr", "id", "es", "fr", "de", "it", "pt", "zh", "ja", "ko", "ar", "hi", "bn",
                        "ur", "vi", "th", "ms", "tl", "pl", "uk", "nl", "el", "fa", "he", "sv", "ro"]
        for code in priority {
            let language = DictationLanguage(tag: code)
            #expect(language.supportsSpeech, "\(code) can be spoken")
            #expect(language.supportsTranslation, "\(code) can be typed in")
        }
    }

    /// Apple's and older codes for a language count as the one in the lists.
    @Test func capabilitiesMatchByLanguageAcrossCodes() {
        #expect(DictationLanguage(tag: "fil-PH").supportsSpeech)
        #expect(DictationLanguage(tag: "fil-PH").speechEntry?.tag == "tl-PH")
        #expect(DictationLanguage(tag: "no").supportsSpeech)
        #expect(DictationLanguage(tag: "pt-PT").speechEntry?.tag == "pt-BR")
        #expect(DictationLanguage(tag: "yue-HK").supportsSpeech)
        #expect(DictationLanguage(tag: "am-ET").speechEntry == nil)
        #expect(DictationLanguage(tag: "am-ET").translationEntry?.tag == "am-ET")
        #expect(!DictationLanguage(tag: "tlh").supportsTranslation)
        // Every on-device Apple language can be spoken, so a primary language is never refused.
        for tag in ["ar-SA", "ca-ES", "cs-CZ", "da-DK", "de-CH", "el-GR", "en-IN", "es-MX", "fi-FI", "fr-CA",
                    "he-IL", "hi-IN", "hr-HR", "hu-HU", "id-ID", "it-IT", "ja-JP", "ko-KR", "ms-MY", "nb-NO",
                    "nl-BE", "pl-PL", "pt-PT", "ro-RO", "ru-RU", "sk-SK", "sv-SE", "th-TH", "tr-TR", "uk-UA",
                    "vi-VN", "yue-CN", "zh-TW"] {
            #expect(DictationLanguage(tag: tag).supportsSpeech, "\(tag) is an Apple dictation locale")
        }
    }

    @Test func filipinoIsCalledFilipino() {
        let filipino = DictationLanguage(tag: "tl-PH")
        #expect(filipino.localizedName == "Filipino")
        #expect(filipino.shortCode == "FIL")
        #expect(DictationLanguage(tag: "yue-CN").localizedName == "Cantonese")
    }

    @Test func searchFindsNamesNativeNamesCodesAndOtherNames() {
        let all = DictationLanguage.translationLanguagesByName
        func first(_ query: String) -> String? { DictationLanguage.search(query, in: all).first?.languageCode }
        #expect(first("russ") == "ru")
        #expect(first("Русский") == "ru")
        #expect(first("deutsch") == "de")
        #expect(first("espanol") == "es")
        #expect(first("日本") == "ja")
        #expect(first("Farsi") == "fa")
        #expect(first("mandarin") == "zh")
        #expect(first("tagalog") == "tl")
        #expect(first("fil") == "tl")
        #expect(first("pt") == "pt")
        #expect(first("melayu") == "ms")
        // Apple calls it Bangla; English speakers mostly search for Bengali.
        #expect(first("bengali") == "bn")
        #expect(first("কাংলা") == nil)
        #expect(first("বাংলা") == "bn")
        #expect(first("עברית") == "he")
        #expect(DictationLanguage.search("  ", in: all) == all)
        #expect(DictationLanguage.search("klingon", in: all).isEmpty)
        // A name that starts with the query comes before one that only contains it.
        let ar = DictationLanguage.search("ar", in: all).map(\.languageCode)
        #expect(ar.first == "ar")
        #expect(ar.firstIndex(of: "hy")! < ar.firstIndex(of: "bg")!)
    }

    @Test func rightToLeftLanguagesAndText() {
        for tag in ["ar-SA", "he-IL", "fa-IR", "ur-PK", "ps-AF"] {
            #expect(DictationLanguage(tag: tag).isRightToLeft, "\(tag)")
        }
        for tag in ["en-US", "ru-RU", "zh-CN", "hi-IN", "am-ET", "und"] {
            #expect(!DictationLanguage(tag: tag).isRightToLeft, "\(tag)")
        }
        #expect(TextDirection.of("مرحبا، كيف حالك؟") == .rightToLeft)
        #expect(TextDirection.of("שלום עולם") == .rightToLeft)
        #expect(TextDirection.of("۱۲۳ سلام") == .rightToLeft)
        #expect(TextDirection.of("«Привет» 123") == .leftToRight)
        #expect(TextDirection.of("Murmur مرحبا") == .leftToRight)
        #expect(TextDirection.of("12:30 — 🎉") == .leftToRight)
        #expect(TextDirection.of("") == .leftToRight)
    }

    /// Non-Latin scripts keep every character through a tag round trip and the names.
    @Test func nonLatinNamesComeFromTheLanguage() {
        #expect(DictationLanguage(tag: "ja-JP").nativeName == "日本語")
        #expect(DictationLanguage(tag: "ar-SA").nativeName == "العربية")
        #expect(DictationLanguage(tag: "hi-IN").nativeName == "हिन्दी")
        #expect(DictationLanguage(tag: "bn-BD").nativeName == "বাংলা")
        #expect(DictationLanguage(tag: "am-ET").nativeName == "አማርኛ")
        #expect(DictationLanguage(normalizing: "zh_CN").tag == "zh-CN")
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
        // A language that can only be typed in was never a Speak language: Auto-detect instead.
        #expect(KeyboardLanguageDefaults.source(saved: "am-ET", autoDetectApplied: true).isAutomatic)
        #expect(KeyboardLanguageDefaults.source(saved: "tlh", autoDetectApplied: true).isAutomatic)
        #expect(KeyboardLanguageDefaults.source(saved: "bn-BD", autoDetectApplied: true).tag == "bn-BD")
    }

    /// A saved target Murmur doesn't type in is replaced like a missing one; a text-only one stays.
    @Test func aTargetMustBeOneMurmurTypesIn() {
        let all = DictationLanguage.translationLanguages
        let amharic = KeyboardLanguageDefaults.target(
            saved: DictationLanguage(tag: "am-ET"), source: .automatic, preferred: ["en-US"], available: all, recent: [])
        #expect(amharic.tag == "am-ET")
        let unknown = KeyboardLanguageDefaults.target(
            saved: DictationLanguage(tag: "tlh"), source: .automatic, preferred: ["ka-GE"], available: all, recent: [])
        #expect(unknown.tag == "ka-GE")
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
    /// "Type as I speak" is off until the user turns it on, and the plan is Basic until the app
    /// says otherwise: an update changes nothing for anyone.
    @Test func typeAsISpeakIsOffAndThePlanBasicUntilSaid() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        #expect(!settings.liveTyping)
        #expect(!settings.planIsPro)

        settings.liveTyping = true
        settings.planIsPro = true
        #expect(SharedSettings(defaults: defaults).liveTyping)
        #expect(SharedSettings(defaults: defaults).planIsPro)
        // Signed out, or back on Basic: the switch is the user's and stays.
        settings.planIsPro = false
        #expect(!SharedSettings(defaults: defaults).planIsPro)
        #expect(SharedSettings(defaults: defaults).liveTyping)
    }

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

    /// The keyboard locks ("You are logged out") only once the app has said nobody is signed in:
    /// unwritten, after an update, it keeps working until Murmur next runs.
    @Test func theKeyboardLocksOnlyOnceTheAppSaysNobodyIsSignedIn() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SharedSettings(defaults: defaults)
        #expect(!settings.signedOut)
        settings.signedOut = true
        #expect(SharedSettings(defaults: defaults).signedOut)
        settings.signedOut = false
        #expect(!SharedSettings(defaults: defaults).signedOut)
        #expect(Brand.signInURL.absoluteString == "murmur://sign-in")
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

    /// The free words are used up until the next reset, and only until then.
    @Test func wordsUsedUpLastUntilTheWeekResets() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        let saturday = try Date("2026-11-21T10:00:00Z", strategy: .iso8601)
        #expect(settings.wordsUsedUpUntil == nil && !settings.wordsUsedUp(at: saturday))

        settings.noteWordsUsedUp(at: saturday)
        #expect(settings.wordsUsedUpUntil == (try Date("2026-11-22T08:00:00Z", strategy: .iso8601)))
        #expect(settings.wordsUsedUp(at: saturday))
        #expect(settings.wordsUsedUp(at: try Date("2026-11-22T07:59:59Z", strategy: .iso8601)))
        #expect(!settings.wordsUsedUp(at: try Date("2026-11-22T08:00:00Z", strategy: .iso8601)))

        // Past the reset the mic records again, but only the server lifts the mark itself.
        #expect(settings.wordsAwaitServer)

        // Another process (the keyboard) reads what the app wrote.
        #expect(SharedSettings(defaults: defaults).wordsUsedUp(at: saturday))
        settings.wordsUsedUpUntil = nil
        #expect(!SharedSettings(defaults: defaults).wordsUsedUp(at: saturday))
        #expect(!settings.wordsAwaitServer)
    }

    /// A refusal that reaches the iPhone just after the reset belongs to the week before: it
    /// doesn't hold the new week's words back.
    @Test func aRefusalJustAfterTheResetDoesNotHoldTheNewWeek() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        let justAfter = try Date("2026-11-22T08:05:00Z", strategy: .iso8601)
        settings.noteWordsUsedUp(at: justAfter)
        #expect(!settings.wordsUsedUp(at: justAfter))
        let wellAfter = try Date("2026-11-22T08:15:00Z", strategy: .iso8601)
        settings.noteWordsUsedUp(at: wellAfter)
        #expect(settings.wordsUsedUpUntil == (try Date("2026-11-29T08:00:00Z", strategy: .iso8601)))
    }

    /// What the server says is left: none marks the words used up (keeping an earlier reset), any lifts it.
    @Test func wordsLeftMarkOrLiftTheLimit() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        let friday = try Date("2026-11-20T12:00:00Z", strategy: .iso8601)
        settings.noteWordsLeft(0, at: friday)
        let reset = try #require(settings.wordsUsedUpUntil)
        #expect(reset == (try Date("2026-11-22T08:00:00Z", strategy: .iso8601)))
        settings.noteWordsLeft(0, at: friday.addingTimeInterval(3_600))
        #expect(settings.wordsUsedUpUntil == reset)
        settings.noteWordsLeft(12, at: friday)
        #expect(settings.wordsUsedUpUntil == nil)
    }

    /// The server counts words on Basic only. A reply that says how many are left, or a refusal
    /// for them, therefore ends "Type as I speak" at once for a plan the app last read as Pro's
    /// (a trial that ended while Murmur stayed in the background).
    @Test func countedWordsSayThePlanIsNotPro() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        let friday = try Date("2026-11-20T12:00:00Z", strategy: .iso8601)

        settings.planIsPro = true
        settings.noteWordsLeft(640, at: friday)
        #expect(!settings.planIsPro)
        settings.planIsPro = true
        settings.noteWordsLeft(0, at: friday)
        #expect(!settings.planIsPro)
        settings.planIsPro = true
        settings.noteWordsUsedUp(at: friday)
        #expect(!settings.planIsPro)
        // The switch is the user's: it waits for the plan to have it again.
        settings.liveTyping = true
        settings.noteWordsUsedUp(at: friday)
        #expect(settings.liveTyping)
    }

    /// A trial ends at a moment the server knows, and nothing tells the iPhone while Murmur stays
    /// in the background. The app writes that moment beside the plan (`planIsProUntil`), and from
    /// then on the plan reads as not Pro's, for the keyboard's "Type as I speak" as well.
    @Test func aTrialPastItsEndIsNotPros() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        let ends = try Date("2026-11-20T12:00:00Z", strategy: .iso8601)
        #expect(settings.planIsProUntil == nil)

        settings.liveTyping = true
        settings.planIsPro = true
        settings.planIsProUntil = ends
        #expect(SharedSettings(defaults: defaults).planIsProUntil == ends)
        #expect(settings.planIsPro(at: ends.addingTimeInterval(-1)))
        #expect(!settings.planIsPro(at: ends))
        #expect(!SharedSettings(defaults: defaults).planIsPro(at: ends.addingTimeInterval(3600)))

        // As the keyboard reads it, by the clock.
        settings.planIsProUntil = Date().addingTimeInterval(3600)
        #expect(settings.planIsPro)
        #expect(settings.typesAsSpoken(fullAccess: true))
        settings.planIsProUntil = Date().addingTimeInterval(-1)
        #expect(!settings.planIsPro)
        #expect(!settings.typesAsSpoken(fullAccess: true))
        #expect(!settings.typesAsSpoken(fullAccess: false))

        // No end (a subscription): the plan is what the app last wrote.
        settings.planIsProUntil = nil
        #expect(SharedSettings(defaults: defaults).planIsProUntil == nil)
        #expect(settings.planIsPro(at: .distantFuture))
        // An end to come makes nothing Pro's that isn't.
        settings.planIsPro = false
        settings.planIsProUntil = ends
        #expect(!settings.planIsPro(at: ends.addingTimeInterval(-1)))
    }

    /// The server's `week_start()`: Sunday 00:00 in Los Angeles, in summer and in winter time.
    @Test func theWeekResetsAtSundayMidnightInLosAngeles() throws {
        func reset(after iso: String) throws -> String {
            WeeklyWords.nextReset(after: try Date(iso, strategy: .iso8601)).formatted(.iso8601)
        }
        // Winter time (PST, UTC-8).
        #expect(try reset(after: "2026-11-18T12:00:00Z") == "2026-11-22T08:00:00Z")
        // Summer time (PDT, UTC-7).
        #expect(try reset(after: "2026-07-01T12:00:00Z") == "2026-07-05T07:00:00Z")
        // The week the clocks go back (Sunday 1 November 2026, 2:00 PDT): that Sunday's midnight is still PDT.
        #expect(try reset(after: "2026-10-30T12:00:00Z") == "2026-11-01T07:00:00Z")
        // The week they go forward (Sunday 8 March 2026): midnight is still PST.
        #expect(try reset(after: "2026-03-05T12:00:00Z") == "2026-03-08T08:00:00Z")
        // At the reset itself, the next one is a week on; a second before, it is that one.
        #expect(try reset(after: "2026-11-22T08:00:00Z") == "2026-11-29T08:00:00Z")
        #expect(try reset(after: "2026-11-22T07:59:59Z") == "2026-11-22T08:00:00Z")
        // Saturday evening in Los Angeles is already Sunday in UTC: still that Sunday's midnight PT.
        #expect(try reset(after: "2026-11-22T03:00:00Z") == "2026-11-22T08:00:00Z")
    }

    /// The keyboard shows a notice as a title and a line.
    @Test func keyboardNoticeSplitsIntoATitleAndALine() {
        let heard = KeyboardNotice.parts(of: "We didn't catch anything. Try again a little closer.")
        #expect(heard.title == "We didn't catch anything")
        #expect(heard.detail == "Try again a little closer.")
        let limit = KeyboardNotice.parts(of: Brand.limitReachedMessage)
        #expect(limit.title == "Dictation limit reached")
        #expect(limit.detail == "Get unlimited access in Redmic.")
        let question = KeyboardNotice.parts(of: "Still there? Tap the mic to go on.")
        #expect(question.title == "Still there?")
        #expect(question.detail == "Tap the mic to go on.")
        // One sentence stays whole, with or without its full stop.
        #expect(KeyboardNotice.parts(of: "No internet connection.").title == "No internet connection.")
        #expect(KeyboardNotice.parts(of: "No internet connection.").detail == nil)
        #expect(KeyboardNotice.parts(of: "  Redmic 1.0 is ready  ").title == "Redmic 1.0 is ready")
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
        #expect(KeyboardDemo("loggedOut") == KeyboardDemo(state: .loggedOut))
        #expect(KeyboardDemo("words@voice") == KeyboardDemo(state: .words, layout: .voice))
        #expect(KeyboardDemo("wordsStart")?.state == .wordsStart)
        #expect(KeyboardDemo("wordsRunning@numbers")?.state == .wordsRunning)
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

        // The `words` state's text: long enough to pass two lines, its end unsettled.
        let id = UUID()
        let sample = KeyboardDemo.sampleWords(for: id)
        #expect(sample.requestId == id)
        #expect(sample.text.count > 100)
        #expect(!sample.unsettled.isEmpty)
    }

    /// The `wordsRunning` state says the sample a word at a time, the last three words unsettled,
    /// and shows only the end of it, as the app would.
    @Test func theRunningDemoGrowsAndKeepsOnlyItsEnd() {
        let id = UUID()
        #expect(KeyboardDemo.runningWords(for: id, count: 0).isEmpty)
        #expect(KeyboardDemo.runningWords(for: id, count: -1).isEmpty)
        #expect(KeyboardDemo.runningWords(for: id, count: 2) == LivePreview(requestId: id, unsettled: "So I"))

        let five = KeyboardDemo.runningWords(for: id, count: 5)
        #expect(five.requestId == id)
        #expect(five.settled == "So I")
        #expect(five.unsettled == " was thinking we")

        let long = KeyboardDemo.runningWords(for: id, count: 200)
        #expect(long.text.count <= LivePreview.tailLimit)
        #expect(long.text.count > LivePreview.tailLimit - LivePreview.tailStep - 24)
        #expect(!long.unsettled.isEmpty)
        // The sample has 23 words, so the 198th to 200th are its 14th to 16th.
        #expect(long.unsettled == " morning is already")
    }
}

struct IPCMessageTests {
    /// Both processes build the notification's name from it, and the app and its keyboard are
    /// not always the same build.
    @Test func theLivePreviewEventKeepsItsWireName() {
        #expect(IPCEvent.livePreview.rawValue == "preview")
        #expect(IPCEvent.livePreview.notificationName(group: "group.example") == "group.example.preview")
    }

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

    /// «мм» after a number is millimetres.
    @Test func millimetresAreNotAHesitation() {
        let formatter = LocalFormatter(language: "ru-RU")
        #expect(formatter.format("Нужен болт на 10 мм.") == "Нужен болт на 10 мм.")
        #expect(formatter.format("Толщина листа 2,5 мм, а ширина 2 метра.") == "Толщина листа 2,5 мм, а ширина 2 метра.")
        #expect(formatter.format("Мм, вкусно.") == "Вкусно.")
    }

    @Test func russianHesitationsLeaveNoStrayPunctuation() {
        let formatter = LocalFormatter(language: "ru-RU")
        #expect(formatter.format("Хм. Не знаю.") == "Не знаю.")
        #expect(formatter.format("Да. Эм, ну ладно.") == "Да. Ну ладно.")
        #expect(formatter.format("Он сказал: «Хм».") == "Он сказал: «Хм».")
        #expect(formatter.format("Давай завтра, э-э.") == "Давай завтра.")
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
