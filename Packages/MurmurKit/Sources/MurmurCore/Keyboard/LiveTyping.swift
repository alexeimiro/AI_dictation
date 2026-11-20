import Foundation

/// The focused field as "Type as I speak" uses it: the keyboard's `textDocumentProxy`.
@MainActor
public protocol LiveTypingField: AnyObject {
    /// `documentContextBeforeInput`: the proxy's own running copy of the text before the cursor,
    /// which shows the keyboard's own edits at once.
    var contextBeforeCursor: String? { get }
    /// `selectedText`; nil or empty when nothing is selected.
    var selectedText: String? { get }
    /// Return would submit here (a search or address bar, a field whose Return key sends).
    var isSingleLine: Bool { get }
    func insertText(_ text: String)
    /// Removes the character before the cursor, or the selection when there is one.
    func deleteBackward()
}

/// "Type as I speak": while a dictation is recorded, the keyboard types its settled words into
/// the field as the previews bring them (`apply`), and the dictation's final text replaces them in
/// one step (`place`). The newest words, which may still change, stay on the keyboard.
///
/// It only ever adds to the end of what it typed, with plain insertions, and deletes only to
/// replace or remove its own words at the end, as its check finds them (what the check can't
/// see is below). Before every edit (a word added, the replacement, the removal) it checks that
/// the text before the cursor shows all of what it typed (`holds`). When it doesn't, it stops
/// typing for that dictation, and the final text is not put beside the raw words unasked
/// (`canPlace`): the keyboard holds it as "Insert last dictation". The person's tap on that card
/// replaces the words only where all of them show again; anywhere else the text goes in at the
/// cursor and the words stay, for the person to delete. Nothing is deleted where only a part of
/// the typed words shows. What it typed is written to the shared container first
/// (`LiveTypedRecord`), so a keyboard that iOS creates again can still replace it.
///
/// What the check can't see: it reads `contextBeforeCursor`, the text iOS gives the keyboard,
/// which is the keyboard's own copy until the app reports a change. Not reported (measured on
/// iOS 26.5): text an app inserts with its own code, in any field, and a web page's script
/// emptying an editable box or moving the cursor in any of its fields, as a page's Send button
/// would. There the words go on being typed, and at the end the deletions (one for each typed
/// character) and the whole final text land wherever the cursor really is. After such a Send the
/// next message's box gets the complete text. After text the app put in at the cursor, that text
/// is deleted and as many of the first typed letters stay in front of the final text. After a
/// cursor the page's script moved (any web field), the words typed before the move stay where
/// they were, and up to as many characters as were typed are deleted before the new cursor, the
/// person's own text among them. ✕ and a dictation that ends with nothing delete there too.
/// `place` is written for the emptied box: it deletes every typed character and inserts the
/// whole text, so there, where the deletions do nothing, the field still ends with the complete
/// text.
///
/// Counting is the care here. A preview's words are found in the dictation's settled text by
/// Unicode scalars, which neither side counts differently; deletions are counted in characters,
/// and only text whose characters a host deletes one at a time is typed at all (`isPlain`).
@MainActor
public final class LiveTyping {
    /// The most characters typed live for one dictation. Later words stay on the keyboard only,
    /// and come with the final text. It stays under the roughly 300 characters before the cursor
    /// that a host reports (measured on iOS 26.5), so what was typed can be found whole in them.
    public static let limit = 280

    /// The focused field. Without one nothing is typed.
    public weak var field: LiveTypingField?

    private let store: IPCPayloadStore
    private let isEnabled: () -> Bool
    private let clock: () -> Date
    /// The dictation this keyboard is armed for (nothing typed yet), or whose words it typed, or
    /// whose record a keyboard before it left.
    private var record: LiveTypedRecord?
    /// `record` may still grow: this keyboard armed it itself, and nothing has frozen it since.
    private var appends = false
    /// The store has been asked for a record that a keyboard before this one left.
    private var askedStore = false

