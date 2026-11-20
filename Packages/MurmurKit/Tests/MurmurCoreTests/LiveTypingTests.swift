import Foundation
import Testing
@testable import MurmurCore

/// A host app's text field as a keyboard reaches it: text with a cursor in it, perhaps a
/// selection, and a host that may hand over only the end of the text before the cursor. The
/// person, or the host, can move the cursor, put text in, select and clear behind the keyboard's
/// back. The host reports those changes, so the keyboard reads the field as it is, except the
/// ones named `Unseen`: after one of those the keyboard goes on reading its own copy
/// (`unseenCopy`), as measured on iOS 26.5.
@MainActor
final class FakeTextField: LiveTypingField {
    private(set) var before: String
    private(set) var after: String
    private(set) var selection = ""
    var isSingleLine = false
    /// The host hands over only this many characters before the cursor; nil, all of them.
    var contextWindow: Int?
    /// What the keyboard did.
    private(set) var insertions: [String] = []
    private(set) var deletions = 0
    /// Runs as each of the keyboard's edits arrives, before it takes effect.
    var beforeEdit: (() -> Void)?
    /// The text before the cursor as the keyboard is given it once the host has changed the field
    /// without reporting it: what stood there before, kept up only with the keyboard's own edits.
    /// Nil while the keyboard reads the field as it is, and again once the host reports a change.
    private(set) var unseenCopy: String?

    init(_ before: String = "", after: String = "") {
        self.before = before
        self.after = after
    }

    var text: String { before + selection + after }

    var contextBeforeCursor: String? {
        let shown = unseenCopy ?? before
        let context = contextWindow.map { String(shown.suffix($0)) } ?? shown
        return context.isEmpty ? nil : context
    }

    var selectedText: String? { selection.isEmpty ? nil : selection }

    func insertText(_ text: String) {
        beforeEdit?()
        insertions.append(text)
        selection = ""
        before += text
        unseenCopy?.append(text)
    }

    /// As measured on iOS 26.5: a selection goes whole; a Latin, Greek or Cyrillic letter goes
    /// with its accents; of any other character made of several scalars, only the last one goes.
    func deleteBackward() {
        beforeEdit?()
        deletions += 1
        if unseenCopy?.isEmpty == false { unseenCopy?.removeLast() }
        guard selection.isEmpty else {
            selection = ""
            return
        }
        guard let last = before.last else { return }
        if last.unicodeScalars.count > 1, let base = last.unicodeScalars.first, !Self.goesWhole(base) {
            var scalars = before.unicodeScalars
            scalars.removeLast()
            before = String(scalars)
        } else {
            before.removeLast()
        }
    }

    private static func goesWhole(_ base: Unicode.Scalar) -> Bool {
        switch base.value {
        case 0x0041...0x024F, 0x0370...0x052F, 0x1E00...0x1FFF: true
        default: false
        }
    }

    // MARK: The person, or the host app

    /// Puts the cursor after the first `offset` characters.
    func moveCursor(to offset: Int) {
        let whole = text
        unseenCopy = nil
        selection = ""
        before = String(whole.prefix(offset))
        after = String(whole.dropFirst(offset))
    }

    func moveCursorToEnd() { moveCursor(to: text.count) }

    /// The host puts text in at the cursor itself, and reports it.
    func hostInserts(_ text: String) {
        unseenCopy = nil
        before += text
    }

    /// A web page's script empties its editable box, as the page's Send button does. Nothing is
    /// reported: the keyboard still reads what it had typed.
    func pageEmptiesTheBoxUnseen() {
        unseenCopy = unseenCopy ?? before
        before = ""
        after = ""
        selection = ""
    }

    /// Selects the last `count` characters before the cursor.
    func selectLast(_ count: Int) {
        unseenCopy = nil
        selection = String(before.suffix(count)) + selection
        before = String(before.dropLast(count))
    }

    /// Selects the first `count` characters after the cursor.
    func selectNext(_ count: Int) {
        unseenCopy = nil
        selection += after.prefix(count)
        after = String(after.dropFirst(count))
    }

    func clear() { focusElsewhere("") }

    /// The focus moves to another field, which holds `before` and `after`.
    func focusElsewhere(_ before: String, after: String = "") {
        unseenCopy = nil
        self.before = before
        self.after = after
        selection = ""
    }
}

@MainActor
private final class Switch {
    var on = true
}

/// One dictation typed into one field as it is said.
@MainActor
private struct Dictation {
    let store: IPCPayloadStore
    let field: FakeTextField
    let enabled = Switch()
    let typing: LiveTyping
    let id = UUID()

    init(_ before: String = "", after: String = "", store: IPCPayloadStore = IPCPayloadStore(container: .temporary())) {
        self.store = store
        field = FakeTextField(before, after: after)
        typing = LiveTyping(store: store, isEnabled: { [enabled] in enabled.on })
        typing.field = field
    }

    func begin(translating: Bool = false, language: String? = nil) {
        typing.begin(id, translating: translating, language: language)
    }

    /// The app's preview: everything settled so far, and the newest words.
    func hear(_ settled: String, _ unsettled: String = "") {
        typing.apply(LivePreview(requestId: id, settled: settled, unsettled: unsettled))
    }

    func result(_ text: String, status: ResultStatus = .cleaned, language: String? = nil) -> DictationResult {
        DictationResult(requestId: id, documentIdentifier: nil, text: text, status: status, createdAt: Date(),
                        language: language)
    }

    var record: LiveTypedRecord? { store.readLiveTyped() }
}

private func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

@MainActor
struct LiveTypingTests {
    private static let english = """
        So I was thinking we could meet on Thursday afternoon instead, because the morning is already \
        full, and then go over the numbers before anyone else arrives.
        """.split(separator: " ").map(String.init)

    /// "й" and "ё" as a letter and a combining mark: two scalars that read, and are deleted, as one.
    private static let russian = """
        Я подумал, что мы могли бы встретиться в четверг после обеда, потому что утро уже занято, \
        а потом пройтись по цифрам до того, как придут остальные, и ещё раз всё проверить.
        """.decomposedStringWithCanonicalMapping.split(separator: " ").map(String.init)

    // MARK: While the dictation is recorded

    /// The words that have settled go into the field, each once. The newest words, which the
    /// recognizer may still rewrite, stay on the keyboard.
    @Test func onlyTheSettledWordsAreTyped() throws {
        let dictation = Dictation()
        dictation.begin()
        #expect(dictation.typing.isTyping(dictation.id))
        #expect(dictation.typing.typedRequestId == nil)

        dictation.hear("", "So I was")
        #expect(dictation.field.text == "")
        #expect(dictation.record == nil, "nothing is written before the first word goes in")

        dictation.hear("So I was", " thinking we")
        #expect(dictation.field.text == "So I was")
        dictation.hear("So I was thinking we", " could meet")
        #expect(dictation.field.text == "So I was thinking we")
        // The same settled words with other new ones: nothing to add.
        dictation.hear("So I was thinking we", " could meet on")
        #expect(dictation.field.insertions == ["So I was", " thinking we"])
        #expect(dictation.field.deletions == 0)

        #expect(dictation.typing.typedRequestId == dictation.id)
        let record = try #require(dictation.record)
        #expect(record.requestId == dictation.id)
        #expect(record.typed == "So I was thinking we")
        #expect(record.settledText == "So I was thinking we")
        #expect(record.settledConsumed == 20)
        #expect(record.contextTail == "")
        #expect(!record.frozen)
    }

