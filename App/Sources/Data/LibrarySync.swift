import Foundation
import MurmurCore
import os

/// Keeps the dictionary, snippets and notes the same on every device signed in to the account.
///
/// Each local save or delete is queued (`noteLocalChange`); a sync then sends the queue and takes
/// whatever changed on the server since its cursor (the server's `updated_at`), deleting what other
/// devices deleted. Sending first means a word edited here and elsewhere ends up as it was here.
/// The queue and the cursors survive restarts in a small file beside the library.
@MainActor
@Observable
final class LibrarySync {
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    /// Why the last sync stopped, until one works.
    private(set) var lastError: String?

    /// What's still to send and how far the pull got, per kind.
    struct State: Codable, Equatable {
        var cursors: [LibraryKind: String] = [:]
        var dirty: [LibraryKind: Set<UUID>] = [:]
        var deleted: [LibraryKind: Set<UUID>] = [:]
        /// The library that existed before sync (or on this iPhone before signing in) was queued.
        var seeded = false
        var lastSyncedAt: Date?
    }

    /// Rows a pull takes at a time; a push sends `pushChunk`, so one request's rows (which share
    /// an `updated_at`) never fill a page and the pages always move on.
    static let pageSize = 500
    static let pushChunk = 100

    @ObservationIgnored private(set) var state: State
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let remote: any LibraryRemote
    @ObservationIgnored private let stateURL: URL?
    /// Sync runs only for a signed-in account.
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "Sync")

    init(library: LibraryStore, remote: any LibraryRemote, stateURL: URL? = LibrarySync.defaultStateURL,
         pageSize: Int = LibrarySync.pageSize, isEnabled: @escaping () -> Bool) {
        self.library = library
        self.pageSize = pageSize
        self.remote = remote
        self.stateURL = stateURL
        self.isEnabled = isEnabled
        state = stateURL.flatMap { JSONFile.read(State.self, from: $0) } ?? State()
        lastSyncedAt = state.lastSyncedAt
    }

    static var defaultStateURL: URL {
        URL.applicationSupportDirectory.appending(path: "Murmur/LibrarySync.json")
    }

    /// `LibraryStore.onLocalChange`: queues the change and syncs shortly after.
    func noteLocalChange(_ kind: LibraryKind, _ id: UUID, deleted: Bool) {
        if deleted {
            state.dirty[kind]?.remove(id)
            state.deleted[kind, default: []].insert(id)
        } else {
            state.deleted[kind]?.remove(id)
            state.dirty[kind, default: []].insert(id)
        }
        save()
        syncSoon()
    }

    /// A sync after `delay`, replacing one already waiting: a burst of edits is sent together.
    func syncSoon(after delay: Duration = .seconds(2)) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Sends this iPhone's changes, then takes the account's. `full` takes everything again
    /// ("Refresh from cloud"). Does nothing while signed out, or while a sync is running.
    func sync(full: Bool = false) async {
        guard isEnabled(), !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        if !state.seeded {
            for (kind, id) in library.allIDs { state.dirty[kind, default: []].insert(id) }
            state.seeded = true
        }
        if full { state.cursors = [:] }
        do {
            for kind in LibraryKind.allCases { try await push(kind) }
            for kind in LibraryKind.allCases { try await pull(kind) }
            state.lastSyncedAt = Date()
            lastSyncedAt = state.lastSyncedAt
            lastError = nil
        } catch {
            logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't sync. Check your connection; Murmur tries again on its own."
        }
        save()
    }

    /// Signing out or deleting the account: nothing is sent, and the next account starts afresh.
    func reset() {
        scheduled?.cancel()
        state = State()
        lastSyncedAt = nil
        lastError = nil
        save()
    }

    // MARK: Push

    private func push(_ kind: LibraryKind) async throws {
        // Taken off the queue first, so an edit made while this one is sent is queued again.
        let deletions = state.deleted[kind] ?? []
        state.deleted[kind] = []
        do {
            for chunk in Array(deletions).chunked(Self.pushChunk) {
                try await remote.delete(kind, ids: chunk)
            }
        } catch {
            state.deleted[kind, default: []].formUnion(deletions)
            throw error
        }

        let ids = state.dirty[kind] ?? []
        state.dirty[kind] = []
        var items: [LibraryItem] = []
        var waiting: Set<UUID> = []
        for id in ids {
            guard let item = library.item(kind, id) else { continue }
            // A new note stays here until something is written in it (or it's discarded).
            if case .note(let note) = item, note.isEmpty {
                waiting.insert(id)
                continue
            }
            items.append(item)
        }
        state.dirty[kind, default: []].formUnion(waiting)
        var sent: Set<UUID> = []
        do {
            for chunk in items.chunked(Self.pushChunk) {
                try await upsert(chunk)
                sent.formUnion(chunk.map(\.id))
            }
        } catch {
            state.dirty[kind, default: []].formUnion(ids.subtracting(sent).subtracting(waiting))
            throw error
        }
    }

    /// Sends `items`. When the server refuses the batch, they go one at a time: a snippet whose
    /// trigger the account already has gives way to the account's (the pull brings it), and one
    /// the server won't take at all is dropped from the queue instead of blocking it.
    private func upsert(_ items: [LibraryItem]) async throws {
        do {
            try await remote.upsert(items)
        } catch LibraryRemoteError.unreachable {
            throw LibraryRemoteError.unreachable
        } catch {
            for item in items {
                do {
                    try await remote.upsert([item])
                } catch LibraryRemoteError.conflict {
                    library.applyRemote([], deletions: [(item.kind, item.id)])
                } catch LibraryRemoteError.rejected(let reason) {
                    logger.error("The server refused a \(item.kind.rawValue, privacy: .public): \(reason, privacy: .public)")
                }
            }
        }
    }

    // MARK: Pull

    private func pull(_ kind: LibraryKind) async throws {
        while true {
            let rows = try await remote.changes(kind, since: state.cursors[kind], limit: pageSize)
            // Something changed here since the push waits for the next one: this iPhone's wins.
            let local = (state.dirty[kind] ?? []).union(state.deleted[kind] ?? [])
            let upserts = rows.filter { !$0.deleted && !local.contains($0.id) }.compactMap(\.item)
            let deletions = rows.filter { $0.deleted && !local.contains($0.id) }.map { (kind, $0.id) }
            let replaced = library.applyRemote(upserts, deletions: deletions)
            for (replacedKind, id) in replaced {
                state.dirty[replacedKind]?.remove(id)
                state.deleted[replacedKind, default: []].insert(id)
            }
            if let newest = rows.map(\.updatedAt).max(), newest > (state.cursors[kind] ?? "") {
                state.cursors[kind] = newest
            }
            guard rows.count == pageSize else { return }
        }
    }

    private func save() {
        guard let stateURL else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONFile.write(state, to: stateURL)
        } catch {
            logger.error("Couldn't save the sync state: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The account's copy, as `LibrarySync` sees it (`SupabaseLibraryRemote`, or a fake in tests).
@MainActor
protocol LibraryRemote: AnyObject {
    /// Rows of `kind` changed at or after `since` (an `updated_at` the server gave; nil for all),
    /// oldest first, at most `limit`.
    func changes(_ kind: LibraryKind, since: String?, limit: Int) async throws -> [RemoteRow]
    /// Inserts or updates items of one kind (and brings back one deleted before).
    func upsert(_ items: [LibraryItem]) async throws
    /// Marks the rows deleted, so other devices remove them too.
    func delete(_ kind: LibraryKind, ids: [UUID]) async throws
}

enum LibraryRemoteError: Error, Equatable {
    /// Offline, a timeout, or no session: try again later.
    case unreachable
    /// Another live snippet has the trigger (the server's unique index).
    case conflict
    /// The server refused the data itself.
    case rejected(String)
}

/// A row as the server has it: what it holds (nil once deleted), and when it last changed there.
struct RemoteRow: Equatable, Sendable {
    let kind: LibraryKind
    let id: UUID
    let item: LibraryItem?
    let updatedAt: String
    var deleted: Bool { item == nil }
}

/// Postgres timestamps as the server sends them ("2026-11-09T18:40:12.123456+00:00").
enum ServerTime {
    static func date(_ text: String) -> Date? {
        var base = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let rest = text[text.index(after: dot)...]
            let digits = rest.prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            base = String(text[..<dot]) + rest.dropFirst(digits.count)
        }
        return ISO8601DateFormatter().date(from: base)?.addingTimeInterval(fraction)
    }
}

private extension Collection {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { start in
            let from = index(startIndex, offsetBy: start)
            let to = index(from, offsetBy: Swift.min(size, distance(from: from, to: endIndex)))
            return Array(self[from..<to])
        }
    }
}
