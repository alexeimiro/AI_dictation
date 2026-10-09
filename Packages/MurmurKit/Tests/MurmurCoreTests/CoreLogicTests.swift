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