    /// A dictation the app began for the keyboard has been recorded for a while when its first
    /// words come: the recognizer is given the audio so far once it is ready, and the first
    /// preview with words then holds many settled ones. They go in whole, in one insertion,
    /// joined to the text before them as it is then, and the typing goes on from there.
    @Test func theFirstPreviewSeenLateIsTypedWhole() throws {
        let heard = "So I was thinking we could meet on Thursday afternoon instead"
        let dictation = Dictation("Let's see.", after: "\nBest, A.")
        dictation.begin()
        // Words will come: the preview is empty for now.
        dictation.hear("")
        dictation.hear("", "So I")
        #expect(dictation.field.insertions.isEmpty)
        #expect(dictation.record == nil)
        #expect(dictation.typing.isTyping(dictation.id))

        dictation.hear(heard, " because the")
        #expect(dictation.field.text == "Let's see. " + heard + "\nBest, A.")
        #expect(dictation.field.insertions == [" " + heard])
        let record = try #require(dictation.record)
        #expect(record.typed == " " + heard)
        #expect(record.settledText == heard)
        #expect(record.settledConsumed == heard.unicodeScalars.count)
        #expect(record.contextTail == ".")
        dictation.hear(heard + " because the morning", " is full")
        #expect(dictation.field.insertions == [" " + heard, " because the morning"])
        #expect(dictation.typing.isTyping(dictation.id))

        // And the final text replaces all of it: a deletion for each character, one insertion.
        let final = "So I was thinking we could meet on Thursday afternoon instead, because the morning is full."
        #expect(dictation.typing.place(dictation.result(final)) == " " + final)
        #expect(dictation.field.text == "Let's see. " + final + "\nBest, A.")
        #expect(dictation.field.deletions == (" " + heard + " because the morning").count)
        #expect(dictation.record == nil)

        // The field as it is when they come, not as it was when the typing was armed.
        let moved = Dictation("Dear Anna,")
        moved.begin()
        moved.field.hostInserts(" as promised:")
        moved.hear("Here is the list")
        #expect(moved.field.text == "Dear Anna, as promised: Here is the list")
        #expect(moved.record?.contextTail == ":")

        // More than is ever typed live, all at once: none of it goes in.
        let long = Dictation("Hi. ")
        long.begin()
        long.hear(Array(repeating: "word", count: 60).joined(separator: " "))
        #expect(long.field.text == "Hi. ")
        #expect(!long.typing.isTyping(long.id))
        #expect(long.record == nil)
        #expect(long.typing.canPlace(long.id))
        #expect(long.typing.place(long.result("Word word.")) == nil)

        // Or only its end, the beginning having left the preview before this keyboard saw any.
        let cut = Dictation("Hi. ")
        cut.begin()
        let late = LivePreview.tail(requestId: cut.id,
                                    settled: Array(repeating: "word", count: 100).joined(separator: " "),
                                    unsettled: " and")
        #expect(late.settledStart > 0 && !late.settled.isEmpty)
        cut.typing.apply(late)
        #expect(cut.field.text == "Hi. ")
        #expect(!cut.typing.isTyping(cut.id))
        #expect(cut.record == nil)
        #expect(cut.typing.place(cut.result("Word word.")) == nil)
    }

    /// The words are fitted to the text before them as a finished dictation is: a space after a
    /// word, and no capital on a common word that continues a sentence.
    @Test func theWordsAreJoinedToTheTextBeforeThem() {
        let continuing = Dictation("Let's meet")
        continuing.begin()
        continuing.hear("And then", " we")
        #expect(continuing.field.text == "Let's meet and then")
        #expect(continuing.record?.typed == " and then")
        #expect(continuing.record?.contextTail == "t")
        continuing.hear("And then we talk.")
        #expect(continuing.field.text == "Let's meet and then we talk.")
        #expect(continuing.field.insertions == [" and then", " we talk."])

        let sentence = Dictation("Done. ")
        sentence.begin()
        sentence.hear("And then")
        #expect(sentence.field.text == "Done. And then")
        #expect(sentence.record?.contextTail == ". ")

        let russian = Dictation("Привет,")
        russian.begin(language: "ru-RU")
        russian.hear("Я думаю")
        #expect(russian.field.text == "Привет, я думаю")
        #expect(russian.record?.language == "ru-RU")

        // Chinese is written without spaces.
        let chinese = Dictation("今天")
        chinese.begin(language: "zh-CN")
        chinese.hear("下午我们")
        chinese.hear("下午我们一起去")
        #expect(chinese.field.text == "今天下午我们一起去")
    }

    /// Of the text before the cursor only what the joiner goes by is kept: its last character
    /// that isn't whitespace, and the whitespace after it.
    @Test func theRecordKeepsOnlyTheEndOfTheTextBeforeTheCursor() {
        #expect(LiveTyping.contextTail(of: "") == "")
        #expect(LiveTyping.contextTail(of: "Dear Anna,") == ",")
        #expect(LiveTyping.contextTail(of: "Dear Anna, ") == ", ")
        #expect(LiveTyping.contextTail(of: "Notes:\n\n") == ":\n\n")
        #expect(LiveTyping.contextTail(of: " \n") == " \n")
        // A long run of whitespace: its end, and still the character before it.
        let spaced = LiveTyping.contextTail(of: "list," + String(repeating: "\n", count: 20))
        #expect(spaced == "," + String(repeating: "\n", count: 7))
        #expect(LiveTyping.contextTail(of: String(repeating: " ", count: 20)).count == 8)
    }

    /// At most `limit` characters are typed for one dictation. The words past them stay on the
    /// keyboard, and the final text brings them.
    @Test func noMoreThanTheLimitIsTyped() throws {
        let dictation = Dictation("Hi. ")
        dictation.begin()
        var said: [String] = []
        var typedAtTheLimit: String?
        while said.joined(separator: " ").count < 600 {
            said.append(Self.english[said.count % Self.english.count])
            let settled = said.joined(separator: " ")
            dictation.hear(settled)
            if settled.count <= LiveTyping.limit {
                #expect(dictation.field.text == "Hi. " + settled)
                #expect(dictation.typing.isTyping(dictation.id))
            } else {
                typedAtTheLimit = typedAtTheLimit ?? dictation.record?.typed
                #expect(!dictation.typing.isTyping(dictation.id))
                #expect(dictation.record?.typed == typedAtTheLimit, "words were typed past the limit")
            }
        }
        let typed = try #require(typedAtTheLimit)
        #expect(typed.count <= LiveTyping.limit)
        #expect(typed.count > LiveTyping.limit - 12, "it stopped a word short of the limit at most")
        #expect(dictation.field.text == "Hi. " + typed)
        #expect(dictation.record?.frozen == true)
        #expect(dictation.field.deletions == 0)

        // The final text still replaces what is there.
        let final = said.joined(separator: " ") + "."
        #expect(dictation.typing.canPlace(dictation.id))
        #expect(dictation.typing.place(dictation.result(final)) == final)
        #expect(dictation.field.text == "Hi. " + final)
    }

