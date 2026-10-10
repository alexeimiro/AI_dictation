import Foundation

/// What the keyboard knows about the field at insertion time.
public struct InsertionTraits: Sendable, Equatable {
    /// `textDocumentProxy.documentContextBeforeInput`.
    public var contextBefore: String?
    /// True when Return would submit (send/go/search/done…): newlines must not be inserted.
    public var singleLine: Bool
    /// BCP-47 tag of the dictation's language; nil means English rules.
    public var language: String?

    public init(contextBefore: String?, singleLine: Bool, language: String? = nil) {
        self.contextBefore = contextBefore
        self.singleLine = singleLine
        self.language = language
    }
}

/// Fits a dictation into the surrounding text: spacing, mid-sentence capitalization, and
/// single-line flattening where a newline would send the message.
public enum TextJoiner {
    public static func prepare(_ text: String, traits: InsertionTraits) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return "" }
        let rules = Rules.rules(for: traits.language)
        if traits.singleLine {
            output = flattenToSingleLine(output)
        }

        let before = traits.contextBefore ?? ""
        let lastVisible = before.last(where: { !$0.isWhitespace })

        // Continuing a sentence: lowercase a capitalized common word ("And then…" → "and then…").
        if let lastVisible, lastVisible.isLetter || lastVisible == "," || lastVisible == ";" {
            output = lowercasingLeadingCommonWord(output, rules: rules)
        }

        // Spacing: separate from the previous word unless we start with closing punctuation.
        if let last = before.last, !last.isWhitespace, !rules.openingCharacters.contains(last),
           let first = output.first, !rules.closingPunctuation.contains(first) {
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

    // MARK: Language rules

    /// Per-language joining rules. The quote sets are shared (a Russian « or an English “ can
    /// appear in either); only the list of words that lose their capital mid-sentence differs.
    struct Rules: Sendable {
        var openingCharacters: Set<Character>
        var closingPunctuation: Set<Character>
        var commonLeadingWords: Set<String>

        static func rules(for language: String?) -> Rules {
            guard let language, DictationLanguage(tag: language).isRussian else { return .english }
            return .russian
        }

        private static let opening: Set<Character> = [
            "(", "[", "{", "\"", "'", "“", "‘", "«", "„", "‚", "/", "@", "#",
        ]
        private static let closing: Set<Character> = [
            ",", ".", ";", ":", "!", "?", ")", "]", "}", "…", "»", "”",
        ]

        static let english = Rules(openingCharacters: opening, closingPunctuation: closing, commonLeadingWords: [
            "a", "an", "and", "the", "but", "or", "so", "then", "to", "of", "in", "on", "at", "for",
            "with", "it", "it's", "this", "that", "these", "those", "we", "you", "they", "he", "she",
            "my", "our", "your", "their", "is", "are", "was", "were", "will", "can", "just", "also",
            "not", "no", "yes", "if", "because", "maybe", "too", "as", "from", "about",
        ])

        /// Unlike English "I", Russian "я" is lowercase mid-sentence.
        static let russian = Rules(openingCharacters: opening, closingPunctuation: closing, commonLeadingWords: [
            "я", "мы", "вы", "ты", "он", "она", "они", "оно", "и", "а", "но", "или", "что", "чтобы",
            "как", "так", "то", "это", "этот", "эта", "эти", "тот", "та", "те", "в", "во", "на", "с",
            "со", "к", "ко", "по", "за", "из", "от", "до", "у", "о", "об", "для", "при", "про", "не",
            "ни", "да", "нет", "же", "ли", "бы", "уже", "еще", "ещё", "тоже", "также", "потом",
            "затем", "если", "потому", "может", "только", "очень", "сейчас", "там", "тут", "здесь",
            "вот", "ну", "мой", "моя", "моё", "мои", "наш", "наша", "наше", "наши", "ваш", "твой",
            "их", "его", "её", "ее", "когда", "где", "куда", "почему", "кто", "который", "которая",
            "которые", "будет", "был", "была", "были", "есть", "можно", "нужно", "надо",
        ])
    }

    private static func lowercasingLeadingCommonWord(_ text: String, rules: Rules) -> String {
        let firstWord = text.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard let first = firstWord.first, first.isUppercase,
              rules.commonLeadingWords.contains(firstWord.lowercased()) else { return text }
        // Don't touch all-caps words such as acronyms.
        if firstWord.count > 1, firstWord.dropFirst().allSatisfy(\.isUppercase) { return text }
        return first.lowercased() + text.dropFirst()
    }

    private static func stripListMarker(_ line: String) -> String {
        if let range = line.range(of: #"^([-•*—–]|\d+[.)])\s+"#, options: .regularExpression) {
            return String(line[range.upperBound...])
        }
        return line
    }
}
