import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The account's copy in memory: rows with a server clock, and refusals on demand.
@MainActor
private final class FakeRemote: LibraryRemote {
    struct Row {
        var item: LibraryItem?
        var updatedAt: String
    }

    var rows: [LibraryKind: [UUID: Row]] = [:]
    var unreachable = false
    private(set) var upserts: [[UUID]] = []
    private(set) var deletes: [[UUID]] = []
    private(set) var pulls: [(LibraryKind, String?)] = []
    private var clock = 0

    private func tick() -> String {
        clock += 1
        return String(format: "2026-11-10T10:00:%02d.000000+00:00", clock)
    }

    /// Another device's change.
    func put(_ item: LibraryItem) {
        rows[item.kind, default: [:]][item.id] = Row(item: item, updatedAt: tick())
    }

    func remove(_ kind: LibraryKind, _ id: UUID) {
        rows[kind, default: [:]][id] = Row(item: nil, updatedAt: tick())
    }

    func changes(_ kind: LibraryKind, since: String?, limit: Int) async throws -> [RemoteRow] {
        if unreachable { throw LibraryRemoteError.unreachable }
        pulls.append((kind, since))
        return (rows[kind] ?? [:])
            .filter { since == nil || $0.value.updatedAt >= since! }
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(limit)
            .map { RemoteRow(kind: kind, id: $0.key, item: $0.value.item, updatedAt: $0.value.updatedAt) }
    }

    func upsert(_ items: [LibraryItem]) async throws {
        if unreachable { throw LibraryRemoteError.unreachable }
        upserts.append(items.map(\.id))
        for item in items {
            if case .snippet(let snippet, _) = item,
               rows[.snippet]?.values.contains(where: { row in
                   guard case .snippet(let other, _)? = row.item else { return false }
                   return other.id != snippet.id && other.trigger.lowercased() == snippet.trigger.lowercased()
               }) == true {
                throw LibraryRemoteError.conflict
            }
        }
        for item in items { put(item) }
    }

    func delete(_ kind: LibraryKind, ids: [UUID]) async throws {
        if unreachable { throw LibraryRemoteError.unreachable }
        deletes.append(ids)
        for id in ids where rows[kind]?[id] != nil { remove(kind, id) }
    }
}

@MainActor
struct LibrarySyncTests {
    private func make(signedIn: Bool = true, pageSize: Int = 500) throws -> (LibraryStore, FakeRemote, LibrarySync) {
        let library = try LibraryStore(inMemory: true)
        let remote = FakeRemote()
        let sync = LibrarySync(library: library, remote: remote, stateURL: nil, pageSize: pageSize,
                               isEnabled: { signedIn })
        library.onLocalChange = { kind, id, deleted in sync.noteLocalChange(kind, id, deleted: deleted) }
        return (library, remote, sync)
    }

    /// What was here before sync goes up; the account's comes down.
    @Test func theFirstSyncSendsTheLibraryAndTakesTheAccounts() async throws {
        let (library, remote, sync) = try make()
        try library.saveEntry(term: "Valerio", misspelling: nil)
        remote.put(.entry(DictionaryEntry(term: "Kubernetes", misspelling: "cooper netties")))
        remote.put(.note(Note(title: "From the iPad", body: "Hello")))
        await sync.sync()
        #expect(remote.rows[.entry]?.count == 2)
        #expect(library.entries.map(\.term).sorted() == ["Kubernetes", "Valerio"])
        #expect(library.notes.map(\.title) == ["From the iPad"])
        #expect(sync.lastSyncedAt != nil && sync.lastError == nil)
        #expect(sync.state.dirty.values.allSatisfy { $0.isEmpty })
    }

    /// Deleted elsewhere: gone here. Deleted here: marked deleted for the others.
    @Test func deletionsGoBothWays() async throws {
        let (library, remote, sync) = try make()
        let mine = try library.saveSnippet(trigger: "my email", expansion: "a@b.c")
        let theirs = Note(title: "Old", body: "x")
        remote.put(.note(theirs))
        await sync.sync()
        #expect(library.notes.count == 1)

        remote.remove(.note, theirs.id)
        library.deleteSnippet(mine.id)
        await sync.sync()
        #expect(library.notes.isEmpty)
        #expect(remote.rows[.snippet]?[mine.id]?.item == nil)
        #expect(remote.deletes.last == [mine.id])
    }

