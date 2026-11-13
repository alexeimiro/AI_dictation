import Foundation

/// The part of Casual that needs no model: lowercase sentence starts and no final full stop. A
/// dictation of three words or fewer never reaches the model, and a failed request falls back
/// to the local text, so without this pass a short reply was never casual. The other styles
/// leave the text alone.
public enum StyleFormatter {
    /// - Parameter written: the model wrote the text, already in the style. Only the ending is
    ///   enforced then: the model knows which capitals are names.
    public static func apply(_ style: StylePreset, to text: String, written: Bool = false) -> String {
        guard style == .casual else { return text }
        return droppingFinalPeriod(written ? text : lowercasingSentenceStarts(text))
    }

    // MARK: Endings

    /// A final "." that ends a sentence: not the end of an ellipsis ("...") or of a dotted
    /// abbreviation ("p.m.", "U.S.", «т.д.»).
    private static func finalPeriod(in text: String) -> String.Index? {
        guard text.last == "." else { return nil }
        let period = text.index(before: text.endIndex)
        if period > text.startIndex, text[text.index(before: period)] == "." { return nil }
        let lastWord = text.split(whereSeparator: \.isWhitespace).last ?? ""
        if lastWord.range(of: #"(?:\p{L}\.){2,}$"#, options: .regularExpression) != nil { return nil }
        return period
    }

    private static func droppingFinalPeriod(_ text: String) -> String {
        guard let period = finalPeriod(in: text) else { return text }
        return String(text[..<period])
    }

    // MARK: Casing

    /// The first word of the text, of each line and of each sentence. A sentence ends at . ! ? or …
    private static var sentenceStart: NSRegularExpression? {
        try? NSRegularExpression(pattern: #"(?:^|[.!?…]\s+|\n\s*)["'“‘«„(\[¡¿]?(\p{Lu}[\p{L}\p{M}'’]*)"#)
    }

    /// Lowercases sentence starts, except "I" ("I'm", "I'll"…) and words with capitals inside
    /// ("NASA", "McDonald's"), which are names and stay as the recognizer wrote them.
    private static func lowercasingSentenceStarts(_ text: String) -> String {
        guard let regex = sentenceStart else { return text }
        let nsText = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let range = match.range(at: 1)
            let word = nsText.substring(with: range)
            guard !keepsCapital(word) else { continue }
            output += nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
            output += word.prefix(1).lowercased() + word.dropFirst()
            cursor = range.location + range.length
        }
        return output + nsText.substring(from: cursor)
    }

    private static func keepsCapital(_ word: String) -> Bool {
        word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") || word.dropFirst().contains(where: \.isUppercase)
    }
}
