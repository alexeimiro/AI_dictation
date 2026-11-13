import Foundation

/// A personal dictionary entry. With `misspelling` set it is a replacement
/// ("Correct a misspelling"); otherwise it only fixes the term's spelling/casing.
public struct DictionaryTerm: Codable, Sendable, Equatable, Hashable {
    public var term: String
    public var misspelling: String?

    public init(term: String, misspelling: String? = nil) {
        self.term = term
        self.misspelling = misspelling
    }
}

/// A voice shortcut: saying `trigger` inserts `expansion`.
public struct SnippetDefinition: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// Deterministic cleanup used when the AI cleanup is unavailable (offline, timeout, refusal,
/// disabled), and for very short dictations.
public struct LocalFormatter: Sendable {
    public var dictionary: [DictionaryTerm]
    public var snippets: [SnippetDefinition]
    /// BCP-47 tag of the dictation; nil applies the English rules only.
    public var language: String?
    /// "Smart formatting" drops "um" and "uh"; off, the speaker's hesitations stay.
    public var removesFillers: Bool

    public init(dictionary: [DictionaryTerm] = [], snippets: [SnippetDefinition] = [], language: String? = nil,
                removesFillers: Bool = true) {
        self.dictionary = dictionary
        self.snippets = snippets
        self.language = language
        self.removesFillers = removesFillers
    }

    public func format(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if removesFillers { text = Self.removeFillers(text, language: language) }
        text = applyDictionary(text)
        text = applySnippets(text)
        text = Self.collapseWhitespace(text)
        return Self.capitalizeFirstLetter(text)
    }

    // MARK: Steps

    /// English hesitations are removed where they can't be words: in English, when the language
    /// is unknown, and in languages not written in Latin letters (bilingual speakers say "um"
    /// too). German and Portuguese "um" is a word and stays. The Russian ones go only from
    /// Russian dictations.
    static func removeFillers(_ text: String, language: String? = nil) -> String {
        let spoken = language.map(DictationLanguage.init(tag:))
        var output = text
        if spoken.map({ $0.isAutomatic || $0.languageCode == "en" || !$0.usesLatinScript }) ?? true {
            output = removeHesitations(matching: englishFillers, in: output)
        }
        if let spoken, spoken.isRussian {
            output = removeHesitations(matching: russianFillers, in: output) { token, before in
                // «мм» after a number is millimetres.
                token.lowercased().allSatisfy { $0 == "м" } && before.last(where: { !$0.isWhitespace })?.isNumber == true
            }
        }
        return output
    }

    /// "um", "uh", "erm", "uhm", "hmm" on their own: not inside "uh-huh", "mm-hmm" or "um's".
    /// "so, uh, we" keeps one comma: "so, we".
    private static let englishFillers =
        #"(?i)(,)?\s*(?<![\p{L}\p{N}'’-])(u+m+|u+h+|e+r+m+|u+h+m+|h+m+)(?![\p{L}\p{N}'’-])\s*(,)?"#

    /// Vocalized hesitations only: "э", "э-э", "эм", "мм", "хм", "гм". Words such as "ну", "вот",
    /// "типа" or "короче" are left alone because they are often meaningful; the AI cleanup
    /// decides about those.
    private static let russianFillers =
        #"(?i)(,)?\s*(?<![\p{L}\p{N}-])(э+м*|э(?:-э)+м*|м{2,}|х+м+|гм+)(?![\p{L}\p{N}-])\s*(,)?"#

    private static let sentenceEnd: Set<Character> = [".", "!", "?", "…"]