    /// A word edited here and elsewhere ends up as it was here: the push goes first.
    @Test func thisIPhonesEditWins() async throws {
        let (library, remote, sync) = try make()
        let entry = try library.saveEntry(term: "Murmur", misspelling: nil)
        await sync.sync()
        remote.put(.entry(DictionaryEntry(id: entry.id, term: "Murmurr", createdAt: entry.createdAt)))
        try library.saveEntry(id: entry.id, term: "Murmur App", misspelling: nil)
        await sync.sync()
        #expect(library.entries.map(\.term) == ["Murmur App"])
        guard case .entry(let server)? = remote.rows[.entry]?[entry.id]?.item else {
            Issue.record("the server lost the word")
            return
        }
        #expect(server.term == "Murmur App")
    }

    /// The account already has a snippet with that trigger: the account's replaces this one.
    @Test func aSnippetWhoseTriggerTheAccountHasGivesWay() async throws {
        let (library, remote, sync) = try make()
        let theirs = SnippetDefinition(trigger: "My Email", expansion: "work@example.com")
        remote.put(.snippet(theirs, createdAt: Date()))
        try library.saveSnippet(trigger: "my email", expansion: "home@example.com")
        await sync.sync()
        #expect(library.snippets.map(\.expansion) == ["work@example.com"])
        #expect(library.snippets.map(\.id) == [theirs.id])
    }

    /// Two devices added the same word under different IDs: the older stays, here and on the
    /// server, whichever device syncs first.
    @Test(arguments: [true, false])
    func theSameWordFromTwoDevicesIsKeptOnce(theirsIsOlder: Bool) async throws {
        let (library, remote, sync) = try make()
        await sync.sync()
        let mine = try library.saveEntry(term: "Anton", misspelling: nil)
        let theirs = DictionaryEntry(term: "anton", createdAt: mine.createdAt.addingTimeInterval(theirsIsOlder ? -60 : 60))
        remote.put(.entry(theirs))
        // This iPhone's word goes up before the pull sees the other one.
        await sync.sync()
        let kept = theirsIsOlder ? theirs.id : mine.id
        #expect(library.entries.map(\.id) == [kept])
        await sync.sync()
        #expect(remote.rows[.entry]?.values.compactMap(\.item).map(\.id) == [kept])
        #expect(library.entries.map(\.id) == [kept])
    }

    @Test func aNewNoteWaitsUntilItHasText() async throws {
        let (library, remote, sync) = try make()
        var note = library.createNote()
        await sync.sync()
        #expect(remote.rows[.note] == nil)
        note.body = "Buy milk"
        library.updateNote(note)
        await sync.sync()
        #expect(remote.rows[.note]?[note.id] != nil)
    }

    @Test func signedOutNothingIsSent() async throws {
        let (library, remote, sync) = try make(signedIn: false)
        try library.saveEntry(term: "Anton", misspelling: nil)
        await sync.sync()
        #expect(remote.upserts.isEmpty && remote.pulls.isEmpty)
    }

    /// Offline: everything stays queued for the next sync.
    @Test func offlineTheQueueIsKept() async throws {
        let (library, remote, sync) = try make()
        await sync.sync()
        remote.unreachable = true
        let entry = try library.saveEntry(term: "Anton", misspelling: nil)
        await sync.sync()
        #expect(sync.lastError != nil)
        #expect(sync.state.dirty[.entry] == [entry.id])
        remote.unreachable = false
        await sync.sync()
        #expect(remote.rows[.entry]?[entry.id] != nil)
        #expect(sync.lastError == nil)
    }

    /// Full pages keep the pull going; the cursor ends at the newest row.
    @Test func pullsPageByPage() async throws {
        let (library, remote, sync) = try make(pageSize: 2)
        for word in ["one", "two", "three", "four", "five"] {
            remote.put(.entry(DictionaryEntry(term: word)))
        }
        await sync.sync()
        #expect(library.entries.count == 5)
        #expect(sync.state.cursors[.entry] == remote.rows[.entry]?.values.map(\.updatedAt).max())
    }

    /// Signing out deletes the library here without telling the server, and starts sync over.
    @Test func resetSendsNothingAndStartsOver() async throws {
        let (library, remote, sync) = try make()
        try library.saveEntry(term: "Anton", misspelling: nil)
        await sync.sync()
        sync.reset()
        library.deleteAll()
        await sync.sync()
        #expect(remote.deletes.isEmpty)
        #expect(library.entries.map(\.term) == ["Anton"])
    }

    @Test func serverTimesKeepTheirMicroseconds() throws {
        let date = try #require(ServerTime.date("2026-11-09T18:40:12.123456+00:00"))
        #expect(abs(date.timeIntervalSince1970 - 1_794_249_612.123456) < 0.000_01)
        #expect(ServerTime.date("2026-11-09T18:40:12+00:00")?.timeIntervalSince1970 == 1_794_249_612)
        #expect(ServerTime.date("not a date") == nil)
    }
}
