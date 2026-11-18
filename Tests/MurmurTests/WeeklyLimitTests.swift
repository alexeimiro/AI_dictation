import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// What the plan the app reads says about the free words, for the keyboard's mic and the session.
struct WeeklyLimitTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func settings() -> SharedSettings {
        SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.weekly.\(UUID().uuidString)"))
    }

    private func quota(plan: String, onTrial: Bool = false, remaining: Int?) -> AccountService.Quota {
        AccountService.Quota(plan: plan, onTrial: onTrial, trialEndsAt: nil, wordsThisWeek: 1_000 - (remaining ?? 0),
                             weeklyLimit: plan == "basic" ? 1_000 : nil, remaining: remaining)
    }

    /// Basic with no words left: used up until the next reset, also for words spent on the Mac.
    @Test func basicWithNoWordsLeftIsUsedUpUntilTheReset() {
        let shared = settings()
        AppModel.recordWordsLeft(quota(plan: "basic", remaining: 0), in: shared, now: now)
        #expect(shared.wordsUsedUpUntil == WeeklyWords.nextReset(after: now))
        #expect(shared.wordsUsedUp(at: now))
    }

    /// A later read of the same week keeps the reset it already has.
    @Test func aSecondReadKeepsTheReset() {
        let shared = settings()
        let earlier = WeeklyWords.nextReset(after: now)
        shared.wordsUsedUpUntil = earlier
        AppModel.recordWordsLeft(quota(plan: "basic", remaining: 0), in: shared, now: now.addingTimeInterval(60))
        #expect(shared.wordsUsedUpUntil == earlier)
    }

    /// The mark is the account's: signing out keeps it, the same account signing in again keeps it
    /// (offline, before its plan is read), another account starts without it.
    @Test func theMarkBelongsToTheAccountItWasSaidOf() throws {
        let shared = settings()
        let suite = "test.murmur.weekly.app.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let olga = UUID(), ivan = UUID()

        AppModel.keepWordsMark(for: olga, in: shared, defaults: defaults)
        shared.noteWordsUsedUp(at: now)
        AppModel.keepWordsMark(for: nil, in: shared, defaults: defaults)
        #expect(shared.wordsUsedUp(at: now))
        AppModel.keepWordsMark(for: olga, in: shared, defaults: defaults)
        #expect(shared.wordsUsedUp(at: now))
        AppModel.keepWordsMark(for: ivan, in: shared, defaults: defaults)
        #expect(shared.wordsUsedUpUntil == nil)
    }

    /// Pro, a trial, words left (a new week, an invite): the mic records again.
    @Test(arguments: [("pro", false, nil), ("pro", true, nil), ("basic", false, 250)] as [(String, Bool, Int?)])
    func anythingElseClearsIt(plan: String, onTrial: Bool, remaining: Int?) {
        let shared = settings()
        shared.noteWordsUsedUp(at: now)
        AppModel.recordWordsLeft(quota(plan: plan, onTrial: onTrial, remaining: remaining), in: shared, now: now)
        #expect(shared.wordsUsedUpUntil == nil)
        #expect(!shared.wordsUsedUp(at: now))
    }
}
