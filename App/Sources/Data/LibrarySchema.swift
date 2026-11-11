import Foundation
import SwiftData

/// Version 1 of the user's library: the personal dictionary, snippets and notes. A store
/// of its own (`Library.store`), so history's schema and its users' data are left alone. Field
/// limits match the server tables (`dictionary_entries`, `snippets`, `notes`) for a later sync.
enum LibrarySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [DictionaryEntryRecord.self, SnippetRecord.self, NoteRecord.self]
    }

    @Model
    final class DictionaryEntryRecord {
        @Attribute(.unique) var id: UUID
        var term: String
        var misspelling: String?
        var createdAt: Date
        var updatedAt: Date

        init(_ entry: DictionaryEntry) {
            id = entry.id
            term = entry.term
            misspelling = entry.misspelling
            createdAt = entry.createdAt
            updatedAt = entry.createdAt
        }

        var snapshot: DictionaryEntry {
            DictionaryEntry(id: id, term: term, misspelling: misspelling, createdAt: createdAt)
        }
    }

    @Model
    final class SnippetRecord {
        @Attribute(.unique) var id: UUID
        var trigger: String
        var expansion: String
        var createdAt: Date
        var updatedAt: Date

        init(id: UUID, trigger: String, expansion: String, createdAt: Date) {
            self.id = id
            self.trigger = trigger
            self.expansion = expansion
            self.createdAt = createdAt
            updatedAt = createdAt
        }
    }

    @Model
    final class NoteRecord {
        @Attribute(.unique) var id: UUID
        var title: String
        var body: String
        var createdAt: Date
        var updatedAt: Date

        init(_ note: Note) {
            id = note.id
            title = note.title
            body = note.body
            createdAt = note.createdAt
            updatedAt = note.updatedAt
        }

        var snapshot: Note {
            Note(id: id, title: title, body: body, createdAt: createdAt, updatedAt: updatedAt)
        }
    }
}

typealias DictionaryEntryRecord = LibrarySchemaV1.DictionaryEntryRecord
typealias SnippetRecord = LibrarySchemaV1.SnippetRecord
typealias NoteRecord = LibrarySchemaV1.NoteRecord

/// A word the recognizer and the cleanup should spell the user's way. With a misspelling, it's a
/// replacement: "btw → by the way".
struct DictionaryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var term: String
    var misspelling: String?
    var createdAt: Date

    init(id: UUID = UUID(), term: String, misspelling: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.term = term
        self.misspelling = misspelling
        self.createdAt = createdAt
    }
}

/// A note. An empty title shows the note's first words, or its date.
struct Note: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "", body: String = "", createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// The title, else the body's first line (up to 60 characters), else the day it was made
    /// ("9 Nov").
    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let line = body.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return String(line.prefix(60))
        }
        return createdAt.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The body has more to show than the title: a named note, or one longer than its first line.
    var hasPreview: Bool {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !body.isEmpty && body != displayTitle
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
