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
            Section {
                IntroCard(
                    title: "Murmur speaks the way you speak",
                    message: Text("Teach it your own words — **names, company jargon, industry terms**."),
                    action: "Add new word",
                    dismissedKey: "intro.dictionary.dismissed"
                ) { editing = .new }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if entries.isEmpty {
                Section {
                    EmptyTabMessage(systemImage: "character.book.closed", title: "No words yet",
                                    detail: "Add a name Murmur keeps getting wrong, or a replacement like btw → by the way.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(entries) { entry in
                        Button { editing = .entry(entry) } label: { row(entry) }
                            .swipeActions {
                                Button(role: .destructive) { model.library.deleteEntry(entry.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    CountHeader(title: "Your words", count: entries.count)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Dictionary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { MenuButton() }
        }
        .overlay(alignment: .bottomTrailing) {
            AddButton(label: "Add word") { editing = .new }
        }
        .sheet(item: $editing) { target in
            DictionaryEditor(target: target)
        }
    }

    private func row(_ entry: DictionaryEntry) -> some View {
        Group {
            if let misspelling = entry.misspelling {
                Text("\(misspelling) → \(entry.term)")
            } else {
                Text(entry.term)
            }
        }
        .font(.transcript(.body))
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(.rect)
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
        NavigationStack {
            Form {
                Section {
                    Toggle("Correct a misspelling", isOn: $correctsMisspelling.animation())
                        .tint(Palette.toggleGreen)
                }
                if correctsMisspelling {
                    Section("Misspelling") {
                        TextField("What Murmur writes, e.g. btw", text: $misspelling)
                            .focused($focused, equals: .misspelling)
                    }
                    Section {
                        TextField("What it should write, e.g. by the way", text: $term)
                            .focused($focused, equals: .term)
                    } header: {
                        Text("Correct spelling")
                    } footer: {
                        FieldError(message: error)
                    }
                } else {
                    Section {
                        TextField("Add a new word", text: $term)
                            .focused($focused, equals: .term)
                    } header: {
                        Text("Word")
                    } footer: {
                        FieldError(message: error)
                    }
                }
                if let existing {
                    Section {
                        Button("Delete word", role: .destructive) {
                            model.library.deleteEntry(existing.id)
                            dismiss()
                        }
                    }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: term) { error = nil }
            .onChange(of: misspelling) { error = nil }
            .onAppear { focused = correctsMisspelling ? .misspelling : .term }
        }
        .tint(Palette.ink)
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
