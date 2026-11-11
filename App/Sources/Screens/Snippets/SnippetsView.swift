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
            Group {
                ScreenTitle(MainTab.snippets.title)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .accessibilityIdentifier(AccessibilityID.screen("snippets"))
                TipCard(title: "Shortcuts for text you repeat",
                        message: "Your email, an address, a link. Say the snippet’s name and Murmur types the whole thing.",
                        action: "Add a snippet", dismissedKey: "intro.snippets.dismissed") { editing = .new }
                if snippets.isEmpty {
                    EmptyState("No snippets yet", message: "Try “my email address” → your email.")
                        .padding(.vertical, 48)
                } else {
                    SectionLabel("Your snippets (\(snippets.count))")
                        .padding(.top, 26)
                        .padding(.bottom, 6)
                }
            }
            .plainListRow()

            ForEach(snippets) { snippet in
                Button { editing = .snippet(snippet) } label: { row(snippet) }
                    .buttonStyle(.plain)
                    .plainListRow()
                    .swipeActions {
                        // Ink, not red: red means the microphone is open.
                        Button(role: .destructive) { model.library.deleteSnippet(snippet.id) } label: {
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
            BarActionItem(systemImage: "plus", label: "Add snippet") { editing = .new }
        }
        .sheet(item: $editing) { target in
            SnippetEditor(target: target)
        }
    }

    private func row(_ snippet: SnippetDefinition) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: snippet.trigger)
                .font(.transcript(.body).weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(verbatim: snippet.expansion)
                .font(.transcript(.subheadline))
                .foregroundStyle(Theme.third)
                .lineLimit(3)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
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
        VStack(spacing: 0) {
            SheetHeader(existing == nil ? "Add snippet" : "Edit snippet", cancel: { dismiss() }, confirm: save)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledField("Snippet") {
                            TextField("What you’ll say, e.g. my email address", text: $trigger)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($triggerFocused)
                        }
                        Text("\(trigger.trimmingCharacters(in: .whitespaces).count)/\(LibraryRules.maxTrigger)")
                            .font(.murmur(.footnote))
                            .monospacedDigit()
                            .foregroundStyle(Theme.third)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledField("Expansion", minHeight: 160) {
                            TextEditor(text: $expansion)
                                .font(.transcript(.body))
                                .scrollContentBackground(.hidden)
                                // The editor insets its text by 5 pt itself.
                                .padding(.horizontal, -5)
                                .padding(.vertical, 6)
                                .frame(minHeight: 160)
                        }
                        Text("Say the snippet while dictating, and Murmur types this text in its place.")
                            .font(.murmur(.footnote))
                            .foregroundStyle(Theme.third)
                    }
                    FieldError(message: error)
                    if let existing {
                        DeleteButton(title: "Delete snippet") {
                            model.library.deleteSnippet(existing.id)
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.canvas)
        .presentationBackground(Theme.canvas)
        .tint(Theme.ink)
        .onChange(of: trigger) { error = nil }
        .onChange(of: expansion) { error = nil }
        .onAppear { if existing == nil { triggerFocused = true } }
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
