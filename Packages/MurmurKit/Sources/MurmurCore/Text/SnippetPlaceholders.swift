import Foundation

/// A snippet's place in a text before its expansion goes in: `⟦s:<id>⟧`. The AI cleanup returns
/// one where a snippet's trigger was spoken, and the app marks the triggers itself in a text no
/// model wrote. The expansion is swapped in on the device, last of all: it never leaves the
/// device, nothing restyles it, and it's never expanded twice.
public enum SnippetPlaceholders {
    /// Any placeholder, a snippet of the user's or not.
    static let pattern = #"⟦s:[0-9a-f]{8}⟧"#

    public static func token(for snippet: SnippetDefinition) -> String {
        "⟦s:\(snippet.id.uuidString.prefix(8).lowercased())⟧"
    }

    // MARK: Marking

    /// Puts each snippet's placeholder where its trigger stands in `text`: the whole phrase, in
    /// any capitals. One pass over the text, so a trigger never matches inside a placeholder
    /// (one already there, or another snippet's), and of two triggers that start at the same word
    /// the longer wins ("my work email" over "my email").
    public static func mark(in text: String, snippets: [SnippetDefinition]) -> String {
        let spoken = snippets.filter { !$0.trigger.isEmpty }.sorted { $0.trigger.count > $1.trigger.count }
        guard !spoken.isEmpty else { return text }
        let triggers = spoken.map { "(" + LocalFormatter.phrasePattern($0.trigger) + ")" }.joined(separator: "|")
        // A placeholder already in the text matches first, with no group, and stays as it is.
        guard let regex = try? NSRegularExpression(
            pattern: pattern + #"|(?<![\p{L}\p{N}])(?:"# + triggers + #")(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]) else {
            return text
        }
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let said = spoken.indices.first(where: { match.range(at: $0 + 1).location != NSNotFound }) else {
                continue
            }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += token(for: spoken[said])
            cursor = match.range.location + match.range.length
        }
        return output + source.substring(from: cursor)
    }

    /// A reply the model wrote, with the snippets it missed marked too. The model returns a
    /// snippet's placeholder where its trigger was said, but not every time (live checks, November
    /// 2026): it can leave the trigger as words, keep the words and add the placeholder («на мой
    /// адрес ⟦…⟧»), or swap the placeholder in for only part of the trigger ("My ⟦…⟧" for "my home
    /// address"). The trigger is the user's cue either way: its words left beside its own
    /// placeholder go, and a trigger left as words is marked as in a text no model wrote.
    public static func repair(_ reply: String, snippets: [SnippetDefinition]) -> String {
        var output = reply
        for snippet in snippets where output.contains("⟦") {
            let token = token(for: snippet)
            guard output.contains(token) else { continue }
            let words = snippet.trigger.split(whereSeparator: \.isWhitespace).map(String.init)
            let placeholder = NSRegularExpression.escapedPattern(for: token)
            // The longest part first: the whole trigger, then "my home ⟦…⟧", then "my ⟦…⟧".
            for count in stride(from: words.count, through: 1, by: -1) {
                let start = LocalFormatter.phrasePattern(words.prefix(count).joined(separator: " "))
                let end = LocalFormatter.phrasePattern(words.suffix(count).joined(separator: " "))
                for part in [#"(?<![\p{L}\p{N}])"# + start + #"\s+"# + placeholder,
                             placeholder + #"\s+"# + end + #"(?![\p{L}\p{N}])"#] {
                    guard let regex = try? NSRegularExpression(pattern: part, options: [.caseInsensitive]) else { continue }
                    output = regex.stringByReplacingMatches(
                        in: output, range: NSRange(output.startIndex..., in: output),
                        withTemplate: NSRegularExpression.escapedTemplate(for: token))
                }
            }
        }
        return mark(in: output, snippets: snippets)
    }

    // MARK: Expanding

    /// Marks that end a sentence, as a recognizer or the model puts them after a snippet.
    private static let closingMarks: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    /// Swaps each placeholder for its snippet's text, exactly as the user typed it. The marks
    /// around a placeholder are the sentence's, and two of them don't suit an expansion:
    /// - a dictation that is one snippet and nothing else is that snippet's text alone, without
    ///   the full stop the recognizer put after it ("My email address." is the address);
    /// - the full stop right after an expansion goes when the expansion ends its own sentence, or
    ///   is several lines (an address, a signature), so nothing ends in ".." or signs "Anton.".
    /// A placeholder that is no snippet of the user's is dropped rather than inserted.
    public static func substitute(in text: String, snippets: [SnippetDefinition]) -> String {
        guard text.contains("⟦"), let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let expansions = Dictionary(snippets.map { (token(for: $0), $0.expansion) }, uniquingKeysWith: { first, _ in first })

        if matches.count == 1, let expansion = expansions[source.substring(with: matches[0].range)] {
            let before = source.substring(to: matches[0].range.location)
            let after = source.substring(from: matches[0].range.location + matches[0].range.length)
            if before.allSatisfy(\.isWhitespace), after.allSatisfy({ $0.isWhitespace || closingMarks.contains($0) }) {
                return expansion
            }
        }

        var output = ""
        var cursor = 0
        for match in matches {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            guard let expansion = expansions[source.substring(with: match.range)] else { continue }
            output += expansion
            if endsItsOwnSentence(expansion), isFullStop(at: cursor, in: source) { cursor += 1 }
        }
        return output + source.substring(from: cursor)
    }

    /// The expansion needs no full stop after it: it ends with a mark of its own, or it's a block
    /// of several lines.
    private static func endsItsOwnSentence(_ expansion: String) -> Bool {
        let text = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return false }
        return closingMarks.contains(last) || text.contains(where: \.isNewline)
    }

    /// A single "." at `location`: not the first of an ellipsis.
    private static func isFullStop(at location: Int, in text: NSString) -> Bool {
        guard location < text.length, text.substring(with: NSRange(location: location, length: 1)) == "." else {
            return false
        }
        return location + 1 >= text.length || text.substring(with: NSRange(location: location + 1, length: 1)) != "."
    }
}
