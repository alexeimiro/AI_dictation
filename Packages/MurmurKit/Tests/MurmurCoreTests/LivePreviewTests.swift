import Foundation
import Testing
@testable import MurmurCore

struct LivePreviewTests {
    private let id = UUID()

    private static let english = """
        So I was thinking we could meet on Thursday afternoon instead, because the morning is already \
        full, and then go over the numbers before anyone else arrives.
        """.split(separator: " ").map(String.init)

    private static let russian = """
        Я подумал, что мы могли бы встретиться в четверг после обеда, потому что утро уже занято, \
        а потом пройтись по цифрам до того, как придут остальные.
        """.split(separator: " ").map(String.init)

    /// A dictation as it grows, a word at a time, until it is `characters` long: after each word,
    /// everything said so far, the last three words unsettled.
    private static func dictation(of vocabulary: [String], characters: Int) -> [(settled: String, unsettled: String)] {
        var said: [String] = []
        var steps: [(settled: String, unsettled: String)] = []
        var length = 0
        while length < characters {
            said.append(vocabulary[said.count % vocabulary.count])
            let settled = said.dropLast(3).joined(separator: " ")
            let unsettled = said.suffix(3).joined(separator: " ")
            steps.append((settled, settled.isEmpty ? unsettled : " " + unsettled))
            length = settled.count + steps[steps.count - 1].unsettled.count
        }
        return steps
    }

    /// Up to `tailLimit` characters nothing is cut.
    @Test func aShortTextIsShownWhole() {
        let short = LivePreview.tail(requestId: id, settled: "Hello there,", unsettled: " how are")
        #expect(short == LivePreview(requestId: id, settled: "Hello there,", unsettled: " how are"))

        let settled = String(repeating: "word ", count: 60)
        let unsettled = String(repeating: "x", count: LivePreview.tailLimit - settled.count)
        let full = LivePreview.tail(requestId: id, settled: settled, unsettled: unsettled)
        #expect(full.text.count == LivePreview.tailLimit)
        #expect(full == LivePreview(requestId: id, settled: settled, unsettled: unsettled))

        #expect(LivePreview.tail(requestId: id, settled: "", unsettled: "").isEmpty)
    }