    /// What a host may not delete character by character is never typed, so that taking the
    /// typed words out again is exact.
    @Test func plainTextIsWhatAHostDeletesACharacterAtATime() {
        #expect(LiveTyping.isPlain(""))
        #expect(LiveTyping.isPlain("So I was thinking, we could meet at 5 p.m. \u{2014} OK?"))
        #expect(LiveTyping.isPlain("Привет, как дела? Ёжик и йод."))
        #expect(LiveTyping.isPlain("Γειά σου, τι κάνεις;"))
        // Accents as combining marks on Latin, Cyrillic and Greek letters.
        #expect(LiveTyping.isPlain("cafe\u{0301} in Zu\u{0308}rich"))
        #expect(LiveTyping.isPlain("и\u{0306}од и е\u{0308}ж"))
        #expect(LiveTyping.isPlain("\u{03B1}\u{0301}"))
        #expect(LiveTyping.isPlain("o\u{0302}\u{0301}"))
        // One scalar to a character: Chinese, Korean syllables, Hebrew and Arabic without their
        // points, a simple emoji.
        #expect(LiveTyping.isPlain("今天下午我们一起去看电影"))
        #expect(LiveTyping.isPlain("\u{C548}\u{B155}\u{D558}\u{C138}\u{C694}"))
        #expect(LiveTyping.isPlain("\u{05E9}\u{05DC}\u{05D5}\u{05DD}"))
        #expect(LiveTyping.isPlain("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"))
        #expect(LiveTyping.isPlain("\u{1F600}"))

        // Emoji made of several scalars.
        #expect(!LiveTyping.isPlain("ok \u{1F44D}\u{1F3FD}"))
        #expect(!LiveTyping.isPlain("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"))
        #expect(!LiveTyping.isPlain("\u{1F1FA}\u{1F1F8}"))
        #expect(!LiveTyping.isPlain("1\u{FE0F}\u{20E3}"))
        #expect(!LiveTyping.isPlain("\u{2764}\u{FE0F}"))
        // Hebrew points, Arabic vowel signs, Thai and Devanagari marks.
        #expect(!LiveTyping.isPlain("\u{05E9}\u{05B8}\u{05DC}\u{05D5}\u{05DD}"))
        #expect(!LiveTyping.isPlain("\u{0645}\u{064E}\u{0631}\u{062D}\u{0628}\u{0627}"))
        #expect(!LiveTyping.isPlain("\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}"))
        #expect(!LiveTyping.isPlain("\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947}"))
        // Other marks on a Latin letter, an accent on something that isn't a letter, and a line
        // break of two scalars.
        #expect(!LiveTyping.isPlain("e\u{20DD}"))
        #expect(!LiveTyping.isPlain("5\u{0301}"))
        #expect(!LiveTyping.isPlain("a\r\nb"))
    }

    @Test func textThatIsNotPlainIsNeverTyped() {
        let dictation = Dictation()
        dictation.begin()
        dictation.hear("Hello")
        // Pointed Hebrew settles next: neither it nor anything after it is typed.
        let pointed = "Hello \u{05E9}\u{05B8}\u{05DC}\u{05D5}\u{05DD}"
        dictation.hear(pointed)
        #expect(dictation.field.text == "Hello")
        #expect(!dictation.typing.isTyping(dictation.id))
        dictation.hear(pointed + " and more")
        #expect(dictation.field.text == "Hello")
        #expect(dictation.field.insertions == ["Hello"])
        // The final text may hold anything: it is inserted, never counted back out.
        let final = pointed + " and more."
        #expect(dictation.typing.place(dictation.result(final)) == final)
        #expect(scalars(dictation.field.text) == scalars(final))

        // As the first words: nothing goes in, and nothing is written.
        let emoji = Dictation("Hi ")
        emoji.begin()
        emoji.hear("\u{1F44D}\u{1F3FD} great")
        emoji.hear("\u{1F44D}\u{1F3FD} great idea")
        #expect(emoji.field.text == "Hi ")
        #expect(emoji.record == nil)
        #expect(emoji.typing.typedRequestId == nil)
        #expect(emoji.typing.place(emoji.result("Great idea")) == nil)
    }

    /// An accent can settle after its letter. It joins the letter in the field as it does in the
    /// text, and the two are counted, and deleted, as the one character they are.
    @Test func anAccentThatSettlesAfterItsLetterJoinsIt() {
        let dictation = Dictation("Order: ")
        dictation.begin()
        dictation.hear("cafe")
        dictation.hear("cafe\u{0301} au lait")
        #expect(dictation.field.insertions == ["cafe", "\u{0301} au lait"])
        #expect(scalars(dictation.field.text) == scalars("Order: cafe\u{0301} au lait"))
        #expect(dictation.record?.typed.count == 12)

        dictation.typing.discard(dictation.id)
        #expect(dictation.field.text == "Order: ")
        #expect(dictation.field.deletions == 12)
    }

    /// A mark that opens the dictation would join the character before the cursor, which is the
    /// user's own: deleting the typed words would then take it along.
    @Test func aMarkThatWouldJoinTheTextBeforeItIsNotTyped() {
        let dictation = Dictation("(")
        dictation.begin()
        dictation.hear("\u{0301}x and more")
        #expect(dictation.field.text == "(")
        #expect(!dictation.typing.isTyping(dictation.id))
        #expect(dictation.record == nil)
    }

    /// The preview's settled words must go on from the ones that were typed. Words that were
    /// never seen in between, or settled words that changed after all, end the typing.
    @Test func aGapOrAChangeInTheSettledWordsStopsTheTyping() {
        let gap = Dictation()
        gap.begin()
        gap.hear("One two")
        // The end of a long text whose middle this keyboard never saw.
        gap.typing.apply(LivePreview(requestId: gap.id, settled: "nine ten", settledLength: 40))
        #expect(gap.field.text == "One two")
        #expect(!gap.typing.isTyping(gap.id))
        #expect(gap.record?.frozen == true)
        // Nor does a preview that would have gone on start it again.
        gap.hear("One two three")
        #expect(gap.field.text == "One two")

        let changed = Dictation()
        changed.begin()
        changed.hear("One two")
        changed.hear("One too many")
        #expect(changed.field.text == "One two")
        #expect(!changed.typing.isTyping(changed.id))

        // The recognizer began again: less is settled than was typed.
        let shorter = Dictation()
        shorter.begin()
        shorter.hear("One two three")
        shorter.hear("One")
        shorter.hear("One two three four")
        #expect(shorter.field.text == "One two three")
        #expect(!shorter.typing.isTyping(shorter.id))

        // A count that can't be right.
        let wrong = Dictation()
        wrong.begin()
        wrong.typing.apply(LivePreview(requestId: wrong.id, settled: "One two", settledLength: 3))
        #expect(wrong.field.text == "")
        #expect(!wrong.typing.isTyping(wrong.id))

        // Another dictation's words are not this one's business.
        let other = Dictation()
        other.begin()
        other.hear("One")
        other.typing.apply(LivePreview(requestId: UUID(), settled: "Somebody else's words"))
        other.hear("One two")
        #expect(other.field.text == "One two")
    }

