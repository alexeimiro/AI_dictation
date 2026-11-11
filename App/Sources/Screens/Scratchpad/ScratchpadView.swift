import MurmurCore
import MurmurUI
import SwiftUI

/// Notes: quick thoughts, typed or dictated with the mic. Signed in, they're on every device
/// (`LibrarySync`).
struct ScratchpadView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        let notes = filtered
        Group {
            if model.library.notes.isEmpty {
                VStack(spacing: 0) {
                    title
                        .padding(.horizontal, 20)
                    Spacer()
                    EmptyState("Say a thought, keep it",
                               message: "Notes are a place to dictate when you have nowhere else to put it.") {
                        Button("New note", action: createNote)
                            .buttonStyle(.murmur(.primary, size: .compact))
                    }
                    Spacer()
                    Spacer()
                }
            } else {
                List {
                    title
                        .plainListRow()
                    SearchField(text: $search, prompt: "Search notes")
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                        .plainListRow()
                    if notes.isEmpty {
                        EmptyState("No notes found", message: "Nothing matches “\(search)”.")
                            .padding(.vertical, 48)
                            .plainListRow()
                    }
                    ForEach(notes) { note in
                        Button {
                            model.router.open(.note(note.id))
                        } label: {
                            NoteRow(note: note)
                        }
                        .buttonStyle(.plain)
                        .plainListRow()
                        .swipeActions {
                            // Ink, not red: red means the microphone is open.
                            Button(role: .destructive) { model.library.deleteNote(note.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(Theme.ink)
                            ShareLink(item: note.body) { Label("Share", systemImage: "square.and.arrow.up") }
                                .tint(Theme.second)
                        }
                    }
                }
                .plainList()
            }
        }
        .background(Theme.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MenuToolbarItem()
            BarActionItem(systemImage: "plus", label: "New note", action: createNote)
        }
    }

    private var title: some View {
        ScreenTitle(MainTab.scratchpad.title)
            .padding(.top, 6)
            .accessibilityIdentifier(AccessibilityID.screen("notes"))
    }

    private var filtered: [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.library.notes }
        return model.library.notes.filter {
            $0.title.localizedStandardContains(query) || $0.body.localizedStandardContains(query)
        }
    }

    private func createNote() {
        let note = model.library.createNote()
        model.router.open(.note(note.id))
    }
}

/// A note in the list: its title, then when it changed and how it starts.
private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.displayTitle)
                .font(.transcript(.body).weight(.semibold))
                .foregroundStyle(Theme.ink)
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
            .foregroundStyle(Theme.third)
        }
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(.rect)
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
                EmptyState("Note not found", message: "It may have been deleted on another device.")
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.canvas)
        .navigationBarTitleDisplayMode(.inline)
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
            .lineSpacing(4)
            .foregroundStyle(Theme.ink)
            .scrollContentBackground(.hidden)
            // The editor insets its text by 5 pt itself: 20 pt in all, the screen's margin.
            .padding(.horizontal, 15)
            .focused($bodyFocused)
            .overlay(alignment: .topLeading) {
                if note.body.isEmpty {
                    Text("Tap the mic and talk, or type.")
                        .font(.transcript(.body))
                        .foregroundStyle(Theme.third)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                NoteMicBar(noteID: id)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        newTitle = note.title
                        renaming = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(note.displayTitle)
                                .font(.murmur(.headline))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.ink)
                        // A title made of the note's first line would run under the bar's buttons.
                        .frame(maxWidth: 220)
                    }
                    .accessibilityLabel("Rename, \(note.displayTitle)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: note.body) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .disabled(note.body.isEmpty)
                    .accessibilityLabel("Share")
                }
                .sharedBackgroundVisibility(.hidden)
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

/// The note's mic, in the middle at the bottom. While it listens it is red, ringed by the voice,
/// with ✕ on its left to drop the dictation and the time on its right.
private struct NoteMicBar: View {
    let noteID: UUID
    @Environment(AppModel.self) private var model
    @State private var listeningSince = Date()

    var body: some View {
        let phase = model.noteDictation.phase(for: noteID)
        HStack(spacing: 20) {
            Group {
                if phase == .listening {
                    Button { model.noteDictation.cancel() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 44, height: 44)
                            .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 1.5) }
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel dictation")
                    .transition(.opacity)
                }
            }
            .frame(width: 84, alignment: .trailing)
            micButton(phase)
            Group {
                switch phase {
                case .listening:
                    Text(timerInterval: listeningSince...Date.distantFuture, countsDown: false)
                        .font(.murmur(.headline).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .accessibilityLabel("Listening")
                case .processing:
                    Text("Writing…")
                        .font(.murmur(.subhead, weight: .semibold))
                        .foregroundStyle(Theme.second)
                case .idle, .starting:
                    EmptyView()
                }
            }
            .frame(width: 84, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
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
                // Red only while the microphone is open for this note.
                Circle()
                    .fill(phase == .listening ? Theme.live : Theme.ink)
                switch phase {
                case .idle:
                    Image(systemName: "mic").font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.onInk)
                case .listening:
                    RoundedRectangle(cornerRadius: 4).fill(Theme.onLive).frame(width: 20, height: 20)
                case .starting, .processing:
                    ProgressView().tint(Theme.onInk)
                }
            }
            .frame(width: 64, height: 64)
            .background {
                if phase == .listening { NoteEchoRings() }
            }
            .contentShape(.circle)
        }
        .buttonStyle(.bare)
        .disabled(phase == .starting || phase == .processing)
        .accessibilityLabel(phase == .listening ? "Stop dictation" : "Dictate")
        .accessibilityHint(phase == .listening ? "Inserts what you said at the cursor" : "")
    }
}

/// The echo rings around the stop button, fed by the session's published level every 50 ms. On
/// screen only while a note is being dictated.
private struct NoteEchoRings: View {
    @Environment(AppModel.self) private var model
    @State private var levels: [Double] = []

    var body: some View {
        EchoRingsView(levels: levels, diameter: 64)
            .task {
                while !Task.isCancelled {
                    let level = Double(model.transport.currentState().level) / 255
                    // As many samples as the outermost ring trails by.
                    levels = Array((levels + [level]).suffix(EchoRings.count * EchoRings.lag + 2))
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
    }
}
