import Foundation

/// What the keyboard's live words need to know about the script they are written in. The keyboard
/// itself is laid out left to right and sized for the system font, whatever language is spoken.
public enum LiveWordsScript {
    /// The words are written from the right (Arabic, Hebrew): any letter of such a script says so.
    /// Not the first letter alone, which is how the text system picks a paragraph's direction: the
    /// keyboard is shown only the end of a long dictation, and a name in Latin letters at the cut
    /// would move the lines to the other edge until the cut moved on.
    public static func readsRightToLeft(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            switch $0.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFC: true
            default: false
            }
        }
    }

    /// The words are Thai, which stacks a tone mark over a vowel and hangs vowels under a letter:
    /// taller than a line of the system font at the same size.
    public static func stacksMarks(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
    }
}