    /// A long dictation's preview is only its end (`LivePreview.tail`). The typed words are found
    /// in it by scalars, which a letter with a combining accent has two of.
    @Test func wordsGoOnFromAPreviewThatWasCut() {
        for vocabulary in [Self.english, Self.russian] {
            let dictation = Dictation()
            dictation.begin()
            // Many unsettled words, so the preview is cut while few are settled.
            let unsettled = " " + Array(repeating: "still changing", count: 13).joined(separator: " ")
            var settled = ""
            var cuts = 0
            for word in vocabulary + vocabulary {
                let longer = settled.isEmpty ? word : settled + " " + word
                guard longer.count <= LiveTyping.limit else { break }
                settled = longer
                let preview = LivePreview.tail(requestId: dictation.id, settled: settled, unsettled: unsettled)
                if preview.settledStart > 0, !preview.settled.isEmpty { cuts += 1 }
                dictation.typing.apply(preview)
                #expect(scalars(dictation.field.text) == scalars(settled))
            }
            #expect(cuts > 5, "the preview was cut \(cuts) times")
            #expect(settled.count > LiveTyping.limit - 20)
            #expect(dictation.typing.isTyping(dictation.id))
            #expect(dictation.record?.settledConsumed == settled.unicodeScalars.count)

            // And every character typed is deleted again, one deletion each.
            dictation.typing.discard(dictation.id)
            #expect(dictation.field.text == "")
            #expect(dictation.field.deletions == settled.count)
        }
        #expect(Self.russian.joined().unicodeScalars.count > Self.russian.joined().count)
    }

    /// Whenever the text before the cursor is no longer what was typed, the typing stops for
    /// this dictation, and doesn't start again.
    @Test func aFieldThatChangedStopsTheTyping() {
        let moved = Dictation("Dear Anna, ")
        moved.begin()
        moved.hear("I will be late")
        #expect(moved.field.text == "Dear Anna, I will be late")
        moved.field.moveCursor(to: 4)
        moved.hear("I will be late today")
        #expect(moved.field.text == "Dear Anna, I will be late")
        #expect(!moved.typing.isTyping(moved.id))
        #expect(moved.record?.frozen == true)
        // Not when the cursor is back at the end either.
        moved.field.moveCursorToEnd()
        moved.hear("I will be late today and tomorrow")
        #expect(moved.field.text == "Dear Anna, I will be late")
        #expect(moved.field.insertions == ["I will be late"])

        // The host put something in itself before the next word.
        let completed = Dictation()
        completed.begin()
        completed.hear("See you at")
        completed.field.hostInserts(" @Anna")
        completed.hear("See you at five")
        #expect(completed.field.text == "See you at @Anna")
        #expect(!completed.typing.isTyping(completed.id))

        // The message was sent: the field is empty.
        let sent = Dictation("Hi. ")
        sent.begin()
        sent.hear("On my way")
        sent.field.clear()
        sent.hear("On my way now")
        #expect(sent.field.text == "")
        #expect(!sent.typing.isTyping(sent.id))

        // The user selected some of it: the next insertion would replace the selection.
        let selected = Dictation()
        selected.begin()
        selected.hear("On my way")
        selected.field.selectLast(3)
        selected.hear("On my way now")
        #expect(selected.field.text == "On my way")
        #expect(selected.field.selectedText == "way")
        #expect(!selected.typing.isTyping(selected.id))

        // Or what follows it: the text before the cursor is as it was, but an edit would take
        // the selection first.
        let following = Dictation("Hi. ", after: " Best, A.")
        following.begin()
        following.hear("On my way")
        following.field.selectNext(6)
        #expect(following.field.contextBeforeCursor == "Hi. On my way")
        following.hear("On my way now")
        #expect(following.field.text == "Hi. On my way Best, A.")
        #expect(!following.typing.isTyping(following.id))
        #expect(!following.typing.canPlace(following.id))
        following.typing.discard(following.id)
        #expect(following.field.text == "Hi. On my way Best, A.")
        #expect(following.field.selectedText == " Best,")
        #expect(following.field.deletions == 0)
    }

    /// Off screen the keyboard's edits have no effect, so leaving ends the typing for this
    /// dictation. What was typed is still replaced.
    @Test func leavingTheScreenStopsTheTyping() {
        let dictation = Dictation("Hi. ")
        dictation.begin()
        dictation.hear("So I was")
        dictation.typing.suspend()
        #expect(!dictation.typing.isTyping(dictation.id))
        #expect(dictation.record?.frozen == true)
        #expect(dictation.record?.typed == "So I was")
        dictation.hear("So I was thinking")
        #expect(dictation.field.text == "Hi. So I was")
        #expect(dictation.typing.typedRequestId == dictation.id)
        #expect(dictation.typing.place(dictation.result("So I was thinking.")) == "So I was thinking.")
        #expect(dictation.field.text == "Hi. So I was thinking.")

        // Left before the first word: nothing is typed afterwards, and there is nothing to replace.
        let early = Dictation("Hi. ")
        early.begin()
        early.typing.suspend()
        early.hear("So I was")
        #expect(early.field.text == "Hi. ")
        #expect(early.record == nil)
        #expect(early.typing.canPlace(early.id))
        #expect(early.typing.place(early.result("So I was thinking.")) == nil)
    }

    /// A field or a dictation that the feature is not for: nothing is typed and nothing written.
    @Test func nothingIsTypedWhereItDoesNotBelong() {
        func typesNothing(_ dictation: Dictation, _ why: Comment) {
            dictation.hear("Hello there")
            dictation.hear("Hello there and more")
            #expect(!dictation.typing.isTyping(dictation.id), why)
            #expect(dictation.field.insertions.isEmpty, why)
            #expect(dictation.field.deletions == 0, why)
            #expect(dictation.record == nil, why)
            #expect(dictation.typing.canPlace(dictation.id), why)
            #expect(dictation.typing.place(dictation.result("Hello there.")) == nil, why)
        }

        // Each with the word the keyboard's log has for it (`refusal`).
        let translating = Dictation()
        translating.begin(translating: true)
        typesNothing(translating, "Translate")
        #expect(translating.typing.refusal(translating: true) == "translation")
        #expect(translating.typing.refusal(translating: false) == nil)

        let search = Dictation()
        search.field.isSingleLine = true
        search.begin()
        typesNothing(search, "a search or address bar")
        #expect(search.typing.refusal(translating: false) == "single line")

        let selected = Dictation("Replace this")
        selected.field.selectLast(4)
        selected.begin()
        typesNothing(selected, "text is selected")
        #expect(selected.field.selectedText == "this")
        #expect(selected.typing.refusal(translating: false) == "selection")

        let off = Dictation()
        off.enabled.on = false
        off.begin()
        typesNothing(off, "the feature is off")
        #expect(off.typing.refusal(translating: false) == "off")

        let noField = Dictation()
        noField.typing.field = nil
        noField.begin()
        typesNothing(noField, "no field")
        #expect(noField.typing.refusal(translating: false) == "no field")

        // Never begun (a dictation the keyboard came back to): previews alone type nothing.
        let unarmed = Dictation()
        typesNothing(unarmed, "not begun")

        // The field became another one before the first word.
        let single = Dictation()
        single.begin()
        single.field.isSingleLine = true
        typesNothing(single, "a search bar by the first word")

        let selectedLater = Dictation("Replace this")
        selectedLater.begin()
        selectedLater.field.selectLast(4)
        typesNothing(selectedLater, "selected by the first word")
        #expect(selectedLater.field.selectedText == "this")
    }

