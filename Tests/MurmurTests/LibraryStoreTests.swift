import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
struct LibraryStoreTests {
    private let store: LibraryStore

    init() throws {
        store = try LibraryStore(inMemory: true)
    }

    // MARK: Dictionary

    @Test func savesWordsAndReplacementsSortedAsListed() throws {
        try store.saveEntry(term: "Voice Memos", misspelling: nil)
        try store.saveEntry(term: "by the way", misspelling: " btw ")
        try store.saveEntry(term: "  Alexey ", misspelling: nil)
        #expect(store.entries.map(\.term) == ["Alexey", "by the way", "Voice Memos"])
        #expect(store.entries[1].misspelling == "btw")
        #expect(store.dictionaryTerms == [
            DictionaryTerm(term: "Alexey"), DictionaryTerm(term: "by the way", misspelling: "btw"),
            DictionaryTerm(term: "Voice Memos"),
        ])
    }

    @Test func rejectsEmptyLongAndDuplicateWords() throws {
        #expect(throws: LibraryError.emptyWord) { try store.saveEntry(term: "  ", misspelling: nil) }
        #expect(throws: LibraryError.wordTooLong) {
            try store.saveEntry(term: String(repeating: "a", count: 60), misspelling: nil)
        }
        #expect(throws: LibraryError.emptyMisspelling) { try store.saveEntry(term: "Kubernetes", misspelling: " ") }
        try store.saveEntry(term: "Kubernetes", misspelling: nil)
        #expect(throws: LibraryError.duplicateWord) { try store.saveEntry(term: "kubernetes ", misspelling: nil) }
        // The same word as a replacement is a different entry.
        try store.saveEntry(term: "Kubernetes", misspelling: "cooper netties")
        #expect(store.entries.count == 2)
    }

    @Test func editsInPlaceWithoutTrippingOverItself() throws {
        let entry = try store.saveEntry(term: "Murmur", misspelling: nil)
        try store.saveEntry(id: entry.id, term: "Murmur", misspelling: "murmer")
        #expect(store.entries.count == 1)
        #expect(store.entries[0].id == entry.id)
        #expect(store.entries[0].misspelling == "murmer")
        store.deleteEntry(entry.id)
        #expect(store.entries.isEmpty)
    }

    // MARK: Snippets

    @Test func savesSnippetsNewestFirstAndKeepsExpansionAsTyped() throws {
        try store.saveSnippet(trigger: "my email address", expansion: "anton@example.com")
        try store.saveSnippet(trigger: " my calendar link ", expansion: "  https://cal.com/anton\n")
        #expect(store.snippets.map(\.trigger) == ["my calendar link", "my email address"])
        #expect(store.snippets[0].expansion == "  https://cal.com/anton\n")
    }

    @Test func snippetErrorsMatchTheServerRules() throws {
        #expect(throws: LibraryError.emptySnippet) { try store.saveSnippet(trigger: " ", expansion: "x") }
        #expect(throws: LibraryError.snippetTooLong) {
            try store.saveSnippet(trigger: String(repeating: "a", count: 60), expansion: "x")
        }
        #expect(throws: LibraryError.emptyExpansion) { try store.saveSnippet(trigger: "sig", expansion: " \n") }
        #expect(throws: LibraryError.expansionTooLong) {
            try store.saveSnippet(trigger: "sig", expansion: String(repeating: "a", count: 4001))
        }
        let saved = try store.saveSnippet(trigger: "My Email", expansion: "a@b.c")
        // Unique like the server's index: lower(btrim(trigger)).
        #expect(throws: LibraryError.duplicateSnippet) { try store.saveSnippet(trigger: " my email", expansion: "x") }
        try store.saveSnippet(id: saved.id, trigger: "my email", expansion: "new@b.c")
        #expect(store.snippets.map(\.expansion) == ["new@b.c"])
    }

    @Test func dictionaryAndSnippetChangesNotifyButNotesDont() throws {
        var calls = 0
        store.onChange = { calls += 1 }
        let entry = try store.saveEntry(term: "Anton", misspelling: nil)
        let snippet = try store.saveSnippet(trigger: "sig", expansion: "Best, Anton")
        store.deleteEntry(entry.id)
        store.deleteSnippet(snippet.id)
        #expect(calls == 4)
        var note = store.createNote()
        note.body = "Hello"
        store.updateNote(note)
        store.deleteNote(note.id)
        #expect(calls == 4)
        // A failed save changes nothing and says nothing.
        _ = try? store.saveEntry(term: "", misspelling: nil)
        #expect(calls == 4)
    }

    // MARK: Notes

    @Test func notesAreOrderedByLastEditAndBlankOnesAreDiscarded() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var first = store.createNote(now: start)
        let second = store.createNote(now: start.addingTimeInterval(60))
        first.body = "Milk, eggs"
        store.updateNote(first, now: start.addingTimeInterval(120))
        #expect(store.notes.map(\.id) == [first.id, second.id])
        store.discardIfEmpty(first.id)
        store.discardIfEmpty(second.id)
        #expect(store.notes.map(\.id) == [first.id])
    }

    @Test func deleteAllEmptiesEverything() throws {
        try store.saveEntry(term: "Anton", misspelling: nil)
        try store.saveSnippet(trigger: "sig", expansion: "Best")
        var note = store.createNote()
        note.title = "Ideas"
        store.updateNote(note)
        store.deleteAll()
        #expect(store.entries.isEmpty && store.snippets.isEmpty && store.notes.isEmpty)
    }

    @Test func noteTitleFallsBackToTheFirstLineThenTheDate() {
        let day = Date(timeIntervalSince1970: 1_794_182_400) // 2026-11-09
        #expect(Note(title: " Groceries ", body: "Milk", createdAt: day).displayTitle == "Groceries")
        #expect(Note(body: "\n  Pitch idea: a voice keyboard\nmore", createdAt: day).displayTitle
            == "Pitch idea: a voice keyboard")
        #expect(Note(body: "", createdAt: day).displayTitle == day.formatted(.dateTime.day().month(.abbreviated)))
        #expect(!Note(body: "One line").hasPreview)
        #expect(Note(body: "One line\nTwo").hasPreview)
    }
}

