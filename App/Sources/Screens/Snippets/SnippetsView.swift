import MurmurCore
import MurmurUI
import SwiftUI

/// Voice shortcuts: saying a snippet while dictating inserts its expansion. The expansion never
/// goes to the server; the model only marks where the snippet was said.
struct SnippetsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SnippetEditor.Target?

    var body: some View {
        let snippets = model.library.snippets
        List {
            Section {
                IntroCard(
                    title: "The stuff you shouldn't have to re-type",
                    message: Text("Save text you type often — **emails, links, addresses, bios**. Say the snippet, and Murmur types the rest."),
                    action: "Add new snippet",
                    dismissedKey: "intro.snippets.dismissed"
                ) { editing = .new }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if snippets.isEmpty {
                Section {
                    EmptyTabMessage(systemImage: "scissors", title: "No snippets yet",
                                    detail: "Try “my email address” → your email.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(snippets) { snippet in
                        Button { editing = .snippet(snippet) } label: { row(snippet) }
                            .swipeActions {
                                Button(role: .destructive) { model.library.deleteSnippet(snippet.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    CountHeader(title: "Your snippets", count: snippets.count)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { MenuButton() }
        }
        .overlay(alignment: .bottomTrailing) {
            AddButton(label: "Add snippet") { editing = .new }
        }
        .sheet(item: $editing) { target in
            SnippetEditor(target: target)
        }
    }

    private func row(_ snippet: SnippetDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snippet.trigger)
                .font(.transcript(.body).weight(.medium))
                .foregroundStyle(Palette.text)
            Text(snippet.expansion)
                .font(.transcript(.subheadline))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// Adds or edits a snippet.
struct SnippetEditor: View {
    enum Target: Identifiable {
        case new
        case snippet(SnippetDefinition)

        var id: String {
            switch self {
            case .new: "new"
            case .snippet(let snippet): snippet.id.uuidString
            }
        }
    }

    let target: Target
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var expansion: String
    @State private var error: String?
    @FocusState private var triggerFocused: Bool

    init(target: Target) {
        self.target = target
        if case .snippet(let snippet) = target {
            _trigger = State(initialValue: snippet.trigger)
            _expansion = State(initialValue: snippet.expansion)
        } else {
            _trigger = State(initialValue: "")
            _expansion = State(initialValue: "")
        }
    }

    private var existing: SnippetDefinition? {
        if case .snippet(let snippet) = target { snippet } else { nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What you'll say, e.g. my email address", text: $trigger)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($triggerFocused)
                } header: {
                    Text("Snippet")
                } footer: {
                    Text("\(trigger.trimmingCharacters(in: .whitespaces).count)/\(LibraryRules.maxTrigger)")
                        .monospacedDigit()
                }
                Section {
                    TextEditor(text: $expansion)
                        .font(.transcript(.body))
                        .frame(minHeight: 160)
                } header: {
                    Text("Expansion")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldError(message: error)
                        Text("Say the snippet while dictating, and Murmur types this text in its place.")
                    }
                }
                if let existing {
                    Section {
                        Button("Delete snippet", role: .destructive) {
                            model.library.deleteSnippet(existing.id)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle(existing == nil ? "Add snippet" : "Edit snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .onChange(of: trigger) { error = nil }
            .onChange(of: expansion) { error = nil }
            .onAppear { if existing == nil { triggerFocused = true } }
        }
        .tint(Palette.ink)
    }

    private func save() {
        do {
            try model.library.saveSnippet(id: existing?.id, trigger: trigger, expansion: expansion)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
