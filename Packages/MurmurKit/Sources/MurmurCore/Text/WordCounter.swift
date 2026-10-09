import Foundation

public enum WordCounter {
    /// Locale-aware word count (also works for languages without spaces, e.g. Japanese).
    public static func count(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    public static func wordsPerMinute(words: Int, seconds: Double) -> Int {
        guard seconds > 0.5 else { return 0 }
        return Int((Double(words) / seconds * 60).rounded())
    }
}
