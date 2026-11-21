import AppKit
import MurmurCore
import SwiftUI

/// Notes: the list on the left (300 pt) and the open note, with a mic that dictates into it.
/// Notes sync with the iPhone's (LibrarySync).
struct NotesPage: View {
    @Bindable var model: MacAppModel
    @State private var search = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 300)
            Rectangle().fill(Mac.Palette.line).frame(width: 1)
            if let note = selected {
                NoteEditor(model: model, note: note) { model.openQuickNote(note) }
                    .id(note.id)
            } else {
                VStack(spacing: 12) {
                    Text("No note open").font(Mac.Font.cardTitle)
                    Text("Start one, then click the mic or hold fn to talk into it.")
                        .font(Mac.Font.lede).foregroundStyle(Mac.Palette.second)
                    Button("New note") { model.newNote() }.buttonStyle(InkButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if model.selectedNoteID == nil { model.selectedNoteID = notes.first?.id }
        }
    }

    private var notes: [Note] {
        let all = model.library.notes.sorted { $0.updatedAt > $1.updatedAt }
        guard !search.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.body.localizedCaseInsensitiveContains(search) }
    }

    private var selected: Note? {
        model.selectedNoteID.flatMap { model.library.note($0) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes").font(.system(size: 20, weight: .bold)).tracking(-0.4)
                Spacer()
                IconButton(symbol: "square.and.pencil", label: "New note", size: 30, iconSize: 16) { model.newNote() }
            }
            .padding(.leading, 20).padding(.trailing, 12)
            .frame(height: Mac.Metric.barHeight)
            SearchField(prompt: "Search notes", text: $search, width: 276)
                .padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(notes) { note in
                        Button {
                            model.selectedNoteID = note.id
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.title.isEmpty ? (note.body.isEmpty ? "New note" : String(note.body.prefix(40))) : note.title)
                                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(meta(note)).font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(note.id == model.selectedNoteID ? Mac.Palette.fill : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            Text("Notes sync with Redmic on your iPhone.")
                .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        }
    }

    private func meta(_ note: Note) -> String {
        let words = WordCounter.count(note.title + " " + note.body)
        return "\(NoteDates.short(note.updatedAt)) · \(words) \(words == 1 ? "word" : "words")"
    }
}

/// The open note: its date, title and text, then the mic bar.
struct NoteEditor: View {
    let model: MacAppModel
    let note: Note
    let openFloating: () -> Void
    @State private var title: String
    @State private var text: String
    @FocusState private var bodyFocused: Bool

    init(model: MacAppModel, note: Note, openFloating: @escaping () -> Void) {
        self.model = model
        self.note = note
        self.openFloating = openFloating
        _title = State(initialValue: note.title)
        _text = State(initialValue: note.body)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                IconButton(symbol: "macwindow.on.rectangle", label: "Open in a floating window", size: 30, iconSize: 15) {
                    openFloating()
                }
                IconButton(symbol: "trash", label: "Delete note", size: 30, iconSize: 15) {
                    model.library.deleteNote(note.id)
                    model.selectedNoteID = model.library.notes.sorted { $0.updatedAt > $1.updatedAt }.first?.id
                }
            }
            .padding(.horizontal, 16)
            .frame(height: Mac.Metric.barHeight)
            VStack(alignment: .leading, spacing: 14) {
                Text(NoteDates.long(note.createdAt)).font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                TextField("Title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Mac.Font.noteTitle)
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .focused($bodyFocused)
                    .padding(.horizontal, -5)
            }
            .padding(.horizontal, 64)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            DictateBar(model: model, hint: "Click the mic, or hold fn, to dictate into this note",
                       focus: { bodyFocused = true },
                       copyText: { [title, text].filter { !$0.isEmpty }.joined(separator: "\n\n") })
                .frame(height: 72)
        }
        .onChange(of: title) { save() }
        .onChange(of: text) { save() }
        .onDisappear {
            save()
            model.library.discardIfEmpty(note.id)
        }
    }

    private func save() {
        var updated = note
        updated.title = title
        updated.body = text
        model.library.updateNote(updated)
    }
}

/// The red ring that swells from the mic while it listens (still under Reduce Motion).
struct PulseRing: View {
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .strokeBorder(Mac.Palette.live, lineWidth: 1.5)
            .scaleEffect(grown && !reduceMotion ? 2.6 : 1)
            .opacity(grown && !reduceMotion ? 0 : 0.7)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { grown = true }
            }
    }
}

/// "Today 09:41", "Yesterday", "Saturday", "November 10"; and "Today at 09:41".
enum NoteDates {
    static func short(_ date: Date, now: Date = Date()) -> String {
        switch DayBucketing.relativeDay(for: date, now: now) {
        case .today: return "Today \(date.formatted(.dateTime.hour().minute()))"
        case .yesterday: return "Yesterday"
        default:
            let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
            return days < 7 ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(.dateTime.month(.wide).day())
        }
    }

    static func long(_ date: Date, now: Date = Date()) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        switch DayBucketing.relativeDay(for: date, now: now) {
        case .today: return "Today at \(time)"
        case .yesterday: return "Yesterday at \(time)"
        default: return "\(date.formatted(.dateTime.month(.wide).day())) at \(time)"
        }
    }
}
