import Foundation

/// How a dictation is written: "Your default style" in Settings, and the keyboard's style pill.
public enum StylePreset: String, Sendable, CaseIterable, Identifiable {
    /// Keeps the speaker's exact words; translations are literal, never rephrased. The default.
    case verbatim
    /// The speaker's words and tone, made grammatically correct.
    case grammar

    public var id: String { rawValue }

    /// Reads a stored raw value. The styles removed in November 2026 (formal, casual, veryCasual,
    /// excited) and anything unknown read as Word for word, the default, so settings, history and
    /// IPC files written by older builds still load.
    public init(stored rawValue: String) {
        self = StylePreset(rawValue: rawValue) ?? .verbatim
    }

    public var title: String {
        switch self {
        case .verbatim: "Word for word"
        case .grammar: "Improve my grammar"
        }
    }

    /// The keyboard pill's label, where "Improve my grammar" doesn't fit.
    public var shortTitle: String {
        switch self {
        case .verbatim: "Word for word"
        case .grammar: "Grammar"
        }
    }

    public var subtitle: String {
        switch self {
        case .verbatim: "Your exact words, no rephrasing"
        case .grammar: "Fixes grammar, keeps your words"
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
