import Foundation

/// What "Type as I speak" (`LiveTyping`) has put into the field for one dictation, so that the
/// dictation's final text can replace exactly that, also from a keyboard that iOS created again
/// meanwhile. The keyboard writes it to `typed/record.json` before each insertion and removes it
/// when the words are replaced or taken out, when they are left as text for good (the card that
/// offers their text is tapped where they can't be replaced, or put away; the cross, or a
/// dictation that ended with nothing, where they no longer all show before the cursor; a
/// dictation that ended with nothing too long ago), and when the next dictation starts; the app removes it at
/// sign-out, and one that is a day old (`IPCPayloadStore.prune`). There is one at most.
///
/// It holds words of the dictation: at most `LiveTyping.limit` characters from its start, and the
/// last character before them in the field.
public struct LiveTypedRecord: Codable, Sendable, Equatable {
    public var requestId: UUID
    /// Exactly the characters the keyboard has inserted for this dictation, the joiner's leading
    /// space included: what stands before the cursor while nothing else has touched the field.
    public var typed: String
    /// How much of the dictation's whole settled text `typed` covers, in Unicode scalars
    /// (`LivePreview.settledLength`).
    public var settledConsumed: Int
    /// That much of the settled text, as the previews brought it.
    public var settledText: String
    /// The end of the text before the cursor when the first word went in: its last character that
    /// isn't whitespace, and the whitespace after it; at most 8 characters. The words were joined
    /// to it (`TextJoiner`), and the final text is joined to it again.
    public var contextTail: String
    /// BCP-47 tag the words are joined by while they are typed; nil means English rules.
    public var language: String?
    /// No more words are added: the final text still replaces the ones that are there.
    public var frozen: Bool
    public var updatedAt: Date

    public init(requestId: UUID, typed: String = "", settledConsumed: Int = 0, settledText: String = "",
                contextTail: String = "", language: String? = nil, frozen: Bool = false, updatedAt: Date) {
        self.requestId = requestId
        self.typed = typed
        self.settledConsumed = settledConsumed
        self.settledText = settledText
        self.contextTail = contextTail
        self.language = language
        self.frozen = frozen
        self.updatedAt = updatedAt
    }
}