    /// The keyboard's condition (`SharedSettings.typesAsSpoken`): the switch in Settings, on a
    /// plan that has the feature, with Full Access. Asked each time, so a plan that ends stops the
    /// typing where it is.
    @Test func itTypesOnlyWithTheSwitchOnAndOnPro() throws {
        let suite = "test.murmur.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        #expect(!settings.liveTyping, "off until the user turns it on")
        #expect(!settings.planIsPro, "Basic until the app has read the plan")

        func dictate(_ words: String...) -> (field: FakeTextField, typing: LiveTyping, id: UUID) {
            let field = FakeTextField()
            let typing = LiveTyping(store: IPCPayloadStore(container: .temporary()),
                                    isEnabled: { settings.typesAsSpoken(fullAccess: true) })
            typing.field = field
            let id = UUID()
            typing.begin(id, translating: false, language: nil)
            for settled in words { typing.apply(LivePreview(requestId: id, settled: settled)) }
            return (field, typing, id)
        }

        #expect(dictate("Hello", "Hello there").field.text == "")
        settings.liveTyping = true
        #expect(dictate("Hello", "Hello there").field.text == "", "Basic")
        settings.liveTyping = false
        settings.planIsPro = true
        #expect(dictate("Hello", "Hello there").field.text == "", "the switch is off")
        settings.liveTyping = true
        #expect(SharedSettings(defaults: defaults).liveTyping && SharedSettings(defaults: defaults).planIsPro)
        #expect(settings.typesAsSpoken(fullAccess: true))
        #expect(!settings.typesAsSpoken(fullAccess: false), "without Full Access the record can't be kept")
        let typed = dictate("Hello", "Hello there")
        #expect(typed.field.text == "Hello there")

        // The trial ended while the dictation ran.
        settings.planIsPro = false
        typed.typing.apply(LivePreview(requestId: typed.id, settled: "Hello there and more"))
        #expect(typed.field.text == "Hello there")
        #expect(!typed.typing.isTyping(typed.id))
        #expect(typed.typing.canPlace(typed.id), "what is there is still replaced")

        // Or its end came, with nobody there to read the plan again (`planIsProUntil`).
        settings.planIsPro = true
        settings.planIsProUntil = Date().addingTimeInterval(3600)
        let onTrial = dictate("Hello")
        #expect(onTrial.field.text == "Hello")
        settings.planIsProUntil = Date().addingTimeInterval(-1)
        onTrial.typing.apply(LivePreview(requestId: onTrial.id, settled: "Hello there"))
        #expect(onTrial.field.text == "Hello")
        #expect(!onTrial.typing.isTyping(onTrial.id))
        #expect(dictate("Hello", "Hello there").field.text == "", "the trial is over")
    }

    /// Words in a field that no record knows of could never be replaced: the record is written
    /// first, and when it can't be (no Full Access), nothing is typed.
    @Test func theRecordIsWrittenBeforeTheWordsGoIn() throws {
        let dictation = Dictation("Hi. ")
        dictation.begin()
        var recorded: [String?] = []
        dictation.field.beforeEdit = { [store = dictation.store] in recorded.append(store.readLiveTyped()?.typed) }
        dictation.hear("So I")
        dictation.hear("So I was")
        #expect(recorded == ["So I", "So I was"])

        // It is there until the final text has replaced the words (a deletion for each of their
        // characters, and the insertion), then gone.
        recorded = []
        #expect(dictation.typing.place(dictation.result("So I was thinking.")) == "So I was thinking.")
        #expect(recorded == Array(repeating: "So I was", count: "So I was".count + 1))
        #expect(dictation.record == nil)
        #expect(dictation.typing.typedRequestId == nil)

        // A container the keyboard can't write to.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let unwritable = IPCPayloadStore(container: SharedContainer(rootURL: file.appendingPathComponent("IPC")))
        let denied = Dictation(store: unwritable)
        denied.begin()
        denied.hear("Hello there")
        #expect(denied.field.text == "")
        #expect(!denied.typing.isTyping(denied.id))
        #expect(denied.typing.typedRequestId == nil)
    }

    // MARK: When the dictation ends

    /// The final text takes the place of exactly what was typed, wherever in the text that is,
    /// and the cursor ends after it.
    @Test func theFinalTextReplacesTheTypedWords() {
        let dictation = Dictation("Notes:\n", after: "\nThe end.")
        dictation.begin()
        dictation.hear("so i was thinking we could meet", " on thursday")
        #expect(dictation.field.text == "Notes:\nso i was thinking we could meet\nThe end.")

        let final = "So I was hoping we could meet on Thursday."
        #expect(dictation.typing.canPlace(dictation.id))
        #expect(dictation.typing.place(dictation.result(final)) == final)
        #expect(dictation.field.text == "Notes:\n" + final + "\nThe end.")
        #expect(dictation.field.before == "Notes:\n" + final)
        // One deletion for each character typed, then the text in one insertion.
        #expect(dictation.field.deletions == "so i was thinking we could meet".count)
        #expect(dictation.field.insertions == ["so i was thinking we could meet", final])
        #expect(dictation.record == nil)
        #expect(dictation.typing.typedRequestId == nil)
        // Its result has been placed: a second time finds nothing typed.
        #expect(dictation.typing.place(dictation.result(final)) == nil)
        #expect(dictation.field.text == "Notes:\n" + final + "\nThe end.")
    }

