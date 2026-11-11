import MurmurUI
import SwiftUI

/// The personal dictionary: words Murmur should spell the user's way, and replacements
/// ("btw → by the way"). Both go with every dictation, to the recognizer and to the cleanup.
struct DictionaryView: View {
    @Environment(AppModel.self) private var model
    /// The editor sheet: a new word, or the entry being edited.
    @State private var editing: DictionaryEditor.Target?

    var body: some View {
        let entries = model.library.entries
        List {
            Group {
                ScreenTitle(MainTab.dictionary.title)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .accessibilityIdentifier(AccessibilityID.screen("dictionary"))
                TipCard(title: "Teach Murmur your words",
                        message: "Names, product terms, jargon. Add a word once and Murmur spells it right.",
                        action: "Add a word", dismissedKey: "intro.dictionary.dismissed") { editing = .new }
                if entries.isEmpty {
                    EmptyState("No words yet",
                               message: "Add a name Murmur keeps getting wrong, or a replacement like btw → by the way.")
                        .padding(.vertical, 48)
                } else {
                    SectionLabel("Your words (\(entries.count))")
                        .padding(.top, 26)
                        .padding(.bottom, 6)
                }
            }
            .plainListRow()

            ForEach(entries) { entry in
                Button { editing = .entry(entry) } label: { row(entry) }
                    .buttonStyle(.plain)
                    .plainListRow()
                    .swipeActions {
                        // Ink, not red: red means the microphone is open.
                        Button(role: .destructive) { model.library.deleteEntry(entry.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(Theme.ink)
                    }
            }
        }
        .plainList()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MenuToolbarItem()
            BarActionItem(systemImage: "plus", label: "Add word") { editing = .new }
        }
        .sheet(item: $editing) { target in
            DictionaryEditor(target: target)
        }
    }

    private func row(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 8) {
            if let misspelling = entry.misspelling {
                Text(verbatim: misspelling)
                    .foregroundStyle(Theme.second)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.second)
                    .accessibilityLabel("becomes")
            }
            Text(verbatim: entry.term)
                .foregroundStyle(Theme.ink)
        }
        .font(.transcript(.body))
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Adds or edits a dictionary word. With "Correct a misspelling", the misheard spelling is
/// replaced by the correct one.
struct DictionaryEditor: View {
    enum Target: Identifiable {
        case new
        case entry(DictionaryEntry)

        var id: String {
            switch self {
            case .new: "new"
            case .entry(let entry): entry.id.uuidString
            }
        }
    }

    let target: Target
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var correctsMisspelling: Bool
    @State private var term: String
    @State private var misspelling: String
    @State private var error: String?
    @FocusState private var focused: Field?

    private enum Field { case term, misspelling }

    init(target: Target) {
        self.target = target
        switch target {
        case .new:
            _correctsMisspelling = State(initialValue: false)
            _term = State(initialValue: "")
            _misspelling = State(initialValue: "")
        case .entry(let entry):
            _correctsMisspelling = State(initialValue: entry.misspelling != nil)
            _term = State(initialValue: entry.term)
            _misspelling = State(initialValue: entry.misspelling ?? "")
        }
    }

    private var existing: DictionaryEntry? {
        if case .entry(let entry) = target { entry } else { nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title, canConfirm: !term.trimmingCharacters(in: .whitespaces).isEmpty,
                        cancel: { dismiss() }, confirm: save)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Toggle("Correct a misspelling", isOn: $correctsMisspelling.animation())
                        .font(.murmur(.body))
                        .foregroundStyle(Theme.ink)
                        .tint(Theme.ink)
                        .frame(minHeight: 56)
                        .overlay(alignment: .bottom) { Hairline() }
                    if correctsMisspelling {
                        LabeledField("Misspelling") {
                            TextField("What Murmur writes, e.g. btw", text: $misspelling)
                                .focused($focused, equals: .misspelling)
                        }
                        LabeledField("Correct spelling") {
                            TextField("What it should write, e.g. by the way", text: $term)
                                .focused($focused, equals: .term)
                        }
                    } else {
                        LabeledField("Word") {
                            TextField("Add a new word", text: $term)
                                .focused($focused, equals: .term)
                        }
                    }
                    FieldError(message: error)
                    if let existing {
                        DeleteButton(title: "Delete word") {
                            model.library.deleteEntry(existing.id)
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .background(Theme.canvas)
        .presentationBackground(Theme.canvas)
        .tint(Theme.ink)
        .onChange(of: term) { error = nil }
        .onChange(of: misspelling) { error = nil }
        .onAppear { focused = correctsMisspelling ? .misspelling : .term }
    }

    private var title: String {
        switch (existing, correctsMisspelling) {
        case (nil, _): "Add to dictionary"
        case (_, true): "Edit replacement"
        case (_, false): "Edit word"
        }
    }

    private func save() {
        do {
            try model.library.saveEntry(id: existing?.id, term: term,
                                        misspelling: correctsMisspelling ? misspelling : nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
