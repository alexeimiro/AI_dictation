import Foundation
import MurmurCore
import os
import SwiftData

/// Why a dictionary word or snippet can't be saved, worded for the editor.
enum LibraryError: Error, Equatable, LocalizedError {
    case emptyWord, wordTooLong, emptyMisspelling, misspellingTooLong, duplicateWord
    case emptySnippet, snippetTooLong, duplicateSnippet, emptyExpansion, expansionTooLong

    var errorDescription: String? {
        switch self {
        case .emptyWord: "Please enter a word"
        case .wordTooLong: "Words can be up to \(LibraryRules.maxWord) characters"
        case .emptyMisspelling: "Please enter the misspelling"
        case .misspellingTooLong: "Misspellings can be up to \(LibraryRules.maxWord) characters"
        case .duplicateWord: "That word is already in your dictionary"
        case .emptySnippet: "Please enter a snippet"
        case .snippetTooLong: "Snippet too long"
        case .duplicateSnippet: "Snippet already exists"
        case .emptyExpansion: "Please enter the text to insert"
        case .expansionTooLong: "The text can be up to \(LibraryRules.maxExpansion) characters"
        }
    }
}

/// The limits the server's tables enforce, checked before saving.
enum LibraryRules {
    static let maxWord = 59
    static let maxTrigger = 59
    static let maxExpansion = 4000

    /// Trims the word (and the misspelling, if there is one) and checks them against the
    /// dictionary's other entries.
    static func validatedEntry(term: String, misspelling: String?, others: [DictionaryEntry])
        throws(LibraryError) -> (term: String, misspelling: String?) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw .emptyWord }
        guard term.count <= maxWord else { throw .wordTooLong }
        var cleanMisspelling: String?
        if let misspelling {
            let trimmed = misspelling.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw .emptyMisspelling }
            guard trimmed.count <= maxWord else { throw .misspellingTooLong }
            cleanMisspelling = trimmed
        }
        if others.contains(where: { normalized($0.term) == normalized(term)
            && $0.misspelling.map(normalized) == cleanMisspelling.map(normalized) }) {
            throw .duplicateWord
        }
        return (term, cleanMisspelling)
    }

    /// Trims the trigger and checks it is unique the way the server's index is
    /// (`lower(btrim(trigger))`). The expansion is kept as typed: its spacing is the user's.
    static func validatedSnippet(trigger: String, expansion: String, others: [SnippetDefinition])
        throws(LibraryError) -> (trigger: String, expansion: String) {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { throw .emptySnippet }
        guard trigger.count <= maxTrigger else { throw .snippetTooLong }
        if others.contains(where: { normalized($0.trigger) == normalized(trigger) }) { throw .duplicateSnippet }
        guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyExpansion }
        guard expansion.count <= maxExpansion else { throw .expansionTooLong }
        return (trigger, expansion)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The personal dictionary, snippets and Scratchpad notes, in the app's private container. Words
/// and snippets feed the dictation pipeline through `onChange`; notes never leave the iPhone.
@MainActor
@Observable
final class LibraryStore {
    /// By the word as written in the list ("Alexey", "btw → by the way", "Wispr Flow").
    private(set) var entries: [DictionaryEntry] = []
    /// Newest first.
    private(set) var snippets: [SnippetDefinition] = []
    /// Most recently edited first.
    private(set) var notes: [Note] = []
    /// Called after the dictionary or the snippets change (not notes).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "Library")

