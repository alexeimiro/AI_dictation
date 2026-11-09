import Foundation
import MurmurCore
import Observation

/// Scratchpad's mic: dictates into a note through the app's own session, without the keyboard.
/// Its phase follows the session's for the dictation it started, so a stop from the Lock Screen
/// or the Action Button shows here too. The text goes in at the cursor of the note on screen
/// (`attach`), or at the end of the note when its editor is gone.
@MainActor
@Observable
final class NoteDictation {
    enum Phase: Equatable {
        case idle
        /// Turning the microphone on.
        case starting
        case listening
        case processing
    }

    /// The note being dictated into.
    private(set) var noteID: UUID?
    /// Why the last dictation didn't put text in, until the next one.
    var failure: String?
    private var starting = false
    private var requestID: UUID?
    @ObservationIgnored private let session: SessionController
    @ObservationIgnored private let library: LibraryStore
    /// The editor on screen for each note, which inserts at its cursor.
    @ObservationIgnored private var inserters: [UUID: (DictationResult) -> Void] = [:]

    init(session: SessionController, library: LibraryStore) {
        self.session = session
        self.library = library
    }

    func phase(for note: UUID) -> Phase {
        guard note == noteID else { return .idle }
        if starting { return .starting }
        guard let requestID else { return .idle }
        switch session.phase {
        case .recording(requestID): return .listening
        case .processing(requestID): return .processing
        default: return .idle
        }
    }

    /// The mic button: starts dictating into `note`, or stops the dictation running.
    func toggle(for note: UUID) async {
        switch phase(for: note) {
        case .listening: stop()
        case .idle: await start(into: note)
        case .starting, .processing: break
        }
    }

    /// Turns Murmur on if it's off (the app is on screen, so it can), then records.
    func start(into note: UUID) async {
        failure = nil
        noteID = note
        requestID = nil
        starting = true
        defer { starting = false }
        if !session.isLive { await session.start() }
        guard session.isLive else {
            if case .failed(let message) = session.phase { failure = message }
            else { failure = "\(Brand.name) couldn't turn the microphone on. Try again." }
            return
        }
        guard let id = session.beginInAppDictation() else {
            failure = "\(Brand.name) is finishing another dictation. Try again in a moment."
            return
        }
        requestID = id
    }

    func stop() {
        guard let requestID, session.phase == .recording(requestID) else { return }
        session.endDictation(commit: true)
    }

    /// Drops the dictation in progress without inserting anything.
    func cancel() {
        guard let requestID, session.phase == .recording(requestID) else { return }
        self.requestID = nil
        session.endDictation(commit: false)
    }

    /// The editor of `note` inserts dictated text at its cursor while it's on screen.
    func attach(_ note: UUID, inserter: @escaping (DictationResult) -> Void) {
        inserters[note] = inserter
    }

    func detach(_ note: UUID) {
        inserters[note] = nil
    }

    /// The session's in-app result (`SessionController.inAppResultHandler`).
    func deliver(_ result: DictationResult) {
        guard result.requestId == requestID, let noteID else { return }
        requestID = nil
        guard result.isInsertable else {
            failure = result.message ?? "We didn't catch anything. Please try speaking again."
            // A note left while dictating into it stays only if something went in.
            if inserters[noteID] == nil { library.discardIfEmpty(noteID) }
            return
        }
        if result.status == .limitReached { failure = result.message }
        if let inserter = inserters[noteID] {
            inserter(result)
        } else if var note = library.note(noteID) {
            note.body = NoteInsertion.insert(result.text, into: note.body, at: nil, language: result.language).body
            library.updateNote(note)
        }
    }
}

/// Where dictated text lands in a note: at the cursor (replacing a selection), spaced and
/// capitalized to fit the text before it, as the keyboard would type it.
enum NoteInsertion {
    /// `range`: the selection in `body`; nil appends. Returns the new body and the cursor after
    /// the inserted text.
    static func insert(_ text: String, into body: String, at range: Range<String.Index>?,
                       language: String?) -> (body: String, cursor: String.Index) {
        let range = range ?? body.endIndex..<body.endIndex
        let before = String(body[..<range.lowerBound])
        var piece = TextJoiner.prepare(text, traits: InsertionTraits(contextBefore: before, singleLine: false,
                                                                    language: language))
        // Text after the cursor that starts with a letter gets a space, as the keyboard leaves one.
        if let next = body[range.upperBound...].first, next.isLetter || next.isNumber, piece.last?.isWhitespace == false {
            piece += " "
        }
        var updated = body
        updated.replaceSubrange(range, with: piece)
        let offset = before.count + piece.count
        return (updated, updated.index(updated.startIndex, offsetBy: offset))
    }
}