    /// `isEnabled`: the switch is on, the plan has it and the keyboard can write to the shared
    /// container. Asked each time a dictation begins and before every word.
    public init(store: IPCPayloadStore, isEnabled: @escaping () -> Bool, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.isEnabled = isEnabled
        self.clock = clock
    }

    /// The dictation whose live-typed words are in a field, as far as this keyboard knows: its
    /// own, or the one a keyboard before it left a record of. Nil when nothing was typed, and
    /// once the words are replaced, removed or forgotten.
    public var typedRequestId: UUID? {
        if !askedStore {
            askedStore = true
            if record == nil { record = store.readLiveTyped() }
        }
        guard let record, !record.typed.isEmpty else { return nil }
        return record.requestId
    }

    /// Words typed live for some dictation are still in a field unreplaced, as this keyboard or
    /// the shared container knows it. The container is read each time: another keyboard object
    /// may have typed them since this one last looked (`typedRequestId` remembers one look).
    /// `begin` must not be called while this holds: it replaces the record those words are
    /// replaced by.
    public var hasTypedWords: Bool {
        if let record, !record.typed.isEmpty { return true }
        return store.readLiveTyped().map { !$0.typed.isEmpty } ?? false
    }

    /// Words may still be typed for `requestId`: `begin` armed it and nothing has frozen it.
    public func isTyping(_ requestId: UUID) -> Bool {
        appends && record?.requestId == requestId
    }

    // MARK: While the dictation is recorded

    /// Arms live typing for a dictation this keyboard follows from its start: one it started
    /// itself and listens to from its first word, or one the app began for it, whose first words
    /// it may be shown seconds in and all at once (`apply` types them as it does any, in one
    /// insertion). Nothing is typed or written yet. Whatever this keyboard held of another
    /// dictation is replaced, so the keyboard doesn't ask while words typed for one still wait in
    /// a field. It does nothing when the feature is off, for a translation (its words are in the
    /// wrong language), without a field, in a single-line field, or while text is selected
    /// (`refusal`).
    public func begin(_ requestId: UUID, translating: Bool, language: String?) {
        guard refusal(translating: translating) == nil else { return }
        record = LiveTypedRecord(requestId: requestId, language: language, updatedAt: clock())
        appends = true
        askedStore = true
    }

    /// Why `begin` would arm nothing here and now, in a word for the keyboard's log (never any of
    /// the field's text). Nil when it would arm.
    func refusal(translating: Bool) -> String? {
        guard isEnabled() else { return "off" }
        guard !translating else { return "translation" }
        guard let field else { return "no field" }
        guard !field.isSingleLine else { return "single line" }
        guard !Self.hasSelection(field) else { return "selection" }
        return nil
    }

    /// The dictation's words so far: types the settled ones that are new. Only for the dictation
    /// `begin` armed, and only until something freezes it: words that don't go on from the typed
    /// ones, text a host may not delete character by character, more than `limit` characters, a
    /// field that no longer shows all of what was typed before the cursor, or a record that
    /// couldn't be written.
    public func apply(_ preview: LivePreview) {
        guard appends, var next = record, next.requestId == preview.requestId else { return }
        guard isEnabled(), let field else { return freeze() }

        // Where the preview's settled words go on from the ones already taken. A gap (words that
        // were never seen) or a difference (not the same text any more) ends it.
        let incoming = Array(preview.settled.unicodeScalars)
        let overlap = next.settledConsumed - preview.settledStart
        guard preview.settledStart >= 0, overlap >= 0, overlap <= incoming.count,
              next.settledText.unicodeScalars.suffix(overlap).elementsEqual(incoming[..<overlap])
        else { return freeze() }
        guard overlap < incoming.count else { return }
        var added = String.UnicodeScalarView()
        added.append(contentsOf: incoming[overlap...])
        next.settledText += String(added)
        next.settledConsumed = preview.settledLength

        if next.typed.isEmpty {
            // The first word: the field as it is now, which may not be as it was at the tap.
            guard !field.isSingleLine, !Self.hasSelection(field) else { return freeze() }
            next.contextTail = Self.contextTail(of: field.contextBeforeCursor ?? "")
        }
        let target = TextJoiner.prepare(next.settledText, traits: InsertionTraits(
            contextBefore: next.contextTail, singleLine: false, language: next.language))
        // Append only: what is in the field stays as it is until the end.
        let typed = next.typed.unicodeScalars
        guard target.unicodeScalars.starts(with: typed) else { return freeze() }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: target.unicodeScalars.dropFirst(typed.count))
        let delta = String(rest)
        guard !delta.isEmpty else {
            // Nothing to show for it (a space): remembered, so the next words still go on from it.
            record = next
            return
        }
        // Checked on the whole text, where a new mark may have joined a character typed before,
        // and with the character the words follow: a mark that opens them would become part of
        // that character, which is the user's own.
        guard Self.isPlain(target),
              (next.contextTail + target).count == next.contextTail.count + target.count,
              target.count <= Self.limit else { return freeze() }
        guard next.typed.isEmpty || holds(next.typed) else { return freeze() }

