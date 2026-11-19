import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// "Type as I speak" in the app: what it tells the keyboard about the plan
/// (`SharedSettings.planIsPro`), and its switch in Settings.
@MainActor
struct LiveTypingSettingTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func settings() -> SharedSettings {
        SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.livetyping.\(UUID().uuidString)"))
    }

    private func quota(plan: String, onTrial: Bool = false, trialEndsAt: Date? = nil) -> AccountService.Quota {
        AccountService.Quota(plan: plan, onTrial: onTrial, trialEndsAt: trialEndsAt, wordsThisWeek: 640,
                             weeklyLimit: plan == "basic" ? 1_000 : nil, remaining: plan == "basic" ? 360 : nil)
    }

    // MARK: The plan, for the keyboard

    /// Pro and its trial have it; Basic doesn't.
    @Test(arguments: [("pro", false, true), ("pro", true, true), ("basic", false, false)] as [(String, Bool, Bool)])
    func thePlanTheAppReadsSaysWhetherItIsPros(plan: String, onTrial: Bool, isPro: Bool) {
        let shared = settings()
        #expect(!shared.planIsPro, "nothing read yet")
        AppModel.recordWordsLeft(quota(plan: plan, onTrial: onTrial), in: shared, now: now)
        #expect(shared.planIsPro == isPro)
    }

    /// The trial ended, or the subscription did: the next read takes it back, and the user's
    /// switch stays as they left it.
    @Test func aPlanThatEndedTakesItBack() {
        let shared = settings()
        shared.liveTyping = true
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true), in: shared, now: now)
        #expect(shared.planIsPro)
        AppModel.recordWordsLeft(quota(plan: "basic"), in: shared, now: now)
        #expect(!shared.planIsPro)
        #expect(shared.liveTyping)
    }

    /// A trial can end while Murmur's session stays on in the background, where nothing reads
    /// the plan again. Its end goes to the keyboard with the plan, which stops being Pro's at
    /// that moment by itself. A subscription has no end to write.
    @Test func aTrialsEndGoesWithThePlan() {
        let shared = settings()
        let ends = Date().addingTimeInterval(3 * 86_400)
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: ends), in: shared, now: now)
        #expect(shared.planIsProUntil == ends)
        #expect(shared.planIsPro)
        #expect(shared.planIsPro(at: ends.addingTimeInterval(-1)))
        #expect(!shared.planIsPro(at: ends), "Basic from the moment the server says so")

        // A trial read whose end has passed since.
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: Date().addingTimeInterval(-60)),
                                 in: shared, now: now)
        #expect(!shared.planIsPro)
        shared.liveTyping = true
        #expect(!shared.typesAsSpoken(fullAccess: true))

        // Bought since: Pro, with no end.
        AppModel.recordWordsLeft(quota(plan: "pro"), in: shared, now: now)
        #expect(shared.planIsProUntil == nil)
        #expect(shared.planIsPro(at: .distantFuture))
        // The server sends a subscriber the end of the trial they once had: it is not the plan's.
        AppModel.recordWordsLeft(quota(plan: "pro", trialEndsAt: Date().addingTimeInterval(-86_400)), in: shared,
                                 now: now)
        #expect(shared.planIsProUntil == nil)
        #expect(shared.planIsPro)
        AppModel.recordWordsLeft(quota(plan: "pro", trialEndsAt: ends), in: shared, now: now)
        #expect(shared.planIsProUntil == nil)
        #expect(shared.planIsPro(at: .distantFuture))

        // Basic has none, and neither has a guest's plan.
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: ends), in: shared, now: now)
        AppModel.recordWordsLeft(quota(plan: "basic"), in: shared, now: now)
        #expect(shared.planIsProUntil == nil)
        #expect(!shared.planIsPro)
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: ends), in: shared, signedIn: false,
                                 now: now)
        #expect(shared.planIsProUntil == nil)
        #expect(!shared.planIsPro)
    }

    /// A guest's session has a plan of its own on the server. It is nobody's here, so it can't be
    /// left behind for the account that signs in after it.
    @Test func aGuestsPlanIsNeverPros() {
        let shared = settings()
        AppModel.recordWordsLeft(quota(plan: "pro"), in: shared, signedIn: false, now: now)
        #expect(!shared.planIsPro)
        // Nor does it keep an account's: the account is gone by then.
        shared.planIsPro = true
        AppModel.recordWordsLeft(quota(plan: "pro"), in: shared, signedIn: false, now: now)
        #expect(!shared.planIsPro)
    }

    /// The plan is the account's. Signed out (or the session lost), it is nobody's; the same
    /// account signing in again has it back only when its plan is read; another account never
    /// starts with it.
    @Test func thePlanGoesWithTheAccount() throws {
        let shared = settings()
        let suite = "test.murmur.livetyping.app.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let olga = UUID(), ivan = UUID()

        AppModel.keepWordsMark(for: olga, in: shared, defaults: defaults)
        AppModel.recordWordsLeft(quota(plan: "pro"), in: shared, now: now)
        // The next launch, the same account, before the plan is read (offline): still Pro's.
        AppModel.keepWordsMark(for: olga, in: shared, defaults: defaults)
        #expect(shared.planIsPro)

        AppModel.keepWordsMark(for: nil, in: shared, defaults: defaults)
        #expect(!shared.planIsPro)
        AppModel.keepWordsMark(for: olga, in: shared, defaults: defaults)
        #expect(!shared.planIsPro)

        AppModel.recordWordsLeft(quota(plan: "pro"), in: shared, now: now)
        #expect(shared.planIsPro)
        AppModel.keepWordsMark(for: ivan, in: shared, defaults: defaults)
        #expect(!shared.planIsPro)

        // A trial's end goes with the plan it was written for, to nobody and to another account.
        let ends = Date().addingTimeInterval(86_400)
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: ends), in: shared, now: now)
        AppModel.keepWordsMark(for: ivan, in: shared, defaults: defaults)
        #expect(shared.planIsProUntil == ends, "the same account keeps it")
        AppModel.keepWordsMark(for: olga, in: shared, defaults: defaults)
        #expect(shared.planIsProUntil == nil)
        #expect(!shared.planIsPro)
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: ends), in: shared, now: now)
        AppModel.keepWordsMark(for: nil, in: shared, defaults: defaults)
        #expect(shared.planIsProUntil == nil)
        #expect(!shared.planIsPro)

        // A trial past its end reads as not Pro's with its flag still set. Taking the date must
        // not make it Pro's again.
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: Date().addingTimeInterval(-60)),
                                 in: shared, now: now)
        #expect(!shared.planIsPro)
        AppModel.keepWordsMark(for: nil, in: shared, defaults: defaults)
        #expect(shared.planIsProUntil == nil)
        #expect(!shared.planIsPro)
        // Nor for another account that signs in after it.
        AppModel.keepWordsMark(for: olga, in: shared, defaults: defaults)
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: Date().addingTimeInterval(-60)),
                                 in: shared, now: now)
        AppModel.keepWordsMark(for: ivan, in: shared, defaults: defaults)
        #expect(shared.planIsProUntil == nil)
        #expect(!shared.planIsPro)
    }

    /// Signing out, or deleting the account, takes the plan from the keyboard, and the keyboard's
    /// note of the words it typed into a field: they are part of a dictation. The switch is the
    /// user's and stays.
    @Test func signingOutForgetsThePlanAndTheTypedWords() throws {
        let shared = settings()
        let payloads = IPCPayloadStore(container: .temporary())
        shared.liveTyping = true
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: Date().addingTimeInterval(86_400)),
                                 in: shared, now: now)
        try payloads.write(liveTyped: LiveTypedRecord(requestId: UUID(), typed: "So I was", updatedAt: now))
        #expect(shared.typesAsSpoken(fullAccess: true))

        AppModel.forgetPlanAndTypedWords(in: shared, payloads: payloads)
        #expect(!shared.planIsPro)
        #expect(shared.planIsProUntil == nil)
        #expect(payloads.readLiveTyped() == nil)
        #expect(shared.liveTyping)
        #expect(!shared.typesAsSpoken(fullAccess: true))

        // A trial past its end, as in `thePlanGoesWithTheAccount`.
        AppModel.recordWordsLeft(quota(plan: "pro", onTrial: true, trialEndsAt: Date().addingTimeInterval(-60)),
                                 in: shared, now: now)
        AppModel.forgetPlanAndTypedWords(in: shared, payloads: payloads)
        #expect(!shared.planIsPro)
    }

    // MARK: The switch in Settings

    /// Settings goes by the plan read since launch; before the first answer, by what the keyboard
    /// has (the last plan read for this account). Signed out, nothing is Pro's.
    @Test func settingsGoesByThePlanReadAndBeforeThatByTheLastOne() {
        #expect(AppModel.planIsPro(signedIn: true, quota: quota(plan: "pro"), stored: false))
        #expect(AppModel.planIsPro(signedIn: true, quota: quota(plan: "pro", onTrial: true), stored: false))
        #expect(!AppModel.planIsPro(signedIn: true, quota: quota(plan: "basic"), stored: true),
                "the plan just read counts, not the one before it")
        #expect(AppModel.planIsPro(signedIn: true, quota: nil, stored: true), "before the first answer")
        #expect(!AppModel.planIsPro(signedIn: true, quota: nil, stored: false))
        #expect(!AppModel.planIsPro(signedIn: false, quota: quota(plan: "pro"), stored: true),
                "a plan still in memory after the session was lost")
    }

    /// On a plan that lacks it the row's chip says whose the switch is, before a tap answers with
    /// Murmur Pro; on Pro and its trial it only says the feature is a beta.
    @Test func theRowSaysItIsProsWhereThePlanLacksIt() {
        #expect(SettingsModel.liveTypingBadge(planIsPro: true) == "Beta")
        #expect(SettingsModel.liveTypingBadge(planIsPro: false) == "Pro · Beta")
    }

    /// With Pro the switch is the user's, and saved at once for the keyboard.
    @Test func withProTheSwitchTurnsOnAndOff() {
        let shared = settings()
        let model = SettingsModel(settings: shared)
        #expect(!model.liveTyping, "off until the user turns it on")
        #expect(!model.typesAsSpoken(planIsPro: true))

        #expect(model.setLiveTyping(true, planIsPro: true))
        #expect(shared.liveTyping)
        #expect(model.typesAsSpoken(planIsPro: true))
        #expect(SettingsModel(settings: shared).liveTyping)

        #expect(model.setLiveTyping(false, planIsPro: true))
        #expect(!shared.liveTyping)
        #expect(!model.typesAsSpoken(planIsPro: true))
    }

    /// On Basic it can't be turned on: nothing is saved, and the caller shows Murmur Pro.
    @Test func withoutProTheSwitchStaysOffAndLeadsToPro() {
        let shared = settings()
        let model = SettingsModel(settings: shared)
        #expect(!model.setLiveTyping(true, planIsPro: false))
        #expect(!model.liveTyping)
        #expect(!shared.liveTyping)
        #expect(!model.typesAsSpoken(planIsPro: false))
    }

    /// Left on when the plan ended, it shows off and a tap leads to Pro; it is kept, and on again
    /// when Pro is back.
    @Test func aSwitchLeftOnWaitsForProToComeBack() {
        let shared = settings()
        shared.liveTyping = true
        let model = SettingsModel(settings: shared)
        #expect(!model.typesAsSpoken(planIsPro: false))
        #expect(!model.setLiveTyping(true, planIsPro: false))
        #expect(shared.liveTyping)
        #expect(model.typesAsSpoken(planIsPro: true))
    }
}
