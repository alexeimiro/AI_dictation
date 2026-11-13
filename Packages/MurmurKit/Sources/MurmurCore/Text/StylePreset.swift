import Foundation

/// How a dictation is written: the Style screen's choice, which the keyboard's style pill
/// changes too.
public enum StylePreset: String, Sendable, CaseIterable, Identifiable {
    /// Keeps the speaker's exact words; translations are literal, never rephrased. The default.
    case verbatim
    /// The speaker's words and tone, made grammatically correct.
    case grammar
    /// Rewritten clear and polite, for work and email.
    case professional
    /// Lowercase and relaxed, like a text to a friend. Stored as "chat": "casual" is a style
    /// removed in November 2026 that old profiles still hold, and it must not come back as this.
    case casual = "chat"
    /// The same message in fewer words.
    case concise

    public var id: String { rawValue }

    /// Reads a stored raw value. The styles removed in November 2026 (formal, casual, veryCasual,
    /// excited) and anything unknown read as Word for word, the default, so settings, history and
    /// IPC files written by older builds still load.
    public init(stored rawValue: String) {
        self = StylePreset(rawValue: rawValue) ?? .verbatim
    }

    /// The model writes the text. Word for word asks it only for what `CleanupGate` finds.
    public var usesModel: Bool { self != .verbatim }

    public var title: String {
        switch self {
        case .verbatim: "Word for word"
        case .grammar: "Improve my grammar"
        case .professional: "Professional"
        case .casual: "Casual"
        case .concise: "Concise"
        }
    }

    /// The keyboard pill's label, where "Improve my grammar" doesn't fit.
    public var shortTitle: String {
        switch self {
        case .grammar: "Grammar"
        case .verbatim, .professional, .casual, .concise: title
        }
    }

    public var subtitle: String {
        switch self {
        case .verbatim: "Your exact words, no rephrasing"
        case .grammar: "Fixes grammar, keeps your words"
        case .professional: "Clear and polite, for work and email"
        case .casual: "Lowercase and relaxed, like texting"
        case .concise: "The same message in fewer words"
        }
    }

    /// One short line under the title on the keyboard's style page, where `subtitle` doesn't fit.
    public var hint: String {
        switch self {
        case .verbatim: "Your exact words"
        case .grammar: "Fixes mistakes"
        case .professional: "For work and email"
        case .casual: "Like texting"
        case .concise: "Fewer words"
        }
    }
}

extension StylePreset: Codable {
    /// Decodes a removed style as `init(stored:)` reads it instead of failing, which would drop the
    /// whole command or record around it. Encoding writes the raw value.
    public init(from decoder: Decoder) throws {
        self.init(stored: try decoder.singleValueContainer().decode(String.self))
    }
}
