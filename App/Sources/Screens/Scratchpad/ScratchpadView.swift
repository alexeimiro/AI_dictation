import MurmurCore
import MurmurUI
import SwiftUI

/// Quick notes, typed or dictated with the mic. Signed in, they're on every device (`LibrarySync`).
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

/// One note: tap the title to rename it, type, or dictate with the mic (`NoteDictation`), which
/// inserts at the cursor. Saved as it changes; left blank, it's deleted.
struct NoteEditorView: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @State private var note: Note?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var selection: TextSelection?
    @State private var toast: String?
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
        .toast($toast)
        .onAppear {
            note = model.library.note(id)
            model.noteDictation.attach(id) { result in insert(result) }
            if note?.body.isEmpty == true, model.noteDictation.phase(for: id) == .idle { bodyFocused = true }
        }
        .onDisappear {
            model.noteDictation.detach(id)
            // Leaving ends the dictation; its text still lands at the end of the note.
            model.noteDictation.stop()
            if model.noteDictation.phase(for: id) == .idle { model.library.discardIfEmpty(id) }
        }
        .onChange(of: model.noteDictation.failure) { _, failure in
            if let failure { toast = failure }
        }
        .alert("Rename note", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { update { $0.title = String(newTitle.prefix(200)) } }
        }
    }

    private func editor(_ note: Note) -> some View {
        TextEditor(text: Binding(get: { self.note?.body ?? "" },
                                 set: { text in update { $0.body = text } }),
                   selection: $selection)
            .font(.transcript(.body))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .focused($bodyFocused)
            .overlay(alignment: .topLeading) {
                if note.body.isEmpty {
                    Text("Tap the mic to start dictating, or type.")
                        .font(.transcript(.body))
                        .foregroundStyle(Palette.disabled)
                        .padding(.horizontal, 17)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NoteMicBar(noteID: id)
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
                                .truncationMode(.tail)
                            Image(systemName: "pencil")
                                .font(.system(size: 14))
                        }
                        .foregroundStyle(Palette.text)
                        // A title made of the note's first line would run under the bar's buttons.
                        .frame(maxWidth: 220)
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

    /// A finished dictation, at the cursor (over the selection), the cursor then after it.
    private func insert(_ result: DictationResult) {
        guard var edited = note else { return }
        let inserted = NoteInsertion.insert(result.text, into: edited.body,
                                            at: Self.range(of: selection, in: edited.body), language: result.language)
        edited.body = inserted.body
        note = edited
        model.library.updateNote(edited)
        selection = TextSelection(insertionPoint: inserted.cursor)
    }

    /// The selection as a range of `text`; nil (the end) when there's none or it no longer fits.
    private static func range(of selection: TextSelection?, in text: String) -> Range<String.Index>? {
        guard let selection, case .selection(let range) = selection.indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else { return nil }
        return range
    }
}

/// The note's mic, bottom right as in Wispr Flow. While it listens: ✕ to drop the dictation, the
/// time, and the mic turned stop button, ringed by the voice's level.
private struct NoteMicBar: View {
    let noteID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listeningSince = Date()

    var body: some View {
        let phase = model.noteDictation.phase(for: noteID)
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            if phase == .listening || phase == .processing {
                HStack(spacing: 10) {
                    if phase == .listening {
                        Button { model.noteDictation.cancel() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Palette.textSecondary)
                                .frame(width: 36, height: 36)
                                .background(Palette.canvas, in: .circle)
                        }
                        .accessibilityLabel("Cancel dictation")
                        Text(timerInterval: listeningSince...Date.distantFuture, countsDown: false)
                            .font(.ui(16, .medium).monospacedDigit())
                            .foregroundStyle(Palette.text)
                            .frame(minWidth: 44, alignment: .leading)
                            .accessibilityLabel("Listening")
                    } else {
                        Text("Writing…")
                            .font(.ui(16, .medium))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 14)
                .padding(.vertical, 6)
                .background(Palette.paper, in: .capsule)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            micButton(phase)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .animation(.snappy(duration: 0.25), value: phase)
        .onChange(of: phase) { _, new in
            if new == .listening { listeningSince = Date() }
        }
    }

    private func micButton(_ phase: NoteDictation.Phase) -> some View {
        Button {
            Task { await model.noteDictation.toggle(for: noteID) }
        } label: {
            ZStack {
                if phase == .listening { LevelRings(reduceMotion: reduceMotion) }
                Circle()
                    .fill(Palette.ink)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                switch phase {
                case .idle:
                    Image(systemName: "mic.fill").font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                case .listening:
                    Image(systemName: "stop.fill").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                case .starting, .processing:
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 84, height: 84)
            .contentShape(.circle)
        }
        .disabled(phase == .starting || phase == .processing)
        .accessibilityLabel(phase == .listening ? "Stop dictation" : "Dictate")
        .accessibilityHint(phase == .listening ? "Inserts what you said at the cursor" : "")
    }
}

/// Rings around the stop button that swell with the voice (the session's published level).
private struct LevelRings: View {
    let reduceMotion: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let level = Double(model.transport.currentState().level) / 255
            Circle()
                .stroke(Palette.ink.opacity(reduceMotion ? 0.15 + level * 0.5 : 0.25), lineWidth: 2)
                .frame(width: 64, height: 64)
                .scaleEffect(reduceMotion ? 1.18 : 1.06 + min(1, level * 1.6) * 0.22)
                .animation(.easeOut(duration: 0.12), value: level)
        }
        .accessibilityHidden(true)
    }
}
