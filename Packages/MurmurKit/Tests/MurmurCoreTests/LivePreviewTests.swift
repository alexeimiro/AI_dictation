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
        #expect(Set(keys) == ["requestId", "settled", "unsettled", "settledLength"])

        let words = LivePreview(requestId: id, settled: "Привет,", unsettled: " как дела")
        #expect(!words.isEmpty)
        #expect(words.text == "Привет, как дела")
        #expect(try JSONDecoder().decode(LivePreview.self, from: JSONEncoder().encode(words)) == words)
    }

    // MARK: Where the settled words belong

    /// A preview says how long the dictation's whole settled text is, in Unicode scalars, so that
    /// "Type as I speak" can tell where its settled words go on from the ones it has typed.
    /// While nothing is cut, `settled` is that whole text.
    @Test func aPreviewSaysHowLongTheSettledTextIs() throws {
        let empty = LivePreview(requestId: id)
        #expect(empty.settledLength == 0 && empty.settledStart == 0)

        let words = LivePreview(requestId: id, settled: "Привет, как", unsettled: " дела")
        #expect(words.settledLength == 11)
        #expect(words.settledStart == 0)

        // Scalars, not characters: a letter with a combining accent is two.
        let accented = LivePreview(requestId: id, settled: "cafe\u{0301}")
        #expect(accented.settled.count == 4)
        #expect(accented.settledLength == 5)

        // The end of a longer text.
        let end = LivePreview(requestId: id, settled: "nine ten", unsettled: " eleven", settledLength: 40)
        #expect(end.settledStart == 32)
        #expect(end != LivePreview(requestId: id, settled: "nine ten", unsettled: " eleven"))
        #expect(try JSONDecoder().decode(LivePreview.self, from: JSONEncoder().encode(end)) == end)

        let short = LivePreview.tail(requestId: id, settled: "Hello there,", unsettled: " how are")
        #expect(short.settledLength == 12 && short.settledStart == 0)
    }

    /// A file written by an app from before the count has none: its settled words are taken for
    /// the whole settled text, as they were until the preview was first cut.
    @Test func aPreviewFromBeforeTheCountIsReadAsWhole() throws {
        let old = Data(#"{"requestId":"\#(id.uuidString)","settled":"cafe\u0301 au","unsettled":" lait"}"#.utf8)
        let preview = try JSONDecoder().decode(LivePreview.self, from: old)
        #expect(preview == LivePreview(requestId: id, settled: "cafe\u{0301} au", unsettled: " lait"))
        #expect(preview.settledLength == 8)
        #expect(preview.settledStart == 0)

        // A file without its words is still no preview.
        let broken = Data(#"{"requestId":"\#(id.uuidString)","settledLength":3}"#.utf8)
        #expect((try? JSONDecoder().decode(LivePreview.self, from: broken)) == nil)
    }

    /// However the end of a long dictation is cut, what is left of the settled words is an exact
    /// end of the settled text, and `settledStart` is where it begins there. In scalars: in
    /// Russian with its accents apart ("й" as "и" and a mark) they are not the characters.
    @Test func theTailSaysWhereItsSettledWordsBegin() {
        let decomposed = Self.russian.map(\.decomposedStringWithCanonicalMapping)
        #expect(decomposed.joined().unicodeScalars.count > decomposed.joined().count)
        for vocabulary in [Self.english, decomposed] {
            var cuts = 0
            for step in Self.dictation(of: vocabulary, characters: 3_000) {
                let whole = Array(step.settled.unicodeScalars)
                let tail = LivePreview.tail(requestId: id, settled: step.settled, unsettled: step.unsettled)
                #expect(tail.settledLength == whole.count)
                #expect(tail.settledStart >= 0 && tail.settledStart <= whole.count)
                guard tail.settledStart >= 0, tail.settledStart <= whole.count else { continue }
                #expect(Array(tail.settled.unicodeScalars) == Array(whole[tail.settledStart...]))
                if tail.settledStart > 0 { cuts += 1 }
            }
            #expect(cuts > 0)
        }
    }

    /// A mark that opens the unsettled words reads as part of the last settled character. It is
    /// unsettled all the same: the settled words in the preview end where the settled text ends.
    @Test func aMarkThatJoinsTheSettledWordsStaysUnsettled() {
        let settled = String(repeating: "word ", count: 80) + "e"
        let whole = Array(settled.unicodeScalars)
        for unsettled in ["\u{0301}xyz and more", "\u{0301}"] {
            let tail = LivePreview.tail(requestId: id, settled: settled, unsettled: unsettled)
            #expect(tail.settledLength == whole.count)
            #expect(tail.settledStart > 0)
            #expect(Array(tail.settled.unicodeScalars) == Array(whole[tail.settledStart...]))
            #expect(tail.settled.last == "e")
            #expect(Array(tail.unsettled.unicodeScalars) == Array(unsettled.unicodeScalars))
            #expect(tail.text.count <= LivePreview.tailLimit)
        }

        // Nothing settled is left after the cut: it begins where the settled text ends, or later.
        let late = LivePreview.tail(requestId: id, settled: "Hello there,",
                                    unsettled: " " + String(repeating: "word ", count: 100))
        #expect(late.settled == "")
        #expect(late.settledLength == 12 && late.settledStart == 12)
    }
}
