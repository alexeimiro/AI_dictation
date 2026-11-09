import Foundation

/// Decides whether a transcript needs the AI cleanup or can be inserted as the recognizer wrote
/// it. Improve my grammar always needs it: a grammar mistake doesn't show in the text. Word for
/// word keeps the speaker's words, so the model only earns its 1–3 s when there is something it
/// writes differently: no punctuation at all, a spoken punctuation or layout command, or a
/// spelled-out address. A miss costs polish, never words, and Regenerate runs the model anyway.
/// With Smart formatting off, Word for word never needs it: the text goes in as recognized.
public enum CleanupGate {
    public static func needsModel(_ transcript: String, style: StylePreset, smartFormatting: Bool = true) -> Bool {
        switch style {
        case .grammar:
            return true
        case .verbatim:
            guard smartFormatting else { return false }
            // No punctuation at all means a recognizer that doesn't punctuate (on device).
            if transcript.rangeOfCharacter(from: sentencePunctuation) == nil { return true }
            let range = NSRange(transcript.startIndex..., in: transcript)
            return commandRegex?.firstMatch(in: transcript, range: range) != nil
        }
    }

    /// Sentence and clause marks as the cloud recognizer writes them in any language: Latin and
    /// Cyrillic, full-width CJK, Arabic, Devanagari, Armenian, the Greek question mark, Ethiopic
    /// and Myanmar. Apostrophes, hyphens and quotes don't count: "i don't know" is unpunctuated.
    static let sentencePunctuation = CharacterSet(charactersIn: ".,!?;:…。．，、！？；：،؛؟।॥։\u{037E}።၊။")

    // MARK: Cues

    /// Whole words or phrases, case-insensitive. A space also matches a comma: "new, line".
    private static let commands = [
        // Spoken punctuation and layout.
        "new line", "newline", "next line", "new paragraph", "comma", "period", "full stop", "question mark",
        "exclamation (?:point|mark)", "colon", "semicolon", "semi-colon", "dash", "hyphen", "ellipsis",
        "(?:open|close|end) (?:quote|quotes|paren|parenthesis|bracket)", "unquote",
        // Spelled-out addresses.
        "dot", "at sign", "underscore", "slash", "at (?:gmail|yahoo|hotmail|outlook|icloud|yandex|proton)",
        // Russian: spoken punctuation and layout.
        "запятая", "запятую", "точка", "точку", "вопросительный знак", "восклицательный знак", "двоеточие", "тире",
        "дефис", "многоточие", "с новой строки", "новая строка", "новый абзац", "с нового абзаца",
        "(?:открыть|открой|закрыть|закрой) (?:кавычки|скобку|скобки)", "в скобках",
        // Russian: spelled-out addresses.
        "собака", "собачка", "джимейл", "нижнее подч[её]ркивание", "сл[эе]ш",
    ]

    private static var commandRegex: NSRegularExpression? {
        let alternatives = commands.map { $0.replacingOccurrences(of: " ", with: #"[\s,]+"#) }.joined(separator: "|")
        return try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}])(?:"# + alternatives + #")(?![\p{L}\p{N}])"#)
    }
}
