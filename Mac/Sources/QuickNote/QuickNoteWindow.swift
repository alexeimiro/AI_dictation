import AppKit
import MurmurCore
import SwiftUI

/// The quick note: a small window that floats over every app and Space (⌥⌘N, the menu, or a
/// note's "Open in a floating window"), with its own mic. What's written lands in Notes.
struct QuickNoteWindow: View {
    @Bindable var model: MacAppModel
    @State private var text = ""
    @State private var noteID: UUID?
    @State private var onTop = true
    @State private var window: NSWindow?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Quick note").font(Mac.Font.label)
                Spacer()
                IconButton(symbol: onTop ? "pin.fill" : "pin", label: onTop ? "Keep on top, on" : "Keep on top, off",
                           iconSize: 13) {
                    onTop.toggle()
                    window?.level = onTop ? .floating : .normal
                }
                IconButton(symbol: "arrow.up.right.square", label: "Open in Murmur", iconSize: 14) {
                    save()
                    model.selectedNoteID = noteID
                    model.openMainWindow(page: .notes)
                }
            }
            .padding(.leading, 76).padding(.trailing, 10)
            .frame(height: 38)
            .overlay(alignment: .bottom) { Rectangle().fill(Mac.Palette.line).frame(height: 1) }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
            DictateBar(model: model, hint: "Click, or hold \(MacSettings.shared.trigger == .function ? "fn" : MacSettings.shared.trigger.name), to dictate here",
                       focus: { focused = true }, copyText: { text })
                .frame(height: 64)
        }
        .frame(minWidth: 360, minHeight: 280)
        .background(Mac.Palette.canvas)
        .foregroundStyle(Mac.Palette.ink)
        .environment(\.colorScheme, .light)
        .background(WindowReader { window in
            self.window = window
            window?.level = onTop ? .floating : .normal
            window?.collectionBehavior.insert(.canJoinAllSpaces)
        })
        .onAppear(perform: load)
        .onChange(of: model.quickNoteID) { load() }
        .onChange(of: text) { save() }
        .onDisappear {
            save()
            if let noteID { model.library.discardIfEmpty(noteID) }
        }
    }

    private func load() {
        if model.quickNoteID == nil { model.quickNoteID = model.library.createNote().id }
        noteID = model.quickNoteID
        let note = noteID.flatMap { model.library.note($0) }
        text = [note?.title, note?.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        focused = true
    }

    /// The first line is the note's title, the rest its text, as Notes shows them.
    private func save() {
        guard let noteID, var note = model.library.note(noteID) else { return }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        note.title = lines.first.map(String.init) ?? ""
        note.body = lines.count > 1 ? String(lines[1]) : ""
        model.library.updateNote(note)
    }
}

/// The mic bar under a note: click to dictate hands-free into the note (or hold the shortcut),
/// "Listening 0:04" while it does, and Copy.
struct DictateBar: View {
    let model: MacAppModel
    let hint: String
    let focus: () -> Void
    let copyText: () -> String
    @State private var listeningHere = false
    @State private var since = Date()
    @State private var copied = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: toggle) {
                ZStack {
                    if listening { PulseRing() }
                    Circle().fill(listening ? Mac.Palette.live : Mac.Palette.ink)
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(listening ? "Stop" : "Dictate into this note")
            if listening {
                HStack(spacing: 10) {
                    Text("Listening").font(Mac.Font.label)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                            .font(Mac.Font.small.monospacedDigit()).foregroundStyle(Mac.Palette.second)
                    }
                }
            } else if listeningHere, model.engine.phase == .processing {
                Text("Writing…").font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
            } else {
                Text(hint).font(Mac.Font.small).foregroundStyle(Mac.Palette.second).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText(), forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(OutlineButtonStyle())
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(Mac.Palette.line).frame(height: 1) }
        .onChange(of: model.engine.phase) { _, phase in
            if phase == .idle { listeningHere = false }
        }
    }

    private var listening: Bool { listeningHere && model.engine.isListening }

    private func toggle() {
        if listening {
            model.engine.end(commit: true)
            return
        }
        focus()
        listeningHere = true
        since = Date()
        // A tick later, so the text view is first responder when the text arrives.
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            model.engine.begin(handsFree: true)
            if !model.engine.isListening { listeningHere = false }
        }
    }
}

/// Hands a view's window to `found` (for the quick note's level).
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