    /// Where the final text begins as the typed words do, that beginning is not left standing:
    /// every typed character is deleted and the whole text written, so the field ends with all
    /// of it also where the deletions found nothing to delete (`aBoxEmptiedUnseen...`).
    @Test func theFinalTextIsWrittenWholeAlsoWhereItBeginsAsTheTypedWordsDo() {
        let dictation = Dictation("Hi. ")
        dictation.begin()
        dictation.hear("So I was thinking we could meet")
        let final = "So I was hoping we could meet on Thursday."
        #expect(dictation.typing.place(dictation.result(final)) == final)
        #expect(dictation.field.text == "Hi. " + final)
        #expect(dictation.field.deletions == "So I was thinking we could meet".count)
        #expect(dictation.field.insertions.last == final)

        // Nothing differs: the same words go and come.
        let same = Dictation()
        same.begin()
        same.hear("All good")
        #expect(same.typing.place(same.result("All good")) == "All good")
        #expect(same.field.text == "All good")
        #expect(same.field.deletions == "All good".count)
        #expect(same.field.insertions == ["All good", "All good"])

        // The final text is the shorter one.
        let shorter = Dictation()
        shorter.begin()
        shorter.hear("All good I think")
        #expect(shorter.typing.place(shorter.result("All good")) == "All good")
        #expect(shorter.field.text == "All good")
        #expect(shorter.field.deletions == "All good I think".count)
        #expect(shorter.field.insertions == ["All good I think", "All good"])

        // Mid-sentence, the final text is joined as the typed words were.
        let continuing = Dictation("Let's meet", after: " Bye.")
        continuing.begin()
        continuing.hear("And then we talk")
        #expect(continuing.typing.place(continuing.result("And then we talk at five.")) == " and then we talk at five.")
        #expect(continuing.field.text == "Let's meet and then we talk at five. Bye.")
        #expect(continuing.field.deletions == " and then we talk".count)
        #expect(continuing.field.insertions.last == " and then we talk at five.")

        // The same letters in another spelling (one scalar for "é", not two).
        let accented = Dictation()
        accented.begin()
        accented.hear("cafe\u{0301} au lait")
        #expect(accented.typing.place(accented.result("caf\u{00E9} au lait")) == "caf\u{00E9} au lait")
        #expect(scalars(accented.field.text) == scalars("caf\u{00E9} au lait"))
    }

    /// What the check can't see (measured on iOS 26.5): a web page's script empties its editable
    /// box, as the page's Send button does, and reports nothing, so the keyboard goes on reading
    /// its own copy of the words. They go on being typed, into the emptied box, and the final
    /// text is placed there: all of it, because the deletions in an empty box do nothing.
    @Test func aBoxEmptiedUnseenEndsWithTheWholeFinalText() {
        let final = "So I was hoping we could meet on Thursday."

        // Sent while the keyboard still listens.
        let listening = Dictation()
        listening.begin()
        listening.hear("So I was thinking we could meet")
        listening.field.pageEmptiesTheBoxUnseen()
        #expect(listening.field.text == "")
        #expect(listening.field.contextBeforeCursor == "So I was thinking we could meet")
        listening.hear("So I was thinking we could meet on Thursday")
        #expect(listening.field.text == " on Thursday", "the next words go into the next message's box")
        #expect(listening.typing.isTyping(listening.id))
        #expect(listening.typing.canPlace(listening.id))
        #expect(listening.typing.place(listening.result(final)) == final)
        #expect(listening.field.text == final)
        #expect(listening.field.deletions == "So I was thinking we could meet on Thursday".count)
        #expect(listening.field.insertions.last == final)

        // Sent while the text is written.
        let writing = Dictation()
        writing.begin()
        writing.hear("So I was thinking we could meet")
        writing.field.pageEmptiesTheBoxUnseen()
        #expect(writing.typing.canPlace(writing.id))
        #expect(writing.typing.place(writing.result(final)) == final)
        #expect(writing.field.text == final)

        // A clear the host reports (a standard field, a web page's textarea) is seen: the typing
        // stops, and the final text waits to be asked for.
        let reported = Dictation()
        reported.begin()
        reported.hear("So I was thinking we could meet")
        reported.field.clear()
        reported.hear("So I was thinking we could meet on Thursday")
        #expect(reported.field.text == "")
        #expect(!reported.typing.isTyping(reported.id))
        #expect(!reported.typing.canPlace(reported.id))
    }

    /// Words typed without a language (the keyboard knew none to give) are joined by English
    /// rules; the final text knows its language and is joined by it.
    @Test func theFinalTextIsJoinedByItsOwnLanguage() {
        let dictation = Dictation("Привет,")
        dictation.begin()
        dictation.hear("Я думаю")
        #expect(dictation.field.text == "Привет, Я думаю")
        let placed = dictation.typing.place(dictation.result("Я думаю, что да.", language: "ru-RU"))
        #expect(placed == " я думаю, что да.")
        #expect(dictation.field.text == "Привет, я думаю, что да.")
    }

    /// When the field no longer ends with the typed words, the final text is not put beside them
    /// unasked: `canPlace` says no, and the keyboard holds the result as "Insert last dictation".
    /// The record stays, so the user's tap replaces the words once the cursor is back after them.
    @Test func theFinalTextWaitsWhenTheFieldChangedAndReplacesOnceItMatchesAgain() {
        let dictation = Dictation("Dear Anna, ", after: "\nBest, A.")
        dictation.begin()
        dictation.hear("I will be late")
        dictation.field.moveCursor(to: 4)
        dictation.hear("I will be late today")
        #expect(!dictation.typing.canPlace(dictation.id))
        #expect(dictation.record?.typed == "I will be late")
        #expect(dictation.typing.typedRequestId == dictation.id)

        dictation.field.moveCursor(to: "Dear Anna, I will be late".count)
        #expect(dictation.typing.canPlace(dictation.id))
        #expect(dictation.typing.place(dictation.result("I'll be late today.")) == "I'll be late today.")
        #expect(dictation.field.text == "Dear Anna, I'll be late today.\nBest, A.")
        #expect(dictation.record == nil)
    }

    /// The user taps "Insert last dictation" with the cursor somewhere else: the text goes in
    /// there, as any dictation's does, and the typed words stay as the text they have become.
    @Test func placedElsewhereTheTypedWordsStayAsText() {
        let dictation = Dictation("Dear Anna, ")
        dictation.begin()
        dictation.hear("I will be late")
        dictation.field.moveCursor(to: 4)
        #expect(!dictation.typing.canPlace(dictation.id))
        #expect(dictation.typing.place(dictation.result("I'll be late today.")) == nil)
        #expect(dictation.field.text == "Dear Anna, I will be late")
        #expect(dictation.field.deletions == 0)
        #expect(dictation.record == nil)
        #expect(dictation.typing.typedRequestId == nil)
        #expect(dictation.typing.canPlace(dictation.id), "nothing is typed for it any more")
    }

    /// The cross takes the words out again, and leaves the text around them as it was.
    @Test func discardingDeletesTheTypedWords() {
        let dictation = Dictation("Dear Anna,", after: "\nBest, A.")
        dictation.begin()
        dictation.hear("I will be late", " today")
        #expect(dictation.field.text == "Dear Anna, I will be late\nBest, A.")
        dictation.typing.discard(dictation.id)
        #expect(dictation.field.text == "Dear Anna,\nBest, A.")
        #expect(dictation.field.deletions == " I will be late".count)
        #expect(dictation.record == nil)
        #expect(dictation.typing.typedRequestId == nil)
        #expect(!dictation.typing.isTyping(dictation.id))
        // And no later preview brings them back.
        dictation.hear("I will be late today")
        #expect(dictation.field.text == "Dear Anna,\nBest, A.")

        // Somewhere the words can't be found, they are left alone.
        let moved = Dictation("Dear Anna, ")
        moved.begin()
        moved.hear("I will be late")
        moved.field.moveCursor(to: 4)
        moved.typing.discard(moved.id)
        #expect(moved.field.text == "Dear Anna, I will be late")
        #expect(moved.field.deletions == 0)
        #expect(moved.record == nil)

        // Another dictation's cross is not this one's.
        let other = Dictation()
        other.begin()
        other.hear("Keep me")
        other.typing.discard(UUID())
        #expect(other.field.text == "Keep me")
        #expect(other.record?.typed == "Keep me")
    }

