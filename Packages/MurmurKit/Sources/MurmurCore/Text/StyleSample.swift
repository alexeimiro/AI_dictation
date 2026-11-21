import Foundation

/// The one sentence the Style screens show in every mode, and what Murmur writes from it. The
/// server's bench has the same sentence as its `screen.*` cases, so the examples can be checked
/// against the deployed model.
public enum StyleSample {
    /// What the user says: fillers, a grammar slip and a vague time, so every mode shows a change.
    public static let spoken = "um so me and him was thinking maybe we could like meet on friday at 4 if that works for you guys"

    /// What each mode writes from `spoken`: the deployed model's own output (Claude Haiku 5.5, live
    /// check of 2026-11-21 against cleanup v28–v30; Email's and Funny's prompts as deployed).
    public static func written(_ style: StylePreset) -> String {
        switch style {
        case .verbatim:
            "So, me and him was thinking maybe we could, like, meet on Friday at 4 if that works for you guys."
        case .rewrite:
            "He and I were thinking maybe we could meet on Friday at 4, if that works for you guys."
        case .email:
            "Hello,\n\nHe and I were thinking we could meet on Friday at 4, if that works for you all.\n\nBest regards,"
        case .funny:
            "He and I were thinking we could maybe hang out on Friday at 4, if that works for you guys! 🎉"
        }
    }
}
