import Foundation

/// What the keyboard knows about the field at insertion time.
public struct InsertionTraits: Sendable, Equatable {
    /// `textDocumentProxy.documentContextBeforeInput`.
    public var contextBefore: String?
    /// True when Return would submit (send/go/search/done…): newlines must not be inserted.
    public var singleLine: Bool

    public init(contextBefore: String?, singleLine: Bool) {
        self.contextBefore = contextBefore
        self.singleLine = singleLine
    }
}

/// Fits a dictation into the surrounding text: spacing, mid-sentence capitalization, and
/// single-line flattening where a newline would send the message.
public enum TextJoiner {
    public static func prepare(_ text: String, traits: InsertionTraits) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return "" }
        if traits.singleLine {
            output = flattenToSingleLine(output)
        }

        let before = traits.contextBefore ?? ""
        let lastVisible = before.last(where: { !$0.isWhitespace })

        // Continuing a sentence: lowercase a capitalized common word ("And then…" → "and then…").
        if let lastVisible, lastVisible.isLetter || lastVisible == "," || lastVisible == ";" {
            output = lowercasingLeadingCommonWord(output)
        }

        // Spacing: separate from the previous word unless we start with closing punctuation.
        if let last = before.last, !last.isWhitespace, !openingCharacters.contains(last),
           let first = output.first, !closingPunctuation.contains(first) {
            output = " " + output
        }
        return output
    }

    /// Turns lines and list items into one line: "- milk\n- eggs" → "milk, eggs".
    public static func flattenToSingleLine(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { stripListMarker($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return lines.first ?? "" }

        var result = ""
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let previousEndsSentence = result.last.map { ".!?:;".contains($0) } ?? false
                result += previousEndsSentence ? " " : ", "
            }
            result += line
        }
        return result
    }

    private static let openingCharacters: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "@", "#"]
    private static let closingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "…"]

    private static let commonLeadingWords: Set<String> = [
        "a", "an", "and", "the", "but", "or", "so", "then", "to", "of", "in", "on", "at", "for",
        "with", "it", "it's", "this", "that", "these", "those", "we", "you", "they", "he", "she",
        "my", "our", "your", "their", "is", "are", "was", "were", "will", "can", "just", "also",
        "not", "no", "yes", "if", "because", "maybe", "too", "as", "from", "about",
    ]

    private static func lowercasingLeadingCommonWord(_ text: String) -> String {
        let firstWord = text.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard let first = firstWord.first, first.isUppercase,
              commonLeadingWords.contains(firstWord.lowercased()) else { return text }
        // Don't touch all-caps words such as acronyms.
        if firstWord.count > 1, firstWord.dropFirst().allSatisfy(\.isUppercase) { return text }
        return first.lowercased() + text.dropFirst()
    }

    private static func stripListMarker(_ line: String) -> String {
        if let range = line.range(of: #"^([-•*]|\d+[.)])\s+"#, options: .regularExpression) {
            return String(line[range.upperBound...])
        }
        return line
    }
}
