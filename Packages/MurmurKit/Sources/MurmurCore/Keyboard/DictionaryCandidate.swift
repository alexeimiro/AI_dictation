import Foundation

/// What the keyboard's ☰ menu offers to add to the dictionary: the selected text, else the word
/// just before the cursor (the one the user just typed or fixed). Nil when that doesn't fit a
/// dictionary entry. Pure, so it's tested here; the keyboard target has no tests.
public enum DictionaryCandidate {
    /// As the app's dictionary allows (`LibraryRules.maxWord`).
    public static let maxLength = 59

    public static func word(selected: String?, before: String?) -> String? {
        if let selected = selected?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            return fits(selected) ? selected : nil
        }
        guard let before else { return nil }
        let edges = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        let trimmed = before.trimmingCharacters(in: edges)
        let word = String(trimmed.reversed().prefix { !$0.isWhitespace && !$0.isNewline }.reversed())
            .trimmingCharacters(in: edges)
        return fits(word) && word.contains(where: \.isLetter) ? word : nil
    }

    static func fits(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxLength && !text.contains(where: \.isNewline)
    }
}