    /// A final text with nothing in it leaves nothing: the typed words go.
    @Test func aFinalTextThatIsEmptyRemovesTheTypedWords() {
        let dictation = Dictation("Hi. ")
        dictation.begin()
        dictation.hear("um")
        #expect(dictation.typing.place(dictation.result(" \n")) == nil)
        #expect(dictation.field.text == "Hi. ")
        #expect(dictation.record == nil)
    }

    /// When the next dictation starts, what was typed for the one before is ordinary text.
    @Test func forgettingLeavesTheWordsAsText() {
        let dictation = Dictation()
        dictation.begin()
        dictation.hear("So I was")
        dictation.typing.forget()
        #expect(dictation.record == nil)
        #expect(dictation.typing.typedRequestId == nil)
        #expect(!dictation.typing.isTyping(dictation.id))
        dictation.hear("So I was thinking")
        #expect(dictation.field.text == "So I was")
        #expect(dictation.typing.canPlace(dictation.id))
        #expect(dictation.typing.place(dictation.result("So I was thinking.")) == nil)
        #expect(dictation.field.text == "So I was")
    }

    /// iOS may end the keyboard and create it again while a dictation runs. The new one finds
    /// the record: it adds no words to it, and the final text still replaces what is there.
    @Test func aKeyboardCreatedAgainReplacesButNeverTypes() {
        let first = Dictation("Hi. ")
        first.begin()
        first.hear("So I was thinking")

        let again = LiveTyping(store: first.store, isEnabled: { true })
        again.field = first.field
        #expect(again.typedRequestId == first.id)
        #expect(!again.isTyping(first.id))
        again.apply(LivePreview(requestId: first.id, settled: "So I was thinking we could"))
        #expect(first.field.text == "Hi. So I was thinking")
        #expect(again.canPlace(first.id))
        #expect(again.place(first.result("So I was thinking we could meet.")) == "So I was thinking we could meet.")
        #expect(first.field.text == "Hi. So I was thinking we could meet.")
        #expect(first.store.readLiveTyped() == nil)
        #expect(again.typedRequestId == nil)

        // Or takes it out.
        let crossed = Dictation("Hi. ")
        crossed.begin()
        crossed.hear("So I was thinking")
        let other = LiveTyping(store: crossed.store, isEnabled: { true })
        other.field = crossed.field
        other.discard(crossed.id)
        #expect(crossed.field.text == "Hi. ")
        #expect(crossed.store.readLiveTyped() == nil)

        // In a field that is not the one the words are in, the result waits to be asked for.
        let elsewhere = Dictation("Hi. ")
        elsewhere.begin()
        elsewhere.hear("So I was thinking")
        let third = LiveTyping(store: elsewhere.store, isEnabled: { true })
        let another = FakeTextField("Something else")
        third.field = another
        #expect(!third.canPlace(elsewhere.id))
        #expect(elsewhere.store.readLiveTyped() != nil)
        #expect(third.place(elsewhere.result("So I was thinking.")) == nil)
        #expect(another.text == "Something else")
        #expect(elsewhere.store.readLiveTyped() == nil)
    }

    /// A host that reports its own state hands the keyboard only the end of a long text (a web
    /// page: about a sentence). The end of the typed words is then all the keyboard can see of
    /// them, and that is enough for nothing: by itself the final text doesn't go in, the
    /// person's tap on "Insert last dictation" replaces nothing (the keyboard then inserts the
    /// text at the cursor, beside the words), and the cross leaves the words.
    @Test func whereOnlyTheEndOfTheTypedWordsShowsTheTextWaitsForATap() {
        let dictation = Dictation("A long letter. ")
        dictation.begin()
        dictation.hear("So I was thinking. We could meet")
        dictation.field.contextWindow = 13
        #expect(dictation.field.contextBeforeCursor == "We could meet")
        #expect(!dictation.typing.canPlace(dictation.id), "not by itself")
        #expect(dictation.field.deletions == 0)
        #expect(dictation.record?.typed == "So I was thinking. We could meet", "the record waits for the tap")
        // The tap on the card: nothing is replaced, and the words are text from here.
        #expect(dictation.typing.place(dictation.result("So I was thinking we could meet on Thursday.")) == nil)
        #expect(dictation.field.text == "A long letter. So I was thinking. We could meet")
        #expect(dictation.field.deletions == 0)
        #expect(dictation.record == nil)
        #expect(dictation.typing.typedRequestId == nil)

        // The cross leaves them where they are, as text.
        let crossed = Dictation("A long letter. ")
        crossed.begin()
        crossed.hear("So I was thinking. We could meet")
        crossed.field.contextWindow = 13
        crossed.typing.discard(crossed.id)
        #expect(crossed.field.text == "A long letter. So I was thinking. We could meet")
        #expect(crossed.field.deletions == 0)
        #expect(crossed.record == nil)

        // A host that hands over all of them: both go through.
        let shown = Dictation("A long letter. ")
        shown.begin()
        shown.hear("So I was thinking. We could meet")
        shown.field.contextWindow = "So I was thinking. We could meet".count
        #expect(shown.typing.canPlace(shown.id))
        shown.typing.discard(shown.id)
        #expect(shown.field.text == "A long letter. ")
    }

