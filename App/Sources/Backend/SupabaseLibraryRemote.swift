import Foundation
import MurmurCore
import Supabase

/// The account's dictionary, snippets and notes in Supabase (`dictionary_entries`, `snippets`,
/// `notes`; row-level security keeps each account to its own rows). IDs come from the device,
/// `updated_at` is set by the server, and deletes are soft (`deleted_at`) so other devices learn
/// of them.
@MainActor
final class SupabaseLibraryRemote: LibraryRemote {
    private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    func changes(_ kind: LibraryKind, since: String?, limit: Int) async throws -> [RemoteRow] {
        try await run {
            var query = backend.client.from(kind.table).select(kind.columns)
            if let since { query = query.gte("updated_at", value: since) }
            let request = query.order("updated_at", ascending: true).limit(limit)
            switch kind {
            case .entry:
                let rows: [EntryRow] = try await request.execute().value
                return rows.map(\.remote)
            case .snippet:
                let rows: [SnippetRow] = try await request.execute().value
                return rows.map(\.remote)
            case .note:
                let rows: [NoteRow] = try await request.execute().value
                return rows.map(\.remote)
            }
        }
    }

    func upsert(_ items: [LibraryItem]) async throws {
        guard let kind = items.first?.kind else { return }
        try await run {
            let table = backend.client.from(kind.table)
            switch kind {
            case .entry:
                try await table.upsert(items.compactMap(EntryRow.init), onConflict: "id").execute()
            case .snippet:
                try await table.upsert(items.compactMap(SnippetRow.init), onConflict: "id").execute()
            case .note:
                try await table.upsert(items.compactMap(NoteRow.init), onConflict: "id").execute()
            }
        }
    }

    func delete(_ kind: LibraryKind, ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await run {
            try await backend.client.from(kind.table)
                .update(["deleted_at": Date().ISO8601Format()])
                .in("id", values: ids.map(\.uuidString))
                .execute()
        }
    }

    /// The session first; the server's refusals as `LibraryRemoteError`.
    private func run<T>(_ work: () async throws -> T) async throws -> T {
        do {
            try await backend.ensureSession()
            return try await work()
        } catch let error as PostgrestError {
            // 23505: a unique index (another live snippet with the trigger). Other codes are the
            // data's (a check, a type).
            if error.code == "23505" { throw LibraryRemoteError.conflict }
            if let code = error.code, code.hasPrefix("22") || code.hasPrefix("23") {
                throw LibraryRemoteError.rejected("\(code) \(error.message)")
            }
            throw LibraryRemoteError.unreachable
        } catch {
            throw LibraryRemoteError.unreachable
        }
    }
}

private extension LibraryKind {
    var table: String {
        switch self {
        case .entry: "dictionary_entries"
        case .snippet: "snippets"
        case .note: "notes"
        }
    }

    var columns: String {
        switch self {
        case .entry: "id,term,misspelling,created_at,updated_at,deleted_at"
        case .snippet: "id,trigger,expansion,created_at,updated_at,deleted_at"
        case .note: "id,title,body,created_at,updated_at,deleted_at"
        }
    }
}

/// Rows as the tables have them. Sent, `deleted_at` is an explicit null, so saving an item
/// brings back a row deleted before; `created_at` keeps the device's.
private struct EntryRow: Codable {
    let id: UUID
    let term: String
    let misspelling: String?
    let created_at: String?
    var updated_at: String?
    var deleted_at: String?

    init?(_ item: LibraryItem) {
        guard case .entry(let entry) = item else { return nil }
        id = entry.id
        term = entry.term
        misspelling = entry.misspelling
        created_at = entry.createdAt.ISO8601Format()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(term, forKey: .term)
        try container.encode(misspelling, forKey: .misspelling)
        try container.encodeIfPresent(created_at, forKey: .created_at)
        try container.encodeNil(forKey: .deleted_at)
    }

    var remote: RemoteRow {
        let created = created_at.flatMap(ServerTime.date) ?? Date()
        return RemoteRow(kind: .entry, id: id,
                         item: deleted_at == nil ? .entry(DictionaryEntry(id: id, term: term, misspelling: misspelling,
                                                                          createdAt: created)) : nil,
                         updatedAt: updated_at ?? "")
    }
}

private struct SnippetRow: Codable {
    let id: UUID
    let trigger: String
    let expansion: String
    let created_at: String?
    var updated_at: String?
    var deleted_at: String?

    init?(_ item: LibraryItem) {
        guard case .snippet(let snippet, let createdAt) = item else { return nil }
        id = snippet.id
        trigger = snippet.trigger
        expansion = snippet.expansion
        created_at = createdAt.ISO8601Format()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(expansion, forKey: .expansion)
        try container.encodeIfPresent(created_at, forKey: .created_at)
        try container.encodeNil(forKey: .deleted_at)
    }

    var remote: RemoteRow {
        let created = created_at.flatMap(ServerTime.date) ?? Date()
        return RemoteRow(kind: .snippet, id: id,
                         item: deleted_at == nil ? .snippet(SnippetDefinition(id: id, trigger: trigger, expansion: expansion),
                                                            createdAt: created) : nil,
                         updatedAt: updated_at ?? "")
    }
}

private struct NoteRow: Codable {
    let id: UUID
    let title: String
    let body: String
    let created_at: String?
    var updated_at: String?
    var deleted_at: String?

    init?(_ item: LibraryItem) {
        guard case .note(let note) = item else { return nil }
        id = note.id
        title = String(note.title.prefix(200))
        body = String(note.body.prefix(200_000))
        created_at = note.createdAt.ISO8601Format()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(created_at, forKey: .created_at)
        try container.encodeNil(forKey: .deleted_at)
    }

    var remote: RemoteRow {
        let created = created_at.flatMap(ServerTime.date) ?? Date()
        let updated = updated_at.flatMap(ServerTime.date) ?? created
        return RemoteRow(kind: .note, id: id,
                         item: deleted_at == nil ? .note(Note(id: id, title: title, body: body, createdAt: created,
                                                              updatedAt: updated)) : nil,
                         updatedAt: updated_at ?? "")
    }
}
