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

    public init(dictionary: [DictionaryTerm] = [], snippets: [SnippetDefinition] = [], language: String? = nil) {
        self.dictionary = dictionary
        self.snippets = snippets
        self.language = language
    }

    public func format(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = Self.removeFillers(text, language: language)
        text = applyDictionary(text)
        text = applySnippets(text)
        text = Self.collapseWhitespace(text)
        return Self.capitalizeFirstLetter(text)
    }

    // MARK: Steps

    /// English hesitations are removed for every language (bilingual speakers say "um" too);
    /// the Russian ones only when the dictation is Russian.
    static func removeFillers(_ text: String, language: String? = nil) -> String {
        var output = removeMatches(of: englishFillers, in: text)
        if let language, DictationLanguage(tag: language).isRussian {
            output = removeMatches(of: russianFillers, in: output)
        }
        return output
    }

    /// "um", "uh", "erm", "uhm", "hmm" as whole words. "so, uh, we" keeps one comma: "so, we".
    private static let englishFillers = #"(?i)(,)?\s*\b(?:u+m+|u+h+|e+r+m+|u+h+m+|h+m+)\b\s*(,)?"#

    /// Vocalized hesitations only: "э", "э-э", "эм", "мм", "хм", "гм". Words such as "ну", "вот",
    /// "типа" or "короче" are left alone because they are often meaningful; the AI cleanup
    /// decides about those.
    private static let russianFillers =
        #"(?i)(,)?\s*(?<![\p{L}\p{N}])(?:э+м*|э(?:-э)+м*|м{2,}|х+м+|гм+)(?![\p{L}\p{N}-])\s*(,)?"#

    private static func removeMatches(of pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            output += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += match.range(at: 1).location != NSNotFound ? ", " : " "
            cursor = match.range.location + match.range.length
        }
        output += nsText.substring(from: cursor)
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
            .replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
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