    /// The end of the typed words says nothing of the rest of them. The person edited the part
    /// the host doesn't hand over; or the keyboard is in another field by now, whose text ends as
    /// the typed words do. Nothing is deleted there: not by the final text, not by the person's
    /// tap on the card, not by the cross, not by a dictation that ends with nothing.
    @Test func nothingIsDeletedWhereOnlyTheEndOfTheTypedWordsShows() {
        let said = "So I was thinking we could meet tomorrow at ten"
        let edited = "Dear Anna, So I was we could meet tomorrow at ten"
        // A web page's field after the person cut "thinking " out of the raw words: it hands over
        // the last 25 characters, which are still how the typed words end.
        func typedThenEdited() -> Dictation {
            let dictation = Dictation("Dear Anna, ")
            dictation.begin()
            dictation.hear(said)
            dictation.field.contextWindow = 25
            dictation.field.focusElsewhere(edited)
            #expect(dictation.record?.typed.count == 47)
            #expect(dictation.field.contextBeforeCursor == "ould meet tomorrow at ten")
            #expect(said.hasSuffix("ould meet tomorrow at ten"))
            #expect(!dictation.typing.canPlace(dictation.id))
            return dictation
        }
        // The tap on the card: 47 deletions would take "ar Anna, " with the 38 characters left.
        let tapped = typedThenEdited()
        #expect(tapped.typing.place(tapped.result("I was thinking we could meet tomorrow at 10.")) == nil)
        #expect(tapped.field.text == edited)
        #expect(tapped.field.deletions == 0)
        #expect(tapped.record == nil)

        let crossed = typedThenEdited()
        crossed.typing.discard(crossed.id)
        #expect(crossed.field.text == edited)
        #expect(crossed.field.deletions == 0)
        #expect(crossed.record == nil)

        // Another field, which holds only "ten".
        func elsewhere() -> Dictation {
            let dictation = Dictation("Hi. ")
            dictation.begin()
            dictation.hear("see you at ten")
            dictation.typing.suspend()
            dictation.field.focusElsewhere("ten")
            #expect(!dictation.typing.canPlace(dictation.id))
            return dictation
        }
        let tappedElsewhere = elsewhere()
        #expect(tappedElsewhere.typing.place(tappedElsewhere.result("See you at 10.")) == nil)
        #expect(tappedElsewhere.field.text == "ten")
        #expect(tappedElsewhere.field.deletions == 0)
        #expect(tappedElsewhere.record == nil)

        let crossedElsewhere = elsewhere()
        crossedElsewhere.typing.discard(crossedElsewhere.id)
        #expect(crossedElsewhere.field.text == "ten")
        #expect(crossedElsewhere.field.deletions == 0)
    }

    /// After a repeated word the text before a cursor in the middle of the typed words reads as
    /// they end, and a replacement from there would delete what stands before them. It isn't all
    /// of them, so nothing is replaced or removed there.
    @Test func aCursorAfterARepeatedWordInTheTypedWordsDeletesNothing() {
        let typed = "Anna called and then Anna"

        // The tap on the card with the cursor after the first "Anna": the text goes in there, as
        // any dictation's does, and nothing is deleted.
        let tapped = Dictation()
        tapped.begin()
        tapped.hear(typed)
        tapped.field.moveCursor(to: 4)
        #expect(tapped.field.contextBeforeCursor == "Anna")
        #expect(!tapped.typing.canPlace(tapped.id))
        #expect(tapped.typing.place(tapped.result("Ana called, and then Anna.")) == nil)
        #expect(tapped.field.text == typed)
        #expect(tapped.field.deletions == 0)

        // The cross there.
        let crossed = Dictation()
        crossed.begin()
        crossed.hear(typed)
        crossed.field.moveCursor(to: 4)
        crossed.typing.discard(crossed.id)
        #expect(crossed.field.text == typed)
        #expect(crossed.field.deletions == 0)

        // A host that hands over seven characters, the cursor after the first "I think": the
        // person's own text stays.
        let windowed = Dictation("Dear team, see below. ")
        windowed.begin()
        windowed.hear("I think so. Yes, I think")
        windowed.field.moveCursor(to: "Dear team, see below. I think".count)
        windowed.field.contextWindow = 7
        #expect(windowed.field.contextBeforeCursor == "I think")
        #expect(windowed.typing.place(windowed.result("I think so. Yes, I think.")) == nil)
        #expect(windowed.field.text == "Dear team, see below. I think so. Yes, I think")
        #expect(windowed.field.deletions == 0)
    }

    /// Words are added only where the text before the cursor shows all of what was typed. A few
    /// characters that read like its end are not enough: after a repeated word they read the
    /// same in the middle of it.
    @Test func wordsAreAddedOnlyWhereAllOfTheTypedWordsShow() {
        let repeated = Dictation()
        repeated.begin()
        repeated.hear("the cat and the")
        // The cursor is put after the first "the": what is before it is how the typed words end.
        repeated.field.moveCursor(to: 3)
        #expect(repeated.field.contextBeforeCursor == "the")
        repeated.hear("the cat and the dog")
        #expect(repeated.field.text == "the cat and the")
        #expect(!repeated.typing.isTyping(repeated.id))

        // A host that hands over less than was typed: no more words, though the cursor is at
        // their end. The final text waits for the tap, which replaces nothing there either.
        let windowed = Dictation("A long letter. ")
        windowed.begin()
        windowed.hear("So I was thinking. We could meet")
        windowed.field.contextWindow = 13
        windowed.hear("So I was thinking. We could meet on Thursday")
        #expect(windowed.field.text == "A long letter. So I was thinking. We could meet")
        #expect(!windowed.typing.isTyping(windowed.id))
        #expect(!windowed.typing.canPlace(windowed.id))
        #expect(windowed.typing.place(windowed.result("So I was thinking.")) == nil)
        #expect(windowed.field.text == "A long letter. So I was thinking. We could meet")
        #expect(windowed.field.deletions == 0)

        // One that hands over enough: the 300 characters of a standard field hold the limit.
        let standard = Dictation(String(repeating: "A long letter. ", count: 40))
        standard.field.contextWindow = 300
        standard.begin()
        var said: [String] = []
        while said.joined(separator: " ").count + 10 < LiveTyping.limit {
            said.append(Self.english[said.count % Self.english.count])
            standard.hear(said.joined(separator: " "))
        }
        #expect(standard.typing.isTyping(standard.id))
        #expect(standard.record?.typed == said.joined(separator: " "))
        #expect(standard.field.text.hasSuffix("A long letter. " + said.joined(separator: " ")))
    }

    // MARK: The demo

    /// The `typing` demo's script, through the engine: the running words go in as they settle,
    /// and its final text, which begins as they do and then differs, replaces them. The
    /// `typingCancel` demo's cross takes them out.
    @Test func theDemoScriptTypesAndIsReplaced() {
        #expect(KeyboardDemo("typing") == KeyboardDemo(state: .typing))
        #expect(KeyboardDemo("typingCancel@voice") == KeyboardDemo(state: .typingCancel, layout: .voice))

        let dictation = Dictation("Hi Anna. ")
        dictation.begin()
        for count in 0...KeyboardDemo.typingWords {
            dictation.typing.apply(KeyboardDemo.runningWords(for: dictation.id, count: count))
        }
        let settled = "So I was thinking we could meet on Thursday afternoon instead, because the morning is "
            + "already full, and then go over"
        #expect(dictation.field.text == "Hi Anna. " + settled)
        #expect(dictation.typing.isTyping(dictation.id))

        let final = KeyboardDemo.typingFinalText
        #expect(!final.contains("\n"))
        #expect(dictation.typing.place(dictation.result(final)) == final)
        #expect(dictation.field.text == "Hi Anna. " + final)
        // Every typed word goes and the whole text comes, "So I was " too.
        #expect(dictation.field.deletions == settled.count)
        #expect(dictation.field.insertions.last == final)

        let cancelled = Dictation("Hi Anna. ")
        cancelled.begin()
        for count in 0...KeyboardDemo.typingCancelWords {
            cancelled.typing.apply(KeyboardDemo.runningWords(for: cancelled.id, count: count))
        }
        #expect(cancelled.field.text == "Hi Anna. So I was thinking we could meet on Thursday")
        cancelled.typing.discard(cancelled.id)
        #expect(cancelled.field.text == "Hi Anna. ")
    }
}
