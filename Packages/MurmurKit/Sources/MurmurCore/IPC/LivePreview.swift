import Foundation

/// The words of the dictation being recorded, for the keyboard to show while it listens. The app
/// writes it to `live/preview.json` and posts `IPCEvent.livePreview`; it removes the file when the
/// dictation ends, however it ends it (after a crash, when it next starts; the keyboard removes it
/// too when it stops following the dictation). With both strings empty it says only that words
/// will come for `requestId`, so the keyboard lays its listening screen out for them before the
/// first one.
/// It is a picture of what was heard, not the dictation's text: `DictationResult` stays the text
/// a dictation leaves in a field. Its words are inserted only by "Type as I speak" (`LiveTyping`),
/// and only the settled ones, which the dictation's `DictationResult` then replaces; the unsettled
/// words never reach a field.
public struct LivePreview: Codable, Sendable, Equatable {
    public var requestId: UUID
    /// Words that won't change any more, as they read.
    public var settled: String
    /// The newest words, which the recognizer may still rewrite. They follow `settled` directly
    /// and bring their own leading space when one belongs between the two.
    public var unsettled: String
    /// How long the dictation's whole settled text is, in Unicode scalars. `settled` is the end of
    /// that text (all of it, until `tail` cuts it), so this says where it belongs in it
    /// (`settledStart`): "Type as I speak" goes on from the words it has typed by it. Nothing
    /// that shows the words reads it.
    public var settledLength: Int

    /// `settledLength`: nil when `settled` is the whole settled text.
    public init(requestId: UUID, settled: String = "", unsettled: String = "", settledLength: Int? = nil) {
        self.requestId = requestId
        self.settled = settled
        self.unsettled = unsettled
        self.settledLength = settledLength ?? settled.unicodeScalars.count
    }

    /// A file written before `settledLength` has none: its settled words are taken for all of them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(UUID.self, forKey: .requestId)
        settled = try container.decode(String.self, forKey: .settled)
        unsettled = try container.decode(String.self, forKey: .unsettled)
        settledLength = try container.decodeIfPresent(Int.self, forKey: .settledLength)
            ?? settled.unicodeScalars.count
    }

    /// Where `settled` begins in the dictation's whole settled text, in Unicode scalars: 0 until
    /// the preview is cut.
    public var settledStart: Int { settledLength - settled.unicodeScalars.count }

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
    /// Only the end of a dictation is ever written to the shared container as its preview: at most
    /// `tailLimit` characters, and, for words one space apart (as the app writes them), more than
    /// `tailLimit - tailStep - 24`; a longer run of spaces at the cut is skipped whole. The cut
    /// is a whole number of `tailStep`s from the start, moved on to the start of the next word
    /// when it falls inside one (up to 24 characters further; a text without spaces is cut where
    /// it is). It therefore
    /// stays where it is while the text grows by less than a step, and the keyboard's lines don't
    /// re-wrap with every word; they do once each time the cut moves.
    ///
    /// The length of the whole settled text goes with it (`settledLength`), and what is left of
    /// `settled` is an exact end of that text. (The words "Type as I speak" has put into a field,
    /// at most `LiveTyping.limit` characters from the dictation's start, are in the container too
    /// while they are there: the keyboard's `LiveTypedRecord`.)
    public static func tail(requestId: UUID, settled: String, unsettled: String) -> LivePreview {
        // Counted on the joined text: a mark that opens `unsettled` can join the last settled
        // character into one, and the two counts would then add up to one too many.
        let text = Array(settled + unsettled)
        let total = text.count
        guard total > tailLimit else {
            return LivePreview(requestId: requestId, settled: settled, unsettled: unsettled)
        }
        var cut = ((total - tailLimit + tailStep - 1) / tailStep) * tailStep
        if !text[cut - 1].isWhitespace, !text[cut].isWhitespace,
           let space = text[cut..<min(cut + 24, total)].firstIndex(where: \.isWhitespace) {
            cut = space
        }
        while cut < total, text[cut].isWhitespace { cut += 1 }
        // The two are told apart in scalars, as they came: a mark that opens `unsettled` reads as
        // part of the last settled character and is unsettled all the same.
        let settledLength = settled.unicodeScalars.count
        let start = text[..<cut].reduce(0) { $0 + $1.unicodeScalars.count }
        guard start < settledLength else {
            return LivePreview(requestId: requestId, unsettled: String(text[cut...]), settledLength: settledLength)
        }
        return LivePreview(requestId: requestId,
                           settled: String(Substring(settled.unicodeScalars.dropFirst(start))),
                           unsettled: unsettled, settledLength: settledLength)
    }
}