        next.typed = target
        next.updatedAt = clock()
        // The record first: words in a field that no record knows of could never be replaced.
        do { try store.write(liveTyped: next) } catch { return freeze() }
        record = next
        field.insertText(delta)
    }

    /// The keyboard leaves the screen (its edits have no effect from there), or the focus leaves
    /// the field: no more words are added to this dictation, also after the keyboard is back.
    /// The words that are in the field are still replaced.
    public func suspend() {
        if appends { freeze() }
    }

    // MARK: When the dictation ends

    /// Whether `requestId`'s final text may go into the field without being asked for: nothing
    /// was typed for it, or the text before the cursor shows all of what was typed, so the final
    /// text replaces it. Otherwise the keyboard holds the result as "Insert last dictation".
    ///
    /// All of it, not its end: the replacement deletes every typed character. Where a host hands
    /// over less than was typed, the part it doesn't show may have changed, or the field be
    /// another one that happens to end alike.
    public func canPlace(_ requestId: UUID) -> Bool {
        guard let record = record(of: requestId), !record.typed.isEmpty else { return true }
        return holds(record.typed)
    }

    /// Replaces the words typed for `result`'s dictation with its final text, joined to the text
    /// that was before them: one deletion for each typed character, then the whole text in one
    /// insertion, at once. Returns the final text as it is in the field now.
    ///
    /// Nothing the two share is left standing, though they often begin alike. A host can have
    /// emptied the field without reporting it (measured: a web page's script clearing an
    /// editable box, as its Send button does); the deletions do nothing there, and the field
    /// must end with the complete text, not with the part that differs. A standard field takes
    /// the whole turn as one change either way.
    ///
    /// Nil when it placed nothing and the caller inserts the result at the cursor as ever: nothing
    /// was typed for this dictation, or the final text is empty (the typed words go), or the text
    /// before the cursor doesn't show all of the typed words. That last is the person's tap on
    /// "Insert last dictation" somewhere `canPlace` said no: the tap asks for the text, not for
    /// deletions nothing confirms, so the words stay beside it as text and their record goes.
    public func place(_ result: DictationResult) -> String? {
        guard let record = record(of: result.requestId) else { return nil }
        defer { clear(result.requestId) }
        guard !record.typed.isEmpty, let field, holds(record.typed) else { return nil }
        let final = TextJoiner.prepare(result.text, traits: InsertionTraits(
            contextBefore: record.contextTail, singleLine: false, language: result.language))
        for _ in 0..<record.typed.count { field.deleteBackward() }
        if !final.isEmpty { field.insertText(final) }
        return final.isEmpty ? nil : final
    }

    /// Takes the words typed for `requestId` out again: the cross, or a dictation that ended with
    /// nothing to insert. They go only while all of them show before the cursor, as for
    /// `canPlace`: every typed character is deleted, and a dictation that ends with nothing does
    /// it with no tap at all. Otherwise they stay, as ordinary text.
    public func discard(_ requestId: UUID) {
        guard let record = record(of: requestId) else { return }
        if !record.typed.isEmpty, let field, holds(record.typed) {
            for _ in 0..<record.typed.count { field.deleteBackward() }
        }
        clear(requestId)
    }

    /// A new dictation starts: whatever was typed for an earlier one stays as ordinary text.
    public func forget() {
        record = nil
        appends = false
        askedStore = true
        store.clearLiveTyped()
    }

    /// `requestId`'s words are ordinary text from here, and their record goes: its "Insert last
    /// dictation" card was put away, or it ended with nothing to insert too long ago to take
    /// words out of a field for. Another dictation's record is left alone.
    public func forget(_ requestId: UUID) {
        clear(requestId)
    }

    // MARK: Rules

    /// Text that is deleted exactly as it is counted: every character is one Unicode scalar, or a
    /// Latin, Greek or Cyrillic letter with combining accents (U+0300...U+036F), which hosts
    /// delete whole. Anything else is never typed live: an emoji made of several scalars, a joiner,
    /// a Hebrew point, an Arabic vowel sign, Thai and Devanagari marks, which a host deletes one
    /// mark at a time.
    public static func isPlain(_ text: String) -> Bool {
        text.allSatisfy { character in
            let scalars = character.unicodeScalars
            guard scalars.count > 1 else { return true }
            guard let base = scalars.first, isLatinGreekOrCyrillicLetter(base) else { return false }
            return scalars.dropFirst().allSatisfy { (0x0300...0x036F).contains($0.value) }
        }
    }

    private static func isLatinGreekOrCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF, // Latin
             0x0370...0x03FF, 0x1F00...0x1FFF, // Greek
             0x0400...0x052F:                  // Cyrillic
            break
        default:
            return false
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// What the joiner needs of the text before the cursor: its last character that isn't
    /// whitespace and the whitespace after it, 8 characters at most. No more of the user's own
    /// text than that goes into the record.
    static func contextTail(of context: String) -> String {
        guard let visible = context.lastIndex(where: { !$0.isWhitespace }) else {
            return String(context.suffix(8))
        }
        return String(context[visible]) + context[context.index(after: visible)...].suffix(7)
    }

    private static func hasSelection(_ field: LiveTypingField) -> Bool {
        !(field.selectedText ?? "").isEmpty
    }

    // MARK: State

    /// The one check, before every edit: the text before the cursor shows all of `typed`, at its
    /// end, and nothing is selected (a selection is what the next deletion would remove instead
    /// of a character).
    ///
    /// All of it, never its end alone. A host that hands over only a few characters says nothing
    /// of the typed words before them, which may have changed or be another field's text:
    /// deleting all of `typed` there would take what was never checked, the person's own text
    /// with it, and so not even their tap on "Insert last dictation" replaces on that; nor must
    /// words go in after so little. Until a host reports its own state the proxy shows everything
    /// the keyboard typed, so this costs nothing there. After it, a standard field's 300
    /// characters hold all of `limit`; a web page's field hands over about a sentence, and where
    /// that is less than was typed the final text waits as "Insert last dictation", its tap
    /// inserts at the cursor, and the cross leaves the words.
    private func holds(_ typed: String) -> Bool {
        guard let field, !Self.hasSelection(field) else { return false }
        return field.contextBeforeCursor?.hasSuffix(typed) ?? false
    }

    /// No more words for this dictation. What is in the field keeps its record, marked.
    private func freeze() {
        appends = false
        guard var frozen = record else { return }
        guard !frozen.typed.isEmpty else {
            record = nil
            return
        }
        frozen.frozen = true
        frozen.updatedAt = clock()
        record = frozen
        try? store.write(liveTyped: frozen)
    }

    /// `requestId`'s record: this keyboard's own, or the one in the store, which a keyboard
    /// before this one wrote and which is only ever replaced or removed, never added to.
    private func record(of requestId: UUID) -> LiveTypedRecord? {
        if let record, record.requestId == requestId { return record }
        guard let stored = store.readLiveTyped(), stored.requestId == requestId else { return nil }
        return stored
    }

    private func clear(_ requestId: UUID) {
        if record?.requestId == requestId {
            record = nil
            appends = false
        }
        if store.readLiveTyped()?.requestId == requestId { store.clearLiveTyped() }
    }
}