    init(inMemory: Bool = false) throws {
        let schema = Schema(versionedSchema: LibrarySchemaV1.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration("Library", schema: schema, isStoredInMemoryOnly: true)
        } else {
            let directory = URL.applicationSupportDirectory.appending(path: "Murmur", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration("Library", schema: schema, url: directory.appending(path: "Library.store"))
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
        reload()
    }

    /// The on-disk store, or an in-memory one when it can't be opened.
    static func open(inMemory: Bool) -> LibraryStore {
        do {
            return try LibraryStore(inMemory: inMemory)
        } catch {
            Logger(subsystem: "Murmur", category: "Library")
                .error("Couldn't open the library store: \(error.localizedDescription, privacy: .public)")
            // swiftlint:disable:next force_try
            return try! LibraryStore(inMemory: true)
        }
    }

    /// What the pipeline sends with each dictation.
    var dictionaryTerms: [DictionaryTerm] {
        entries.map { DictionaryTerm(term: $0.term, misspelling: $0.misspelling) }
    }

    // MARK: Dictionary

    /// Adds a word, or changes the one with `id`. `misspelling` nil saves a plain word.
    @discardableResult
    func saveEntry(id: UUID? = nil, term: String, misspelling: String?) throws(LibraryError) -> DictionaryEntry {
        let clean = try LibraryRules.validatedEntry(
            term: term, misspelling: misspelling, others: entries.filter { $0.id != id })
        let now = Date()
        let saved: DictionaryEntry
        if let id, let record = entryRecord(id) {
            record.term = clean.term
            record.misspelling = clean.misspelling
            record.updatedAt = now
            saved = record.snapshot
        } else {
            saved = DictionaryEntry(term: clean.term, misspelling: clean.misspelling, createdAt: now)
            context.insert(DictionaryEntryRecord(saved))
        }
        commit(notifying: true)
        return saved
    }

    func deleteEntry(_ id: UUID) {
        guard let record = entryRecord(id) else { return }
        context.delete(record)
        commit(notifying: true)
    }

    // MARK: Snippets

    @discardableResult
    func saveSnippet(id: UUID? = nil, trigger: String, expansion: String) throws(LibraryError) -> SnippetDefinition {
        let clean = try LibraryRules.validatedSnippet(
            trigger: trigger, expansion: expansion, others: snippets.filter { $0.id != id })
        let saved: SnippetDefinition
        if let id, let record = snippetRecord(id) {
            record.trigger = clean.trigger
            record.expansion = clean.expansion
            record.updatedAt = Date()
            saved = SnippetDefinition(id: id, trigger: clean.trigger, expansion: clean.expansion)
        } else {
            saved = SnippetDefinition(trigger: clean.trigger, expansion: clean.expansion)
            context.insert(SnippetRecord(id: saved.id, trigger: saved.trigger, expansion: saved.expansion, createdAt: Date()))
        }
        commit(notifying: true)
        return saved
    }

    func deleteSnippet(_ id: UUID) {
        guard let record = snippetRecord(id) else { return }
        context.delete(record)
        commit(notifying: true)
    }

    // MARK: Notes

    func note(_ id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    /// A new, empty note. `discardIfEmpty` removes it again if the user leaves it blank.
    func createNote(now: Date = Date()) -> Note {
        let note = Note(createdAt: now)
        context.insert(NoteRecord(note))
        commit(notifying: false)
        return note
    }

    func updateNote(_ note: Note, now: Date = Date()) {
        guard let record = noteRecord(note.id),
              record.title != note.title || record.body != note.body else { return }
        record.title = note.title
        record.body = note.body
        record.updatedAt = now
        commit(notifying: false)
    }

    func deleteNote(_ id: UUID) {
        guard let record = noteRecord(id) else { return }
        context.delete(record)
        commit(notifying: false)
    }

    /// Leaving a note with no title and no text deletes it, so "Create a note" leaves nothing behind.
    func discardIfEmpty(_ id: UUID) {
        guard let note = note(id), note.isEmpty else { return }
        deleteNote(id)
    }

    /// Everything: words, snippets and notes (deleting the account).
    func deleteAll() {
        do {
            try context.delete(model: DictionaryEntryRecord.self)
            try context.delete(model: SnippetRecord.self)
            try context.delete(model: NoteRecord.self)
        } catch {
            logger.error("Couldn't clear the library: \(error.localizedDescription, privacy: .public)")
        }
        commit(notifying: true)
    }

    // MARK: Plumbing

    private func entryRecord(_ id: UUID) -> DictionaryEntryRecord? {
        var descriptor = FetchDescriptor<DictionaryEntryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func snippetRecord(_ id: UUID) -> SnippetRecord? {
        var descriptor = FetchDescriptor<SnippetRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func noteRecord(_ id: UUID) -> NoteRecord? {
        var descriptor = FetchDescriptor<NoteRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func commit(notifying: Bool) {
        do {
            try context.save()
        } catch {
            logger.error("Couldn't save the library: \(error.localizedDescription, privacy: .public)")
        }
        reload()
        if notifying { onChange?() }
    }

    private func reload() {
        let entryRecords = (try? context.fetch(FetchDescriptor<DictionaryEntryRecord>())) ?? []
        entries = entryRecords.map(\.snapshot).sorted {
            ($0.misspelling ?? $0.term).localizedStandardCompare($1.misspelling ?? $1.term) == .orderedAscending
        }
        let snippetRecords = (try? context.fetch(
            FetchDescriptor<SnippetRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        snippets = snippetRecords.map { SnippetDefinition(id: $0.id, trigger: $0.trigger, expansion: $0.expansion) }
        let noteRecords = (try? context.fetch(
            FetchDescriptor<NoteRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        notes = noteRecords.map(\.snapshot)
    }
}
