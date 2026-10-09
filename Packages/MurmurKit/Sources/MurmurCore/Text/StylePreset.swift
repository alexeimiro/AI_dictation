import Foundation

/// Writing style applied by the cleanup step ("Your default style" in the Style tab).
public enum StylePreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case formal
    case casual
    case veryCasual
    case excited

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .formal: "Formal."
        case .casual: "Casual"
        case .veryCasual: "very casual"
        case .excited: "Excited!"
        }
    }

    public var subtitle: String {
        switch self {
        case .formal: "Caps + punctuation"
        case .casual: "Caps + less punctuation"
        case .veryCasual: "No caps + less punctuation"
        case .excited: "More exclamations"
        }
    }

    /// Instruction passed to the cleanup model.
    public var promptInstruction: String {
        switch self {
        case .formal:
            "Formal: standard capitalization and full punctuation, polished but faithful wording."
        case .casual:
            "Casual: standard capitalization, lighter punctuation (a final period on a single sentence is optional)."
        case .veryCasual:
            "Very casual: all lowercase except proper nouns and \"I\", minimal punctuation, no trailing period."
        case .excited:
            "Excited: standard capitalization, upbeat tone with exclamation marks where natural."
        }
    }
}
