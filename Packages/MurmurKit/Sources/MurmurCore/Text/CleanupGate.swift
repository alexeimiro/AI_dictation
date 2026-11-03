import Foundation

/// Decides whether a transcript needs the AI cleanup or can be inserted as the recognizer wrote
/// it. The recognizer already punctuates and capitalizes, so the model only earns its 1–3 s when
/// the speaker said something it rewrites: spoken punctuation, a self-correction, a filler the
/// local formatter leaves alone, a list, a spelled-out address or number, a repeated word, or a
/// style the recognizer can't produce. A miss costs polish, never words, and Regenerate runs the
/// model anyway.
public enum CleanupGate {
    public static func needsModel(_ transcript: String, style: StylePreset) -> Bool {
        if style == .veryCasual || style == .excited { return true }
        // No punctuation at all means a recognizer that doesn't punctuate (on device).
        if transcript.rangeOfCharacter(from: CharacterSet(charactersIn: ".,!?;:…")) == nil { return true }
        let range = NSRange(transcript.startIndex..., in: transcript)
        if cueRegex?.firstMatch(in: transcript, range: range) != nil { return true }
        if repeatedWordRegex?.firstMatch(in: transcript, range: range) != nil { return true }
        return (listCueRegex?.numberOfMatches(in: transcript, range: range) ?? 0) >= 2
    }

    // MARK: Cues

    /// Whole words or phrases, case-insensitive. A space also matches a comma: "no, wait".
    private static let cues = [
        // Spoken punctuation and layout.
        "new line", "newline", "next line", "new paragraph", "comma", "period", "full stop", "question mark",
        "exclamation (?:point|mark)", "colon", "semicolon", "semi-colon", "dash", "hyphen", "ellipsis",
        "(?:open|close|end) (?:quote|quotes|paren|parenthesis|bracket)", "unquote",
        // Self-corrections.
        "no wait", "wait no", "actually", "scratch that", "strike that", "delete that", "i mean", "correction",
        "make that", "or rather",
        // Fillers the local formatter leaves alone.
        "you know", "basically", #"(?<=,\s{0,2})like(?=\s*,)"#,
        // Spelled-out addresses.
        "dot", "at sign", "underscore", "slash", "at (?:gmail|yahoo|hotmail|outlook|icloud|yandex|proton)",
        // Numbers and times the model writes as digits.
        "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion)s?",
        "percent", "dollars?", "euros?", "bucks", "o['’]?clock",
        #"(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve) (?:in the (?:morning|afternoon|evening)|at night)"#,
        // Russian: spoken punctuation and layout.
        "запятая", "запятую", "точка", "точку", "вопросительный знак", "восклицательный знак", "двоеточие", "тире",
        "дефис", "многоточие", "с новой строки", "новая строка", "новый абзац", "с нового абзаца",
        "(?:открыть|открой|закрыть|закрой) (?:кавычки|скобку|скобки)", "в скобках",
        // Russian: self-corrections.
        "нет подожди", "нет не так", "вернее", "точнее", "то есть", "в смысле", "ой", "отмени", "забудь",
        "зачеркни", "убери последнее",
        // Russian: fillers the local formatter leaves alone.
        "ну", "типа", "как бы", "короче", "в общем", "это самое", "так сказать", "блин",
        // Russian: spelled-out addresses.
        "собака", "собачка", "джимейл", "нижнее подч[её]ркивание", "сл[эе]ш",
        // Russian: numbers and times.
        #"(?:двадцат|тридцат|сорок|тысяч|миллион|миллиард|процент|рубл|доллар)\p{L}*"#,
        "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто", "сто", "двести", "триста", "четыреста",
        "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот",
        #"(?:\d+|один|два|три|четыре|пять|шесть|семь|восемь|девять|десять|одиннадцать|двенадцать) (?:утра|дня|вечера|ночи|часов|часа)"#,
    ]

    /// One of these is ordinary speech ("at first"); two make a list.
    private static let listCues = [
        "first(?:ly)?", "second(?:ly)?", "third(?:ly)?", "fourth(?:ly)?", "fifth(?:ly)?",
        "number (?:one|two|three|four|five)", "step (?:one|two|three|four|five)",
        "во-первых", "во-вторых", "в-третьих", "в-четв[её]ртых", "первое", "второе", "третье",
        "пункт (?:один|два|три|первый|второй|третий)",
    ]

    private static var cueRegex: NSRegularExpression? { wholeWords(cues) }
    private static var listCueRegex: NSRegularExpression? { wholeWords(listCues) }
    /// "the the", "I, I", «да, да»: stutters the model collapses.
    private static var repeatedWordRegex: NSRegularExpression? {
        try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}])(\p{L}+)[\s,]+\1(?![\p{L}\p{N}])"#)
    }

    private static func wholeWords(_ phrases: [String]) -> NSRegularExpression? {
        let alternatives = phrases.map { $0.replacingOccurrences(of: " ", with: #"[\s,]+"#) }.joined(separator: "|")
        return try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}])(?:"# + alternatives + #")(?![\p{L}\p{N}])"#)
    }
}
