import Foundation

/// Folds a recognizer's results into a dictation's text. Final results are joined for good and make
/// the transcript; the newest result that isn't final yet is kept beside them for the live words
/// and replaced by the next one.
struct LiveWordsFold: Sendable, Equatable {
    /// Every final result joined, as the recognizer gave them: what the transcript is made of.
    private(set) var text = ""
    /// The newest result that isn't final. The next result replaces it; a final one clears it.
    private(set) var pending = ""
    /// `text` as it reads (`normalize`), brought up to date by each final result.
    private(set) var settled = ""

    mutating func add(_ segment: String, isFinal: Bool) {
        guard isFinal else {
            pending = segment   // an empty one takes the earlier words back
            return
        }
        Self.append(segment, to: &text)
        settled = Self.normalize(text)
        pending = ""
    }

    /// What follows `settled` on screen. `settled + unsettled` equals `normalize` of `pending`
    /// joined to `text` with `append`.
    var unsettled: String {
        let words = Self.normalize(pending)
        guard !words.isEmpty, !settled.isEmpty else { return words }
        let spaced = text.last?.isWhitespace == true || pending.first?.isWhitespace == true
            || Self.joinsWithSpace(text.last, pending.first)
        return spaced ? " " + words : words
    }

    static func joinsWithSpace(_ last: Character?, _ first: Character?) -> Bool {
        guard let last, let first else { return false }
        return (last.isLetter || last.isNumber) && (first.isLetter || first.isNumber)
    }

    /// Final segments usually carry their own leading space; add one when they don't.
    static func append(_ segment: String, to text: inout String) {
        guard !segment.isEmpty else { return }
        if joinsWithSpace(text.last, segment.first) { text += " " }
        text += segment
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
