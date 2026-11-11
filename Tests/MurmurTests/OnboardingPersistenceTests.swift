import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
struct OnboardingPersistenceTests {
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: "test.murmur.onboarding.\(UUID().uuidString)")!
    }

    private func stored(_ json: String) -> OnboardingRecord? {
        defaults.set(Data(json.utf8), forKey: DefaultsOnboardingPersistence.key)
        return DefaultsOnboardingPersistence(defaults: defaults).load()
    }

    // MARK: Checkpoints

    @Test func everyAcceptedEventIsSavedAndResumed() {
        let persistence = DefaultsOnboardingPersistence(defaults: defaults)
        let store = OnboardingStore(persistence: persistence)
        store.send(.next)
        store.send(.toggleUseCase(.captureIdeas))
        store.send(.next)
        store.send(.next)
        #expect(store.step == .signIn)

        let relaunched = OnboardingStore(persistence: DefaultsOnboardingPersistence(defaults: defaults))
        #expect(relaunched.step == store.step)
        #expect(relaunched.answers.useCases == [.captureIdeas])
    }

    @Test func rejectedEventsDoNotTouchStorage() {
        let persistence = InMemoryOnboardingPersistence()
        let store = OnboardingStore(persistence: persistence)
        #expect(!store.send(.back))
        #expect(persistence.stored == nil)
    }

    @Test func keyboardSetupSurvivesTermination() {
        // Turning on Full Access can kill the app: the confirmed keyboard must be on disk already.
        let store = OnboardingStore(persistence: DefaultsOnboardingPersistence(defaults: defaults))
        for event: OnboardingEvent in [.next, .toggleUseCase(.emails), .next, .next, .authenticated(.apple), .next,
                                       .keyboardStatusChanged(added: true, fullAccess: false)] {
            store.send(event)
        }
        let relaunched = OnboardingStore(persistence: DefaultsOnboardingPersistence(defaults: defaults))
        #expect(relaunched.step == .practiceIntro)
        #expect(relaunched.permissions.keyboardAdded)
        #expect(relaunched.answers.authMethod == .apple)
    }

    @Test func existingInstallsSkipOnboarding() {
        let store = OnboardingStore(persistence: DefaultsOnboardingPersistence(defaults: defaults), legacyInstall: true)
        #expect(store.isComplete)
        #expect(store.record.historySeeded)
        // …and stay complete even if the legacy signal later disappears.
        let later = OnboardingStore(persistence: DefaultsOnboardingPersistence(defaults: defaults), legacyInstall: false)
        #expect(later.isComplete)
    }

    @Test func freshInstallStartsAtWelcome() {
        let store = OnboardingStore(persistence: DefaultsOnboardingPersistence(defaults: defaults))
        #expect(store.step == .welcome)
        #expect(!store.isComplete)
    }

    @Test func restartForgetsTheJourney() {
        let store = OnboardingStore(persistence: DefaultsOnboardingPersistence(defaults: defaults), legacyInstall: true)
        store.restart()
        #expect(store.step == .welcome)
        #expect(DefaultsOnboardingPersistence(defaults: defaults).load()?.step == .welcome)
    }

    // MARK: Migration

    @Test func renamedStepsMapToTheirReplacement() {
        #expect(stored(#"{"version":0,"step":"welcome2"}"#)?.step == .welcome)
        #expect(stored(#"{"version":0,"step":"keyboardSettingsRoundTrip"}"#)?.step == .keyboardInstructions)
    }

    @Test func unknownStepsResumeAtThePhaseTheUserReached() {
        #expect(stored(#"{"step":"teleport"}"#)?.step == .welcome)
        #expect(stored(#"{"step":"teleport","answers":{"authMethod":"google"}}"#)?.step == .setupIntro)
        #expect(stored(#"{"step":"teleport","answers":{"authMethod":"google"},"practiceCommittedAt":1}"#)?.step == .wrapUpIntro)
    }

    @Test func aFinishedRecordStaysFinished() {
        let record = stored(#"{"step":"trialOffer","completedAt":1000}"#)
        #expect(record?.step == .complete)
        #expect(record?.isComplete == true)
    }

    @Test func unknownOptionsAreDroppedAndTheVersionIsCurrent() {
        let record = stored(#"{"version":7,"step":"useCases","answers":{"useCases":["emails","telepathy"]},"practiceDone":["basic","juggling"]}"#)
        #expect(record?.answers.useCases == [.emails])
        #expect(record?.practiceDone == [.basic])
        #expect(record?.version == OnboardingRecord.currentVersion)
    }

    @Test func garbageIsIgnored() {
        #expect(stored("not json") == nil)
    }

    @Test func recordsRoundTrip() throws {
        var record = OnboardingRecord()
        record.step = .referralDetail
        record.answers.useCases = [.onTheGo, .messages]
        record.answers.dataChoice = DataChoiceDecision(choice: .doNotShare, policyVersion: 1, decidedAt: Date(timeIntervalSince1970: 5))
        record.answers.desktopLink = .requested(Date(timeIntervalSince1970: 6))
        record.answers.offer = .trial(days: 14)
        record.permissions.notifications = .denied
        record.practiceDone = [.basic, .whisper]
        let data = try JSONEncoder().encode(record)
        #expect(OnboardingMigration.decode(data) == record)
    }

    // MARK: Completion and history

    @Test func completionRunsOnceAndRetriesUntilHistoryIsSeeded() {
        var record = OnboardingRecord()
        record.step = .trialOffer
        record.answers.offer = .free
        let persistence = InMemoryOnboardingPersistence(record)
        var calls = 0
        let store = OnboardingStore(persistence: persistence)
        store.onComplete = { _ in calls += 1 }
        #expect(store.send(.next))
        #expect(calls == 1)
        #expect(!store.send(.next))
        #expect(calls == 1)

        // Terminated before seeding: the next launch finishes the job, then never again.
        let relaunched = OnboardingStore(persistence: persistence)
        relaunched.onComplete = { _ in calls += 1 }
        relaunched.resumePendingCompletion()
        #expect(calls == 2)
        relaunched.markHistorySeeded()
        relaunched.resumePendingCompletion()
        #expect(calls == 2)
    }

    @Test func practiceTakesReachHistoryOnceAfterCompletion() throws {
        let history = try HistoryStore(inMemory: true, settings: SharedSettings(defaults: defaults))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("practice-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let buffer = PracticeTranscriptBuffer(history: history, fileURL: file)

        buffer.activeExercise = .basic
        buffer.record(Transcript(rawText: "first try", cleanedText: "First try.", status: .cleaned))
        let retry = Transcript(rawText: "second try", cleanedText: "Second try.", status: .cleaned)
        buffer.record(retry)
        buffer.activeExercise = .whisper
        buffer.record(Transcript(rawText: "", status: .empty))
        buffer.activeExercise = nil
        buffer.record(Transcript(rawText: "from Notes", status: .raw))

        // Only the dictation made outside the exercises is in history so far.
        #expect(history.recent().map(\.rawText) == ["from Notes"])
        // A relaunch still has the takes.
        #expect(PracticeTranscriptBuffer(history: history, fileURL: file).latest[.basic]?.id == retry.id)

        buffer.flushToHistory()
        buffer.flushToHistory()
        let texts = history.recent().map(\.displayText)
        #expect(texts.filter { $0 == "Second try." }.count == 1)
        #expect(!texts.contains("First try."))
        #expect(history.count == 2)
        #expect(history.snapshot(retry.id)?.insertedAt != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

/// Small helpers the screens rely on.
struct OnboardingHelperTests {
    @Test func offerFollowsTheEntitlementRow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        #expect(SupabaseOfferProvider.variant(plan: "basic", source: "trial", trialEndsAt: now.addingTimeInterval(14 * day - 60),
                                              expiresAt: nil, now: now) == .trial(days: 14))
        #expect(SupabaseOfferProvider.variant(plan: "basic", source: "trial", trialEndsAt: now.addingTimeInterval(-60),
                                              expiresAt: nil, now: now) == .free)
        #expect(SupabaseOfferProvider.variant(plan: "pro", source: "app_store", trialEndsAt: nil,
                                              expiresAt: now.addingTimeInterval(day), now: now) == .subscriber)
        #expect(SupabaseOfferProvider.variant(plan: "pro", source: "app_store", trialEndsAt: nil,
                                              expiresAt: now.addingTimeInterval(-day), now: now) == .free)
    }

    @Test @MainActor func trialLengthReadsNaturally() {
        #expect(TrialOfferView.duration(14) == "2 weeks")
        #expect(TrialOfferView.duration(7) == "1 week")
        #expect(TrialOfferView.duration(10) == "10 days")
        #expect(TrialOfferView.duration(1) == "1 day")
    }

    /// The plan page's title spells out a number that opens it, and its lines keep the digits.
    @Test func theTrialIsNamedByItsLength() {
        #expect(OnboardingCopy.Offer.trialTitle(days: 14) == "Two weeks of Pro, on us")
        #expect(OnboardingCopy.Offer.trialTitle(days: 7) == "One week of Pro, on us")
        #expect(OnboardingCopy.Offer.trialTitle(days: 10) == "Ten days of Pro, on us")
        #expect(OnboardingCopy.Offer.trialTitle(days: 12) == "12 days of Pro, on us")
        #expect(OnboardingCopy.Offer.trialLine(days: 14) == "Unlimited words for 2 weeks. No card needed.")
        #expect(OnboardingCopy.Offer.trialCaption(days: 1) == "day of unlimited words")
        #expect(OnboardingCopy.Offer.trialCaption(days: 14) == "days of unlimited words")
    }

    /// The bar at the top counts four parts, in order; the pages that open a part, sign-in and
    /// the last two pages have no bar.
    @Test func everyStepWithABarBelongsToOnePartInOrder() {
        let parts = OnboardingStep.allCases.compactMap(OnboardingProgress.part(for:))
        #expect(parts == parts.sorted())
        #expect(Set(parts) == Set(1...OnboardingProgress.parts))
        for step in [OnboardingStep.welcome, .signIn, .signInOptions, .emailSignIn, .setupIntro, .practiceIntro,
                     .wrapUpIntro, .ready, .trialOffer, .complete] {
            #expect(OnboardingProgress.part(for: step) == nil, "\(step)")
        }
        // Skip is offered only where the journey's rules let a page be skipped.
        for step in OnboardingStep.allCases where OnboardingProgress.showsSkip(step) {
            #expect(OnboardingReducer.skipTarget(from: step) != nil, "\(step)")
        }
    }

    @Test @MainActor func emailValidation() {
        for valid in ["a@b.co", "  name.surname@mail.example.org ", "x+tag@domain.io"] {
            #expect(EmailSignInView.isValidEmail(valid), "\(valid)")
        }
        for invalid in ["", "plain", "a@b", "a@b.", "@b.co", "a@.co", "a b@c.co", "a@b@c.co"] {
            #expect(!EmailSignInView.isValidEmail(invalid), "\(invalid)")
        }
    }

    @Test func permissionFixturesParse() {
        let snapshot = PermissionSnapshot(fixture: "keyboard, fullAccess,mic=denied,notifications=granted")
        #expect(snapshot.keyboardAdded && snapshot.fullAccessConfirmed)
        #expect(snapshot.microphone == .denied)
        #expect(snapshot.notifications == .granted)
        #expect(PermissionSnapshot(fixture: "none") == PermissionSnapshot())
    }

    @Test func onboardingLaunchArguments() {
        let options = LaunchOptions(arguments: [
            "Murmur", "-onboarding-step", "basicPractice", "-onboarding-variant", "listening",
            "-permission-fixtures", "keyboard,mic=granted",
        ])
        #expect(options.onboardingStep == .basicPractice)
        #expect(options.onboardingVariant == "listening")
        #expect(options.permissionFixtures?.microphone == .granted)
        #expect(options.isOnboardingScreenshot && options.usesOnboardingFixtures)
        #expect(LaunchOptions(arguments: ["Murmur", "-onboarding-step", "nope"]).onboardingStep == nil)
        let journey = LaunchOptions(arguments: ["Murmur", "-onboarding-fixtures", "-onboarding-reset"])
        #expect(journey.usesOnboardingFixtures && journey.resetOnboarding && !journey.isOnboardingScreenshot)
    }

    @Test func authCallbackLinksAreRecognized() {
        let url = URL(string: "murmur://auth-callback?code=abc")!
        #expect(DeepLink(url: url) == .authCallback(url))
    }

    @Test func everyReferenceStateHasAFixture() {
        // Screenshot routes must open on the requested step with what that screen needs.
        for step in OnboardingStep.allCases {
            let record = OnboardingFixtures.record(step: step, variant: nil, permissions: nil)
            #expect(record.step == step)
        }
        let explainer = OnboardingFixtures.record(step: .personalizedExplainer, variant: nil, permissions: nil)
        #expect(!explainer.answers.useCases.isEmpty)
        let result = OnboardingFixtures.record(step: .formattingPractice, variant: "result", permissions: nil)
        #expect(result.isDone(.formatting))
        #expect(OnboardingFixtures.offer(variant: "offline") == nil)
    }
}