    /// Removes the hesitations `pattern` finds (group 1: a comma before, 2: the sound, 3: a comma
    /// after), except those that are words: an acronym (UM, HM), a name in mid-sentence (Uhm),
    /// and what `isWord` keeps, given the sound and the text before it. A hesitation that is a
    /// sentence of its own goes with its mark, and one at the end of a sentence takes the comma
    /// before it along.
    private static func removeHesitations(
        matching pattern: String, in text: String,
        keeping isWord: (_ sound: String, _ before: String) -> Bool = { _, _ in false }
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var output = ""
        var cursor = 0
        // The word after a removed sentence opener starts the sentence.
        var capitalizeNext = false
        func append(_ segment: String) {
            guard capitalizeNext, let first = segment.firstIndex(where: { !$0.isWhitespace }) else {
                output += segment
                return
            }
            capitalizeNext = false
            output += segment.replacingCharacters(in: first...first, with: segment[first].uppercased())
        }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            // Already taken, as the mark of the hesitation before.
            guard match.range.location >= cursor else { continue }
            let sound = source.substring(with: match.range(at: 2))
            let between = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let before = output + between
            let opensSentence = before.last(where: { !$0.isWhitespace }).map { sentenceEnd.contains($0) || $0.isNewline } ?? true
            let isAcronym = sound.count > 1 && sound == sound.uppercased()
            let isName = sound.first?.isUppercase == true && !opensSentence
            if isAcronym || isName || isWord(sound, before) { continue }

            append(between)
            var end = match.range.location + match.range.length
            let marks = source.substring(from: end).prefix(while: { sentenceEnd.contains($0) })
            if !marks.isEmpty {
                if opensSentence {
                    end += (String(marks) as NSString).length
                    output += " "
                    capitalizeNext = !output.allSatisfy(\.isWhitespace)
                }
            } else if end < source.length {
                output += match.range(at: 1).location != NSNotFound ? ", " : " "
                capitalizeNext = opensSentence && !output.allSatisfy(\.isWhitespace)
            }
            cursor = end
        }
        append(source.substring(from: cursor))
        return output
    }

    func applyDictionary(_ text: String) -> String {
        var output = text
        for entry in dictionary {
            let source = entry.misspelling ?? entry.term
            guard !source.isEmpty else { continue }
            output = Self.replaceWholePhrase(source, with: entry.term, in: output)
        }
        return output
    }

    func applySnippets(_ text: String) -> String {
        var output = text
        // Longest triggers first so "my work email" wins over "my email".
        for snippet in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            output = Self.replaceWholePhrase(snippet.trigger, with: snippet.expansion, in: output)
        }
        return output
    }

    // MARK: Helpers

    static func replaceWholePhrase(_ phrase: String, with replacement: String, in text: String) -> String {
        let escaped = yoInsensitive(NSRegularExpression.escapedPattern(for: phrase))
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// Russian "ё" is routinely written and recognized as "е", so a term matches either spelling.
    /// The replacement keeps the dictionary's own spelling.
    private static func yoInsensitive(_ pattern: String) -> String {
        var output = ""
        for character in pattern {
            switch character {
            case "е", "ё": output += "[её]"
            case "Е", "Ё": output += "[ЕЁ]"
            default: output.append(character)
            }
        }
        return output
    }

    static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([,.;:!?،؛؟।。，、！？；：])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capitalizeFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter), text[index].isLowercase else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }
}

/// The AI cleanup returns `⟦s:<id>⟧` where a snippet trigger was spoken; the app swaps in the
/// expansion locally, so expansions never leave the device and are never expanded twice.
public enum SnippetPlaceholders {
    public static func token(for snippet: SnippetDefinition) -> String {
        "⟦s:\(snippet.id.uuidString.prefix(8).lowercased())⟧"
    }

    public static func substitute(in text: String, snippets: [SnippetDefinition]) -> String {
        var output = text
        for snippet in snippets {
            output = output.replacingOccurrences(of: token(for: snippet), with: snippet.expansion)
        }
        // Drop placeholders we don't recognize rather than inserting them.
        return output.replacingOccurrences(of: #"⟦s:[0-9a-f]{8}⟧"#, with: "", options: .regularExpression)
    }
}
