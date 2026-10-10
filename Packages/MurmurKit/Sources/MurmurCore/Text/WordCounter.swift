import Foundation

public enum WordCounter {
    /// Locale-aware word count (also works for languages without spaces, e.g. Japanese).
    /// Tokens without a letter or digit are skipped: the enumerator can yield bare spaces for
    /// some Cyrillic text. Hyphenated words ("кто-то") count as two, like the server does.
    public static func count(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords]) { substring, _, _, _ in
            if let substring, substring.contains(where: { $0.isLetter || $0.isNumber }) {
                count += 1
            }
        }
        return count
    }

    public static func wordsPerMinute(words: Int, seconds: Double) -> Int {
        guard seconds > 0.5 else { return 0 }
        return Int((Double(words) / seconds * 60).rounded())
    }
}
