import AppKit
import ApplicationServices
import MurmurCore
import os

/// Puts a dictation's text where the user is typing, in whichever app is in front: through the
/// clipboard and a ⌘V, the way the user would paste it, which every text field takes. The
/// clipboard's contents are put back only once the text has landed (or after `restoreDeadline`),
/// unless something else changed it meanwhile. Put back too early, the app pastes the user's old
/// clipboard instead: that happened once in testing (2026-11-16), into Murmur's own window.
///
/// In Murmur's own windows the text goes straight to the focused field: no clipboard, and no
/// Accessibility calls into its own process, which its main thread would have to answer.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        /// Pasted into the focused text field.
        case pasted
        /// No text field has focus: the text is left on the clipboard for the user to paste.
        case copied
    }

    /// The shortest wait before the clipboard is put back, and the longest when the field can't
    /// be read to see the text arrive. Electron apps read the clipboard asynchronously.
    static let restoreDelay: Duration = .milliseconds(350)
    static let restoreDeadline: Duration = .milliseconds(1500)
    /// Accessibility calls into another app give up after this, so a busy app can't stall us.
    static let axTimeout: Float = 0.5

    private static let logger = Logger(subsystem: "Murmur", category: "Insert")
    /// Clipboard managers skip items marked this way (nspasteboard.org).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// `language`: the dictation's, for how it joins the text before the cursor.
    /// `joining`: fit the text to what's before the cursor (off when it replaces a selection).
    static func insert(_ text: String, language: String?, joining: Bool = true) async -> Outcome {
        let target = NSWorkspace.shared.frontmostApplication
        if target?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return insertInOwnWindow(text, language: language)
        }
        let (focus, element) = target.map { focused(in: $0) } ?? (.none, nil)
        // Fitted to the text before the cursor, as the iPhone keyboard does: a space after a
        // word, lowercase when continuing a sentence, one line in a single-line field.
        let traits = InsertionTraits(
            contextBefore: element.flatMap(contextBefore), singleLine: element.map(isSingleLine) ?? false,
            language: language)
        let prepared = joining ? TextJoiner.prepare(text, traits: traits) : text
        guard !prepared.isEmpty else { return .pasted }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(prepared, forType: .string)

        guard focus != .none else {
            // Nothing to paste into: the text stays on the clipboard (not marked transient, so a
            // clipboard manager keeps it too).
            logger.info("No focused text field in \(target?.bundleIdentifier ?? "?", privacy: .public); copied")
            return .copied
        }
        pasteboard.setData(Data(), forType: transientType)
        let ours = pasteboard.changeCount
        let valueBefore = element.flatMap { string($0, kAXValueAttribute) }
        postPaste()
        await waitForPaste(of: prepared, into: element, valueBefore: valueBefore)
        if pasteboard.changeCount == ours {
            restore(saved, to: pasteboard)
        }
        return .pasted
    }

    /// Returns once the field's value shows the text (checked every 50 ms after `restoreDelay`),
    /// or at `restoreDeadline` when it doesn't change or can't be read.
    private static func waitForPaste(of text: String, into element: AXUIElement?, valueBefore: String?) async {
        let clock = ContinuousClock()
        let start = clock.now
        try? await Task.sleep(for: restoreDelay)
        guard let element, let valueBefore else {
            try? await Task.sleep(until: start + restoreDeadline, clock: clock)
            return
        }
        let probe = String(text.trimmingCharacters(in: .whitespaces).suffix(24))
        while clock.now - start < restoreDeadline {
            if let now = string(element, kAXValueAttribute), now != valueBefore, now.contains(probe) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        logger.notice("Couldn't see the pasted text arrive; putting the clipboard back after the deadline")
    }

    /// Murmur's own window (the try-it box, a note): straight into the focused text view.
    private static func insertInOwnWindow(_ text: String, language: String?) -> Outcome {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .copied
        }
        let caret = view.selectedRange().location
        let string = view.string as NSString
        let from = max(0, min(caret, string.length) - 200)
        let before = string.substring(with: NSRange(location: from, length: min(caret, string.length) - from))
        let prepared = TextJoiner.prepare(
            text, traits: InsertionTraits(contextBefore: before, singleLine: !view.isFieldEditor ? false : true,
                                          language: language))
        view.insertText(prepared, replacementRange: view.selectedRange())
        return .pasted
    }

    // MARK: Focus

    enum Focus: Equatable {
        /// A text field, text view or web text box has focus.
        case editable
        /// The app doesn't say (no Accessibility support): paste and hope, as a user would.
        case unknown
        /// Nothing that takes text has focus.
        case none
    }

    /// The focused element of `app` and whether it takes text.
    static func focused(in app: NSRunningApplication) -> (Focus, AXUIElement?) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, axTimeout)
        // Chromium and Electron apps (Slack, VS Code, Notion…) build their accessibility tree only
        // once an assistive app asks; without it their text boxes look like nothing has focus.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value)
        switch result {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (.unknown, nil) }
            let focused = value as! AXUIElement // swiftlint:disable:this force_cast
            AXUIElementSetMessagingTimeout(focused, axTimeout)
            return isEditable(focused) ? (.editable, focused) : (.none, nil)
        case .noValue, .attributeUnsupported:
            return (.none, nil)
        default:
            // .cannotComplete, .notImplemented, .apiDisabled…
            return (.unknown, nil)
        }
    }

    /// Up to 200 characters before the cursor (or the selection the paste will replace); nil
    /// when the field doesn't say.
    static func contextBefore(_ element: AXUIElement) -> String? {
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil } // swiftlint:disable:this force_cast
        let start = max(0, selection.location - 200)
        var before = CFRange(location: start, length: selection.location - start)
        guard before.length > 0 else { return "" }
        if let parameter = AXValueCreate(.cfRange, &before) {
            var text: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &text) == .success,
               let text = text as? String {
                return text
            }
        }
        // Some fields only give their whole value; AX ranges count UTF-16 units, as NSString does.
        guard let value = string(element, kAXValueAttribute) else { return nil }
        let whole = value as NSString
        let end = min(selection.location, whole.length)
        let from = max(0, end - 200)
        return whole.substring(with: NSRange(location: from, length: end - from))
    }

    /// A one-line field, where a newline would send or submit.
    static func isSingleLine(_ element: AXUIElement) -> Bool {
        ["AXTextField", "AXComboBox", "AXSearchField"].contains(string(element, kAXRoleAttribute) ?? "")
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        // Web text boxes and custom views: a settable value with a text selection.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            var range: AnyObject?
            return AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        }
        return false
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Paste

    /// ⌘V with no other modifier: the fn or ⌥ the user may still hold must not turn it into
    /// another command.
    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Clipboard

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(of pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type] = data }
            }
            return types
        }
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
