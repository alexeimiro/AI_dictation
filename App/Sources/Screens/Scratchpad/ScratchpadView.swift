import MurmurCore
import MurmurUI
import SwiftUI

/// Quick notes, dictated with the Murmur keyboard inside the app. They stay on this iPhone.
struct ScratchpadView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        let notes = filtered
        Group {
            if model.library.notes.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(notes) { note in
                        NavigationLink(value: Route.note(note.id)) { NoteRow(note: note) }
                            .swipeActions {
                                Button(role: .destructive) { model.library.deleteNote(note.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                ShareLink(item: note.body) { Label("Share", systemImage: "square.and.arrow.up") }
                                    .tint(Palette.ink)
                            }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .searchable(text: $search, prompt: "Search notes")
                .overlay {
                    if notes.isEmpty { ContentUnavailableView.search(text: search) }
                }
                .overlay(alignment: .bottomTrailing) {
                    AddButton(label: "New note", action: createNote)
                }
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Scratchpad")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { MenuButton() }
        }
    }

    private var filtered: [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.library.notes }
        return model.library.notes.filter {
            $0.title.localizedStandardContains(query) || $0.body.localizedStandardContains(query)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "note.text.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.muted)
            Text("Capture quick thoughts\nwith your voice")
                .font(.ui(20, .semibold, relativeTo: .title3))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Button("Create a note", action: createNote)
                .buttonStyle(.pill(.ink, height: 50))
                .frame(width: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func createNote() {
        let note = model.library.createNote()
        model.router.open(.note(note.id))
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.displayTitle)
                .font(.transcript(.body).weight(.medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                if !note.title.trimmingCharacters(in: .whitespaces).isEmpty, note.hasPreview {
                    Text("·")
                    Text(note.body)
                        .lineLimit(1)
                }
            }
            .font(.transcript(.subheadline))
            .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 4)
    }
}

/// One note: tap the title to rename it, type or dictate the text. Saved as it changes; left
/// blank, it's deleted.
struct NoteEditorView: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @State private var note: Note?
    @State private var renaming = false
    @State private var newTitle = ""
    @FocusState private var bodyFocused: Bool

    var body: some View {
        Group {
            if let note {
                editor(note)
            } else {
                ContentUnavailableView("Note not found", systemImage: "note.text")
            }
        }
        .background(Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            note = model.library.note(id)
            if note?.body.isEmpty == true { bodyFocused = true }
        }
        .onDisappear { model.library.discardIfEmpty(id) }
        .alert("Rename note", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { update { $0.title = String(newTitle.prefix(200)) } }
        }
    }

    private func editor(_ note: Note) -> some View {
        TextEditor(text: Binding(get: { self.note?.body ?? "" },
                                 set: { text in update { $0.body = text } }))
            .font(.transcript(.body))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .focused($bodyFocused)
            .overlay(alignment: .topLeading) {
                if note.body.isEmpty {
                    Text("Tap the mic on the \(Brand.name) keyboard to start dictating, or type.")
                        .font(.transcript(.body))
                        .foregroundStyle(Palette.disabled)
                        .padding(.horizontal, 17)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        newTitle = note.title
                        renaming = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(note.displayTitle)
                                .font(.ui(17, .medium))
                                .lineLimit(1)
                            Image(systemName: "pencil")
                                .font(.system(size: 14))
                        }
                        .foregroundStyle(Palette.text)
                    }
                    .accessibilityLabel("Rename, \(note.displayTitle)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: note.body) { Image(systemName: "square.and.arrow.up") }
                        .disabled(note.body.isEmpty)
                }
            }
    }

    private func update(_ change: (inout Note) -> Void) {
        guard var edited = note else { return }
        change(&edited)
        note = edited
        model.library.updateNote(edited)
    }
}
