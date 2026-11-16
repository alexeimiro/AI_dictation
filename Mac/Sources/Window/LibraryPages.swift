import MurmurCore
import SwiftUI

/// Dictionary: words Murmur spells the user's way, and what it hears wrong.
struct DictionaryPage: View {
    @Bindable var model: MacAppModel
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            PageBar {
                SearchField(prompt: "Search words", text: $search, width: 220)
                Button { model.sheet = .word(nil) } label: { Label("Add word", systemImage: "plus") }
                    .buttonStyle(InkButtonStyle(height: 30))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "Dictionary", lede: "Words Murmur should always spell your way, in every app.")
                    if !model.dictionaryIntroDismissed, search.isEmpty {
                        IntroCard(title: "Teach Murmur your words",
                                  text: "Names, product terms, jargon. Add a word once and Murmur spells it right. If Murmur hears it wrong, tell it what you say and what it should write.",
                                  dismiss: { model.dictionaryIntroDismissed = true })
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            SectionLabel(text: "Your words (\(model.library.entries.count))")
                            Spacer()
                            if model.isSignedIn { SyncedNote() }
                        }
                        .padding(.bottom, 4)
                        if entries.isEmpty {
                            Text(search.isEmpty ? "No words yet." : "No words match “\(search)”.")
                                .font(Mac.Font.lede).foregroundStyle(Mac.Palette.second)
                                .frame(height: 46, alignment: .leading)
                                .overlay(alignment: .top) { Rectangle().fill(Mac.Palette.line).frame(height: 1) }
                        }
                        ForEach(entries, id: \.id) { entry in
                            WordRow(entry: entry) { model.sheet = .word(entry) } delete: { model.deleteWord(entry) }
                        }
                        Rectangle().fill(Mac.Palette.line).frame(height: 1)
                    }
                }
                .padding(.horizontal, Mac.Metric.pagePadding)
                .padding(.top, 4).padding(.bottom, 40)
                .frame(maxWidth: Mac.Metric.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var entries: [DictionaryEntry] {
        let all = model.library.entries.sorted { $0.createdAt < $1.createdAt }
        guard !search.isEmpty else { return all }
        return all.filter { $0.term.localizedCaseInsensitiveContains(search)
            || ($0.misspelling ?? "").localizedCaseInsensitiveContains(search) }
    }
}

