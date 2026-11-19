import Foundation
import Testing
@testable import Murmur

/// How `AppleSpeechTranscriber` joined a recognizer's final results before the fold took that over
/// (its `appendSegment`), kept here word for word: the transcript must not change.
private func appendSegmentAsBefore(_ segment: String, to text: inout String) {
    guard !segment.isEmpty else { return }
    if let last = text.last, let first = segment.first,
       last.isLetter || last.isNumber, first.isLetter || first.isNumber {
        text += " "
    }
    text += segment
}

/// Final results as a recognizer sends them: with and without their own spaces, empty ones,
/// punctuation, line breaks, and scripts with and without spaces between words.
private let finalStreams: [[String]] = [
    [],
    ["Hello"],
    ["Hello", " world"],
    ["Hello", "world"],
    ["Hello,", " world."],
    ["Hello.", "Next"],
    ["", "Hello", "", " there", ""],
    ["one", "2", "three"],
    ["end.", " ", "Start"],
    ["  ", "hi"],
    ["a\n", "\nb"],
    ["Привет,", " как", " дела"],
    ["Привет", "как", "дела"],
    ["你好", "世界"],
    ["See you at 5", "pm", ", then."],
]

/// Final results, then the one that isn't final yet.
private let wordsSoFar: [(finals: [String], pending: String)] = [
    (["Hello"], " world"),
    (["Hello"], "world"),
    (["Hello"], ", world"),
    (["Hello "], "world"),
    ([], " hi"),
    (["Hello"], "   "),
    (["Hello."], "Next"),
    (["Привет,", " как"], " дела"),
    (["你好"], "世界"),
    (["  "], "hi"),
    (["a\n"], "\nb"),
    (["Hello", " there", ""], ""),
]

struct LiveWordsFoldTests {
    /// The transcript is made of the final results alone, joined as they always were. The results
    /// that come before them, which only the live words use, change nothing in it.
    @Test(arguments: finalStreams)
    func finalResultsMakeTheTranscriptAsBefore(finals: [String]) {
        var before = ""
        for segment in finals { appendSegmentAsBefore(segment, to: &before) }

        var plain = LiveWordsFold()
        for segment in finals { plain.add(segment, isFinal: true) }
        #expect(plain.text == before)

        // Each final result after the unsettled ones a recognizer sends first: the words as they
        // grow, a rewrite, and an empty one.
        var interleaved = LiveWordsFold()
        for segment in finals {
            interleaved.add(String(segment.prefix(2)), isFinal: false)
            interleaved.add(segment + " and more", isFinal: false)
            interleaved.add("something else", isFinal: false)
            interleaved.add("", isFinal: false)
            interleaved.add(segment, isFinal: true)
            #expect(interleaved.pending.isEmpty)
        }
        interleaved.add(" words still being spoken", isFinal: false)
        #expect(interleaved.text == before)
        #expect(interleaved.settled == LiveWordsFold.normalize(before))
    }

    /// A result that isn't final is only the recognizer's latest guess at the newest words: the
    /// next one takes its place, and nothing of the earlier guess stays.
    @Test func theNewestUnsettledResultReplacesTheOneBefore() {
        var fold = LiveWordsFold()
        fold.add("Hello", isFinal: true)
        fold.add(" wor", isFinal: false)
        #expect(fold.settled == "Hello" && fold.unsettled == " wor")

        fold.add(" world how", isFinal: false)
        #expect(fold.settled == "Hello" && fold.unsettled == " world how")

        fold.add(" word", isFinal: false)
        #expect(fold.settled == "Hello" && fold.unsettled == " word")
        #expect(fold.text == "Hello")
    }

    /// When the recognizer settles a stretch, it is no longer shown as unsettled as well.
    @Test func aFinalResultClearsTheUnsettledWords() {
        var fold = LiveWordsFold()
        fold.add("see you", isFinal: false)
        #expect(fold.settled.isEmpty && fold.unsettled == "see you")

        fold.add("See you at five.", isFinal: true)
        #expect(fold.settled == "See you at five.")
        #expect(fold.unsettled.isEmpty && fold.pending.isEmpty)

        fold.add(" Then", isFinal: false)
        fold.add(" Then we eat.", isFinal: true)
        #expect(fold.settled == "See you at five. Then we eat.")
        #expect(fold.unsettled.isEmpty)
    }

    /// The recognizer can take its guess back altogether: the settled words stay, alone.
    @Test func anEmptyUnsettledResultTakesTheWordsBack() {
        var fold = LiveWordsFold()
        fold.add("Hello", isFinal: true)
        fold.add(" world", isFinal: false)
        #expect(fold.unsettled == " world")

        fold.add("", isFinal: false)
        #expect(fold.unsettled.isEmpty)
        #expect(fold.settled == "Hello" && fold.text == "Hello")

        // An empty final result settles nothing and takes the guess with it.
        fold.add(" again", isFinal: false)
        fold.add("", isFinal: true)
        #expect(fold.unsettled.isEmpty && fold.settled == "Hello")
    }

    /// The preview reads as the transcript would if the unsettled words became final as they are:
    /// the same single spaces, and one between the settled and the unsettled words exactly where
    /// the transcript would have one.
    @Test(arguments: wordsSoFar.indices)
    func theWordsReadAsTheTranscriptWould(index: Int) {
        let (finals, pending) = wordsSoFar[index]
        var fold = LiveWordsFold()
        for segment in finals { fold.add(segment, isFinal: true) }
        fold.add(pending, isFinal: false)

        var transcript = fold.text
        LiveWordsFold.append(pending, to: &transcript)
        #expect(fold.settled + fold.unsettled == LiveWordsFold.normalize(transcript),
                "\(finals) then \(pending.debugDescription)")
        #expect(fold.settled == LiveWordsFold.normalize(fold.text))
        // Neither part ends with a space of its own: the one between them opens the unsettled words.
        #expect(!fold.settled.hasSuffix(" ") && !fold.unsettled.hasSuffix(" "))
    }
}