    /// However long the dictation, the shared container gets its end only: never more than
    /// `tailLimit` characters, and never so few that the keyboard's two lines would run short.
    @Test func onlyTheEndOfALongDictationIsWritten() {
        var longest = 0
        for step in Self.dictation(of: Self.english, characters: 5_000) {
            let whole = step.settled + step.unsettled
            let tail = LivePreview.tail(requestId: id, settled: step.settled, unsettled: step.unsettled)
            #expect(tail.requestId == id)
            #expect(tail.text.count <= LivePreview.tailLimit)
            #expect(whole.hasSuffix(tail.text))
            // What is settled stays settled, and the newest words stay the newest.
            #expect(step.settled.hasSuffix(tail.settled) && step.unsettled.hasSuffix(tail.unsettled))
            if whole.count > LivePreview.tailLimit {
                #expect(tail.text.count > LivePreview.tailLimit - LivePreview.tailStep - 24,
                        "\(tail.text.count) of \(whole.count) characters")
            } else {
                #expect(tail.text == whole)
            }
            longest = whole.count
        }
        #expect(longest >= 5_000)
    }

    /// The cut never falls inside a word.
    @Test func theTailStartsAtAWord() {
        var cuts = 0
        for step in Self.dictation(of: Self.english, characters: 5_000) {
            let whole = Array(step.settled + step.unsettled)
            guard whole.count > LivePreview.tailLimit else { continue }
            let tail = LivePreview.tail(requestId: id, settled: step.settled, unsettled: step.unsettled)
            let start = whole.count - tail.text.count
            #expect(whole[start - 1] == " ", "cut inside a word at \(start) of \(whole.count)")
            #expect(tail.text.first != " ")
            cuts += 1
        }
        #expect(cuts > 0)
    }

    /// The keyboard's lines re-wrap when the cut moves, so it moves in steps, not with every word.
    @Test func theCutStaysPutWhileTheTextGrowsByLessThanAStep() {
        var start = 0
        var moves = 0
        var longest = 0
        for step in Self.dictation(of: Self.english, characters: 5_000) {
            let whole = step.settled + step.unsettled
            let tail = LivePreview.tail(requestId: id, settled: step.settled, unsettled: step.unsettled)
            let now = whole.count - tail.text.count
            #expect(now >= start, "the cut went back from \(start) to \(now)")
            if now != start {
                moves += 1
                start = now
            }
            longest = whole.count
        }
        // At most once for each step the text grew past the limit.
        let steps = (longest - LivePreview.tailLimit + LivePreview.tailStep - 1) / LivePreview.tailStep
        #expect(moves > 0)
        #expect(moves <= steps, "\(moves) moves in \(longest) characters")
    }

    /// Chinese and Japanese have no spaces to move the cut to.
    @Test func aTextWithoutSpacesIsCutWhereItIs() {
        let said = String(repeating: "今天下午我们一起去看电影好吗", count: 100).prefix(1_000)
        let tail = LivePreview.tail(requestId: id, settled: String(said.dropLast(10)),
                                    unsettled: String(said.suffix(10)))
        #expect(tail.text.count <= LivePreview.tailLimit)
        #expect(tail.text.count > LivePreview.tailLimit - LivePreview.tailStep - 24)
        // A whole number of steps from the start.
        #expect((said.count - tail.text.count) % LivePreview.tailStep == 0)
        #expect(said.hasSuffix(tail.text))
        #expect(tail.unsettled == said.suffix(10))
    }

    /// A recognizer that settles nothing for a long stretch: the end is all unsettled.
    @Test func theCutCanFallInTheUnsettledWords() {
        let settled = "Hello there,"
        let long = Self.dictation(of: Self.english, characters: 600).last!
        let unsettled = " " + (long.settled + long.unsettled).prefix(499)
        #expect(unsettled.count == 500)
        let tail = LivePreview.tail(requestId: id, settled: settled, unsettled: unsettled)
        #expect(tail.settled == "")
        #expect(tail.unsettled.count <= LivePreview.tailLimit)
        #expect(tail.unsettled.count > LivePreview.tailLimit - LivePreview.tailStep - 24)
        #expect(unsettled.hasSuffix(tail.unsettled))
    }

    /// The limit is in characters as they read, not in bytes: Cyrillic gets as much as Latin.
    @Test func russianIsCountedInCharacters() {
        var cuts = 0
        for step in Self.dictation(of: Self.russian, characters: 2_000) {
            let whole = step.settled + step.unsettled
            guard whole.count > LivePreview.tailLimit else { continue }
            let tail = LivePreview.tail(requestId: id, settled: step.settled, unsettled: step.unsettled)
            #expect(tail.text.count <= LivePreview.tailLimit)
            #expect(tail.text.count > LivePreview.tailLimit - LivePreview.tailStep - 24,
                    "\(tail.text.count) of \(whole.count) characters")
            #expect(whole.hasSuffix(tail.text))
            #expect(tail.text.utf8.count > LivePreview.tailLimit)
            cuts += 1
        }
        #expect(cuts > 0)
    }

    /// The first unsettled character can join the last settled one into a single character (an
    /// accent, the second half of a flag): the text is then one character shorter than its parts.
    @Test func aMarkThatJoinsTheSettledWordsDoesNotTrap() {
        let words = String(repeating: "word ", count: 80)

        let accented = words + "e"
        #expect(accented.count == 401)
        let accent = LivePreview.tail(requestId: id, settled: accented, unsettled: "\u{0301}xyz and more")
        #expect(accent.text.count <= LivePreview.tailLimit)
        #expect((accented + "\u{0301}xyz and more").hasSuffix(accent.text))
        #expect(accent.text.hasSuffix("e\u{0301}xyz and more"))

        let flagged = words + "\u{1F1FA}"
        #expect(flagged.count == 401)
        let flag = LivePreview.tail(requestId: id, settled: flagged, unsettled: "\u{1F1F8} flag")
        #expect(flag.text.count <= LivePreview.tailLimit)
        #expect((flagged + "\u{1F1F8} flag").hasSuffix(flag.text))
        #expect(flag.text.hasSuffix("\u{1F1FA}\u{1F1F8} flag"))

        // Nothing but the joining mark is unsettled, so the text is exactly as long as `settled`.
        let bare = LivePreview.tail(requestId: id, settled: accented, unsettled: "\u{0301}")
        #expect(bare.text.count <= LivePreview.tailLimit)
        #expect((accented + "\u{0301}").hasSuffix(bare.text))
    }

    /// Before the first word the app publishes a preview with no words in it, which is how the
    /// keyboard learns that this dictation has one.
    @Test func anEmptyPreviewSaysOnlyThatWordsWillCome() throws {
        let empty = LivePreview(requestId: id)
        #expect(empty.isEmpty)
        #expect(empty.text == "")
        #expect(empty.settled == "" && empty.unsettled == "")

        let data = try JSONEncoder().encode(empty)
        #expect(try JSONDecoder().decode(LivePreview.self, from: data) == empty)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["requestId", "settled", "unsettled"])

        let words = LivePreview(requestId: id, settled: "Привет,", unsettled: " как дела")
        #expect(!words.isEmpty)
        #expect(words.text == "Привет, как дела")
        #expect(try JSONDecoder().decode(LivePreview.self, from: JSONEncoder().encode(words)) == words)
    }
}