private struct WordRow: View {
    let entry: DictionaryEntry
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let heard = entry.misspelling {
                Text(heard).foregroundStyle(Mac.Palette.third)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Mac.Palette.third)
            }
            Text(entry.term)
            Spacer(minLength: 0)
            if hovering {
                IconButton(symbol: "pencil", label: "Edit \(entry.term)", action: edit)
                IconButton(symbol: "trash", label: "Delete \(entry.term)", action: delete)
            }
        }
        .font(Mac.Font.body)
        .frame(height: 46)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Mac.Palette.fill : .clear))
        .overlay(alignment: .top) { Rectangle().fill(Mac.Palette.line).frame(height: 1).padding(.horizontal, 12) }
        .padding(.horizontal, -12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

/// "Add a word" and "Edit word".
struct WordSheet: View {
    let model: MacAppModel
    let entry: DictionaryEntry?
    @State private var term: String
    @State private var hearsWrong: Bool
    @State private var heard: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: MacAppModel, entry: DictionaryEntry?) {
        self.model = model
        self.entry = entry
        _term = State(initialValue: entry?.term ?? "")
        _hearsWrong = State(initialValue: entry?.misspelling != nil)
        _heard = State(initialValue: entry?.misspelling ?? "")
    }

    var body: some View {
        DialogChrome(title: entry == nil ? "Add a word" : "Edit word") {
            DialogField(label: "Word", text: $term)
            Toggle(isOn: $hearsWrong) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Murmur hears it wrong").font(.system(size: 14, weight: .semibold))
                    Text("Tell it what you say, and it writes the word instead")
                        .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                }
            }
            .toggleStyle(InkToggleStyle())
            if hearsWrong {
                VStack(alignment: .leading, spacing: 6) {
                    DialogField(label: "When I say", text: $heard)
                    if !term.isEmpty, !heard.isEmpty {
                        Text("Murmur writes “\(term)” whenever it hears “\(heard)”.")
                            .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                    }
                }
            }
            if let error {
                Text(error).font(Mac.Font.caption).foregroundStyle(Mac.Palette.ink)
            }
        } buttons: {
            Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
            Button(entry == nil ? "Add word" : "Save") { save() }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func save() {
        do {
            try model.saveWord(entry, term: term, misspelling: hearsWrong && !heard.isEmpty ? heard : nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Snippets: a name the user says, and the text Murmur types for it.
struct SnippetsPage: View {
    @Bindable var model: MacAppModel
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            PageBar {
                SearchField(prompt: "Search snippets", text: $search, width: 220)
                Button { model.sheet = .snippet(nil) } label: { Label("New snippet", systemImage: "plus") }
                    .buttonStyle(InkButtonStyle(height: 30))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "Snippets", lede: "Say a snippet’s name while you dictate and Murmur types the whole thing.")
                    if !model.snippetsIntroDismissed, search.isEmpty {
                        IntroCard(title: "Shortcuts for text you repeat",
                                  text: "Your email, an address, a link. Say “my calendar link” in any app and Murmur writes the link.",
                                  dismiss: { model.snippetsIntroDismissed = true })
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            SectionLabel(text: "Your snippets (\(model.library.snippets.count))")
                            Spacer()
                            if model.isSignedIn { SyncedNote() }
                        }
                        .padding(.bottom, 4)
                        if snippets.isEmpty {
                            Text(search.isEmpty ? "No snippets yet." : "No snippets match “\(search)”.")
                                .font(Mac.Font.lede).foregroundStyle(Mac.Palette.second)
                                .frame(height: 46, alignment: .leading)
                                .overlay(alignment: .top) { Rectangle().fill(Mac.Palette.line).frame(height: 1) }
                        }
                        ForEach(snippets) { snippet in
                            SnippetRow(snippet: snippet) { model.sheet = .snippet(snippet) } delete: { model.deleteSnippet(snippet) }
                        }
                        Rectangle().fill(Mac.Palette.line).frame(height: 1)
                    }
                }
                .padding(.horizontal, Mac.Metric.pagePadding)
                .padding(.top, 4).padding(.bottom, 40)
                .frame(maxWidth: Mac.Metric.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var snippets: [SnippetDefinition] {
        guard !search.isEmpty else { return model.library.snippets }
        return model.library.snippets.filter {
            $0.trigger.localizedCaseInsensitiveContains(search) || $0.expansion.localizedCaseInsensitiveContains(search)
        }
    }
}

private struct SnippetRow: View {
    let snippet: SnippetDefinition
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.trigger).font(Mac.Font.cardTitle)
                Text(snippet.expansion).font(Mac.Font.small).foregroundStyle(Mac.Palette.second).lineSpacing(2)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                IconButton(symbol: "pencil", label: "Edit \(snippet.trigger)", action: edit)
                IconButton(symbol: "trash", label: "Delete \(snippet.trigger)", action: delete)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Mac.Palette.fill : .clear))
        .overlay(alignment: .top) { Rectangle().fill(Mac.Palette.line).frame(height: 1).padding(.horizontal, 12) }
        .padding(.horizontal, -12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

/// "New snippet" and "Edit snippet".
struct SnippetSheet: View {
    let model: MacAppModel
    let snippet: SnippetDefinition?
    @State private var trigger: String
    @State private var expansion: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    static let limit = 4000

    init(model: MacAppModel, snippet: SnippetDefinition?) {
        self.model = model
        self.snippet = snippet
        _trigger = State(initialValue: snippet?.trigger ?? "")
        _expansion = State(initialValue: snippet?.expansion ?? "")
    }

    var body: some View {
        DialogChrome(title: snippet == nil ? "New snippet" : "Edit snippet", width: 500) {
            DialogField(label: "Name you say", text: $trigger)
            VStack(alignment: .leading, spacing: 6) {
                Text("Murmur types").font(Mac.Font.label)
                TextEditor(text: $expansion)
                    .font(Mac.Font.body)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5).padding(.vertical, 6)
                    .frame(height: 112)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Mac.Palette.track, lineWidth: 1))
                Text("\(expansion.count.formatted()) of \(Self.limit.formatted())")
                    .font(Mac.Font.caption.monospacedDigit()).foregroundStyle(Mac.Palette.third)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text("Say “\(trigger.isEmpty ? "my calendar link" : trigger)” in any app and Murmur writes the whole text. It works in the middle of a sentence too.")
                .font(Mac.Font.small).foregroundStyle(Mac.Palette.second).lineSpacing(2)
            if let error {
                Text(error).font(Mac.Font.caption).foregroundStyle(Mac.Palette.ink)
            }
        } buttons: {
            Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Save snippet") { save() }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty
                    || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || expansion.count > Self.limit)
        }
    }

    private func save() {
        do {
            try model.saveSnippet(snippet, trigger: trigger, expansion: expansion)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
