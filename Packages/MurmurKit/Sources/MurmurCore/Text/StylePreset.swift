import Foundation

/// How a dictation is written: one of four modes, picked on the Style screen and from the
/// keyboard's style pill. The mode a dictation starts in is the one it is written in: changing it
/// while a dictation is recorded or written applies from the next one.
public enum StylePreset: String, Sendable, CaseIterable, Identifiable {
    /// The speaker's words in the order they were said, punctuated and capitalized. The default.
    case verbatim
    /// Grammar fixed and sentences smoothed: the same meaning, facts and tone, written fluently.
    case rewrite
    /// A clear, polite email, with a greeting and a closing when it is a whole message.
    case email
    /// Lively and playful, with light humor and an emoji or two where they help.
    case funny

    public var id: String { rawValue }

    /// Reads a stored raw value: settings, the account's style, history and IPC files written by
    /// any build. The styles of the builds before the four modes become the mode closest to them:
    /// Improve my grammar and Concise were rewrites, Professional was for work and email. Casual
    /// ("chat") kept the speaker's words, so it becomes Word-to-Word rather than Funny, which adds
    /// jokes and emoji nobody asked for. The styles removed before then (formal, casual,
    /// veryCasual, excited) and anything unknown read as Word-to-Word, the default.
    public init(stored rawValue: String) {
        if let preset = StylePreset(rawValue: rawValue) {
            self = preset
            return
        }
        switch rawValue {
        case "grammar", "concise": self = .rewrite
        case "professional": self = .email
        default: self = .verbatim
        }
    }

    /// The model writes the text. Word-to-Word asks it only for what `CleanupGate` finds.
    public var usesModel: Bool { self != .verbatim }

    public var title: String {
        switch self {
        case .verbatim: "Word-to-Word"
        case .rewrite: "Rewrite"
        case .email: "Email"
        case .funny: "Funny"
        }
    }

    /// The keyboard pill's label. Every title fits it.
    public var shortTitle: String { title }

    /// One line under the title on the Style screen and in VoiceOver.
    public var subtitle: String {
        switch self {
        case .verbatim: "Your exact words, punctuated"
        case .rewrite: "Fixes grammar and flow, keeps your meaning"
        case .email: "A clear, polite email"
        case .funny: "Playful, with a light joke or emoji"
        }
    }

    /// The short line under the title on the keyboard's style page, where `subtitle` doesn't fit.
    public var hint: String {
        switch self {
        case .verbatim: "Your exact words"
        case .rewrite: "Smooth and correct"
        case .email: "Polished for email"
        case .funny: "Light and playful"
        }
    }

    /// The SF Symbol on the mode's tile in the app and the keyboard.
    public var symbol: String {
        switch self {
        case .verbatim: "text.quote"
        case .rewrite: "wand.and.stars"
        case .email: "envelope"
        case .funny: "face.smiling"
        }
    }

    /// What the mode does, in short points for the Style screen: three, and four for Rewrite.
    public var promises: [String] {
        switch self {
        case .verbatim:
            ["Keeps every word, in the order you said it",
             "Adds punctuation and capitals",
             "Never rephrases or changes your tone"]
        case .rewrite:
            ["Fixes grammar and sentence structure",
             "Cuts repetition so it reads naturally",
             "Splits long text into paragraphs by meaning",
             "Keeps your meaning and facts, adds nothing"]
        case .email:
            ["Polite, professional and well organized",
             "Adds a greeting and sign-off when it's a whole message",
             "Never invents names, dates or promises"]
        case .funny:
            ["Friendly, lively tone with light humor",
             "An emoji or two, only where they help",
             "Keeps your meaning, never mean or over the top"]
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
