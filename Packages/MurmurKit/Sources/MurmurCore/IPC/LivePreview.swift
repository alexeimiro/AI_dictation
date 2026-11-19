import Foundation

/// The words of the dictation being recorded, for the keyboard to show while it listens. The app
/// writes it to `live/preview.json` and posts `IPCEvent.livePreview`; it removes the file when the
/// dictation ends, however it ends it (after a crash, when it next starts; the keyboard removes it
/// too when it stops following the dictation). With both strings empty it says only that words
/// will come for `requestId`, so the keyboard lays its listening screen out for them before the
/// first one.
/// It is never inserted: `DictationResult` stays the only text that reaches a field.
public struct LivePreview: Codable, Sendable, Equatable {
    public var requestId: UUID
    /// Words that won't change any more, as they read.
    public var settled: String
    /// The newest words, which the recognizer may still rewrite. They follow `settled` directly
    /// and bring their own leading space when one belongs between the two.
    public var unsettled: String

    public init(requestId: UUID, settled: String = "", unsettled: String = "") {
        self.requestId = requestId
        self.settled = settled
        self.unsettled = unsettled
    }

    /// Everything shown: `settled + unsettled`.
    public var text: String { settled + unsettled }
    public var isEmpty: Bool { settled.isEmpty && unsettled.isEmpty }

    /// The most characters a preview carries, settled and unsettled together.
    public static let tailLimit = 320
    /// The cut moves in steps of this many characters.
    public static let tailStep = 80

    /// The preview for the words so far: all of them while they are short, otherwise their end.
    /// `settled` and `unsettled` are text as it reads, one after the other.
    ///
    /// Only the end of a dictation is ever written to the shared container: at most `tailLimit`
    /// characters, and, for words one space apart (as the app writes them), more than
    /// `tailLimit - tailStep - 24`; a longer run of spaces at the cut is skipped whole. The cut
    /// is a whole number of `tailStep`s from the start, moved on to the start of the next word
    /// when it falls inside one (up to 24 characters further; a text without spaces is cut where
    /// it is). It therefore
    /// stays where it is while the text grows by less than a step, and the keyboard's lines don't
    /// re-wrap with every word; they do once each time the cut moves.
    public static func tail(requestId: UUID, settled: String, unsettled: String) -> LivePreview {
        // Counted on the joined text: a mark that opens `unsettled` can join the last settled
        // character into one, and the two counts would then add up to one too many.
        let text = Array(settled + unsettled)
        let total = text.count
        guard total > tailLimit else {
            return LivePreview(requestId: requestId, settled: settled, unsettled: unsettled)
        }
        let boundary = min(settled.count, total)
        var cut = ((total - tailLimit + tailStep - 1) / tailStep) * tailStep
        if !text[cut - 1].isWhitespace, !text[cut].isWhitespace,
           let space = text[cut..<min(cut + 24, total)].firstIndex(where: \.isWhitespace) {
            cut = space
        }
        while cut < total, text[cut].isWhitespace { cut += 1 }
        return LivePreview(requestId: requestId,
                           settled: String(text[min(cut, boundary)..<boundary]),
                           unsettled: String(text[max(cut, boundary)..<total]))
    }
}
