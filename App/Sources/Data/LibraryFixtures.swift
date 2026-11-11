import Foundation
import MurmurCore

/// Words, snippets and notes for `-fixtures` screenshot runs (the store is in memory then).
enum LibraryFixtures {
    @MainActor
    static func seed(_ library: LibraryStore, now: Date = Date()) {
        try? library.saveEntry(term: "Anton", misspelling: nil)
        try? library.saveEntry(term: "Kubernetes", misspelling: "cooper netties")
        try? library.saveEntry(term: "by the way", misspelling: "btw")
        try? library.saveEntry(term: "Murmur", misspelling: nil)
        try? library.saveSnippet(trigger: "my calendar link", expansion: "https://cal.com/anton/30min")
        try? library.saveSnippet(trigger: "my email address", expansion: "anton@example.com")
        try? library.saveSnippet(
            trigger: "standup update",
            expansion: "Yesterday: shipped the keyboard redesign. Today: Dictionary and Snippets. Blockers: none.")
        var groceries = library.createNote(now: now.addingTimeInterval(-86_400))
        groceries.title = "Groceries"
        groceries.body = "Milk, eggs, sourdough, coffee beans and something for Friday's dinner."
        library.updateNote(groceries, now: now.addingTimeInterval(-86_000))
        var idea = library.createNote(now: now.addingTimeInterval(-3_600))
        idea.body = "Pitch idea: a voice keyboard that keeps your exact words and only fixes what you ask it to."
        library.updateNote(idea, now: now.addingTimeInterval(-3_500))
    }
}

extension AccountService.Quota {
    /// Halfway through the trial, for screenshots.
    static var fixture: AccountService.Quota {
        AccountService.Quota(plan: "pro", onTrial: true, trialEndsAt: Date().addingTimeInterval(7 * 86_400 - 60),
                             wordsThisWeek: 1_240, weeklyLimit: nil, remaining: nil)
    }

    /// The plans `-quota-fixture <name>` shows: `trial`, `basic` (some of the week's words used),
    /// `limit` (all of them used) and `pro` (a subscription).
    static func fixture(named name: String) -> AccountService.Quota? {
        switch name {
        case "trial": fixture
        case "basic":
            AccountService.Quota(plan: "basic", onTrial: false, trialEndsAt: nil, wordsThisWeek: 640,
                                 weeklyLimit: 1000, remaining: 360)
        case "limit":
            AccountService.Quota(plan: "basic", onTrial: false, trialEndsAt: nil, wordsThisWeek: 1000,
                                 weeklyLimit: 1000, remaining: 0)
        case "pro":
            AccountService.Quota(plan: "pro", onTrial: false, trialEndsAt: nil, wordsThisWeek: 5_200,
                                 weeklyLimit: nil, remaining: nil)
        default: nil
        }
    }
}