struct AccountQuotaTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func trialCountsDaysUsed() {
        let quota = AccountService.Quota(plan: "pro", onTrial: true, trialEndsAt: now.addingTimeInterval(7 * 86_400 - 60),
                                         wordsThisWeek: 300, weeklyLimit: nil, remaining: nil)
        #expect(quota.badge == "Pro Trial")
        #expect(quota.trialDaysLeft(now: now) == 7)
        #expect(quota.usageLine(now: now) == "7 of 14 days used in trial")
        #expect(quota.usageFraction(now: now) == 0.5)
    }

    @Test func basicCountsThisWeeksWords() {
        let quota = AccountService.Quota(plan: "basic", onTrial: false, trialEndsAt: now.addingTimeInterval(-86_400),
                                         wordsThisWeek: 250, weeklyLimit: 1000, remaining: 750)
        #expect(quota.badge == "Basic")
        #expect(quota.trialDaysLeft(now: now) == nil)
        #expect(quota.usageLine(now: now) == "250 of \(1000.formatted()) words used this week")
        #expect(quota.usageFraction(now: now) == 0.25)
    }

    @Test func paidProHasNothingToCount() {
        let quota = AccountService.Quota(plan: "pro", onTrial: false, trialEndsAt: nil,
                                         wordsThisWeek: 5000, weeklyLimit: nil, remaining: nil)
        #expect(quota.badge == "Pro")
        #expect(quota.usageLine(now: now) == nil)
        #expect(quota.chip(now: now) == "Pro")
        #expect(quota.usage(now: now) == nil)
    }

    /// The chip beside the wordmark counts the trial's days down.
    @Test func chipNamesThePlanAndTheDaysLeft() {
        func trial(daysLeft: Double) -> AccountService.Quota {
            AccountService.Quota(plan: "pro", onTrial: true, trialEndsAt: now.addingTimeInterval(daysLeft * 86_400),
                                 wordsThisWeek: 0, weeklyLimit: nil, remaining: nil)
        }
        #expect(trial(daysLeft: 5.5).chip(now: now) == "Trial · 6 days")
        #expect(trial(daysLeft: 0.2).chip(now: now) == "Trial · 1 day")
        #expect(trial(daysLeft: -1).chip(now: now) == "Trial")
        let basic = AccountService.Quota(plan: "basic", onTrial: false, trialEndsAt: nil,
                                         wordsThisWeek: 0, weeklyLimit: 1000, remaining: 1000)
        #expect(basic.chip(now: now) == "Basic")
    }

    /// The menu's meter: a segment a day for the two-week trial, ten for Basic's week, and a
    /// longer free stretch in proportion.
    @Test func usageFillsTheMenusMeter() {
        typealias Usage = AccountService.Quota.Usage
        let trial = AccountService.Quota(plan: "pro", onTrial: true, trialEndsAt: now.addingTimeInterval(6 * 86_400 - 60),
                                         wordsThisWeek: 300, weeklyLimit: nil, remaining: nil)
        #expect(trial.usage(now: now) == Usage(title: "Trial", detail: "8 of 14 days used", filled: 8, total: 14))

        let month = AccountService.Quota(plan: "pro", onTrial: true, trialEndsAt: now.addingTimeInterval(20 * 86_400 - 60),
                                         wordsThisWeek: 0, weeklyLimit: nil, remaining: nil,
                                         trialStartedAt: now.addingTimeInterval(-10 * 86_400))
        #expect(month.usage(now: now) == Usage(title: "Trial", detail: "10 of 30 days used", filled: 5, total: 14))

        func basic(words: Int) -> Usage? {
            AccountService.Quota(plan: "basic", onTrial: false, trialEndsAt: nil, wordsThisWeek: words,
                                 weeklyLimit: 1000, remaining: max(0, 1000 - words)).usage(now: now)
        }
        #expect(basic(words: 250) == Usage(title: "This week", detail: "250 of \(1000.formatted()) words used",
                                           filled: 3, total: 10))
        // Never empty once something is used, never full before everything is.
        #expect(basic(words: 0)?.filled == 0)
        #expect(basic(words: 12)?.filled == 1)
        #expect(basic(words: 990)?.filled == 9)
        #expect(basic(words: 1400)?.filled == 10)
    }

    @Test func decodesMyQuotaRows() throws {
        let json = #"[{"plan":"basic","on_trial":false,"trial_ends_at":null,"words_this_week":12,"weekly_limit":1000,"remaining":988}]"#
        let rows = try JSONDecoder().decode([AccountService.Quota].self, from: Data(json.utf8))
        #expect(rows.first?.remaining == 988)
        #expect(rows.first?.weeklyLimit == 1000)
    }
}
