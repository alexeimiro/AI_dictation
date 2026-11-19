import MurmurCore
import UIKit

/// The focused field as "Type as I speak" edits it (`LiveTyping`): the keyboard's
/// `textDocumentProxy`, asked anew each time. Plain insertions and deletions only, never marked
/// text: with marked text, Undo crashed host apps and a field with a length limit lost the
/// dictation (measured on iOS 26.5).
@MainActor
final class DocumentProxyField: LiveTypingField {
    private weak var keyboard: KeyboardViewController?

    init(keyboard: KeyboardViewController) {
        self.keyboard = keyboard
    }

    var contextBeforeCursor: String? { keyboard?.textDocumentProxy.documentContextBeforeInput }
    var selectedText: String? { keyboard?.textDocumentProxy.selectedText }
    /// A keyboard that is gone has no field to type into.
    var isSingleLine: Bool { keyboard?.isSingleLineField ?? true }

    func insertText(_ text: String) {
        keyboard?.textDocumentProxy.insertText(text)
    }

    func deleteBackward() {
        keyboard?.textDocumentProxy.deleteBackward()
    }
}
