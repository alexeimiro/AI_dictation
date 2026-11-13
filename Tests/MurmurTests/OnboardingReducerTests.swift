import Foundation
import MurmurCore
import Testing
@testable import Murmur

struct OnboardingReducerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(at step: OnboardingStep, _ configure: (inout OnboardingRecord) -> Void = { _ in }) -> OnboardingRecord {
        var record = OnboardingRecord()
        record.step = step
        configure(&record)
        return record
    }

    private func reduce(_ record: OnboardingRecord, _ events: OnboardingEvent...) -> OnboardingRecord? {
        var current: OnboardingRecord? = record
        for event in events {
            guard let state = current else { return nil }
            current = OnboardingReducer.reduce(state, event, now: now)
        }
        return current
    }

    // MARK: The whole journey

    @Test func happyPathVisitsEveryStepInOrder() throws {
        var state = OnboardingRecord()
        var visited: [OnboardingStep] = [state.step]
        let script: [OnboardingEvent] = [
            .next,
            .toggleUseCase(.typeFaster), .next,
            .next,
            .showSignInOptions, .showEmailSignIn, .authenticated(.email),
            .next,
            .keyboardStatusChanged(added: true, fullAccess: false),
            .next,
            .permissionChanged(.microphone, .granted),
            .practiceCompleted(.basic), .next,
            .practiceCompleted(.formatting), .next,
            .next,
            .practiceCompleted(.whisper), .next,
            .next,
            .next,
            .selectDataChoice(.doNotShare, at: now), .next,
            .setLanguages(["en-US", "ru-RU"]), .next,
            .selectStyle(.grammar), .next,
            .permissionChanged(.notifications, .denied), .next,
            .desktopLinkDeclined,
            .selectReferral(.searchEngine), .next,
            .selectReferralDetail("DuckDuckGo"), .next,
            .next,
            .offerResolved(.trial(days: 14)), .next,
        ]
        for event in script {
            state = try #require(OnboardingReducer.reduce(state, event, now: now), "rejected \(event) on \(state.step)")
            if visited.last != state.step { visited.append(state.step) }
        }
        #expect(visited == OnboardingStep.allCases)
        #expect(state.isComplete)
        #expect(state.completedAt == now)
        #expect(state.practiceCommittedAt == now)
        #expect(state.answers.authMethod == .email)
        #expect(state.answers.languages == ["en-US", "ru-RU"])
        #expect(state.answers.style == .grammar)
        #expect(state.answers.referralDetail == "DuckDuckGo")
    }

    @Test func finishedOnboardingRejectsEverything() {
        let done = record(at: .complete)
        for event: OnboardingEvent in [.next, .back, .skipOptional, .sessionLinkOpened, .signInRequested,
                                       .permissionChanged(.microphone, .granted)] {
            #expect(OnboardingReducer.reduce(done, event, now: now) == nil)
        }
    }

    // MARK: Gates

    @Test(arguments: [
        OnboardingStep.useCases, .signIn, .signInOptions, .emailSignIn, .keyboardInstructions, .microphonePrimer,
        .basicPractice, .formattingPractice, .whisperPractice, .dataChoice, .languages, .defaultStyle,
        .notifications, .desktopOffer, .referralSource, .referralDetail, .trialOffer,
    ])
    func primaryActionWaitsForItsRequirement(step: OnboardingStep) {
        #expect(reduce(record(at: step), .next) == nil)
    }

    @Test func requirementsUnlockThePrimaryAction() {
        #expect(reduce(record(at: .useCases), .toggleUseCase(.emails), .next)?.step == .personalizedExplainer)
        #expect(reduce(record(at: .useCases), .toggleUseCase(.emails), .toggleUseCase(.emails), .next) == nil)
        #expect(reduce(record(at: .keyboardInstructions) { $0.permissions.keyboardAdded = true }, .next)?.step == .practiceIntro)
        #expect(reduce(record(at: .dataChoice), .selectDataChoice(.improveModel, at: now), .next)?.step == .languages)
        #expect(reduce(record(at: .languages), .setLanguages(["de-DE"]), .next)?.step == .defaultStyle)
        #expect(reduce(record(at: .defaultStyle), .selectStyle(.grammar), .next)?.step == .notifications)
        #expect(reduce(record(at: .notifications), .permissionChanged(.notifications, .granted), .next)?.step == .desktopOffer)
        #expect(reduce(record(at: .trialOffer), .offerResolved(.free), .next)?.step == .complete)
    }

    @Test func practiceIntroSkipsThePrimerWhenTheMicrophoneIsAllowed() {
        #expect(reduce(record(at: .practiceIntro), .next)?.step == .microphonePrimer)
        let granted = record(at: .practiceIntro) { $0.permissions.microphone = .granted }
        #expect(reduce(granted, .next)?.step == .basicPractice)
    }

    @Test func exercisesOnlyCompleteOnTheirOwnScreen() {
        #expect(reduce(record(at: .basicPractice), .practiceCompleted(.formatting)) == nil)
        let done = reduce(record(at: .basicPractice), .practiceCompleted(.basic), .practiceCompleted(.basic))
        #expect(done?.practiceDone == [.basic])
        #expect(done.flatMap { reduce($0, .next) }?.step == .formattingPractice)
    }

    @Test func answersOnlyChangeOnTheirOwnScreen() {
        #expect(reduce(record(at: .languages), .toggleUseCase(.emails)) == nil)
        #expect(reduce(record(at: .useCases), .selectStyle(.grammar)) == nil)
        #expect(reduce(record(at: .dataChoice), .setLanguages(["en-US"])) == nil)
        #expect(reduce(record(at: .signIn), .showEmailSignIn) == nil)
        #expect(reduce(record(at: .setupIntro), .authenticated(.apple)) == nil)
    }

    // MARK: Back and skip

    @Test func backFromEveryScreenThatHasOne() {
        let expected: [OnboardingStep: OnboardingStep] = [
            .useCases: .welcome, .personalizedExplainer: .useCases, .signIn: .personalizedExplainer,
            .signInOptions: .signIn, .emailSignIn: .signInOptions, .keyboardInstructions: .setupIntro,
            .microphonePrimer: .practiceIntro, .basicPractice: .practiceIntro,
            .formattingPractice: .basicPractice, .whisperIntro: .formattingPractice,
            .whisperPractice: .whisperIntro, .practiceComplete: .whisperPractice, .dataChoice: .wrapUpIntro,
            .languages: .dataChoice, .defaultStyle: .languages, .notifications: .defaultStyle,
            .desktopOffer: .notifications, .referralSource: .desktopOffer, .referralDetail: .referralSource,
        ]
        for step in OnboardingStep.allCases {
            let result = reduce(record(at: step), .back)?.step
            #expect(result == expected[step], "back from \(step)")
        }
    }

    @Test func goingBackKeepsTheAnswers() {
        let start = record(at: .signIn) { $0.answers.useCases = [.messages, .emails] }
        #expect(reduce(start, .back)?.answers.useCases == [.messages, .emails])
    }

    @Test func skipLeavesOptionalScreens() {
        #expect(reduce(record(at: .basicPractice), .skipOptional)?.step == .formattingPractice)
        #expect(reduce(record(at: .formattingPractice), .skipOptional)?.step == .whisperIntro)
        #expect(reduce(record(at: .whisperIntro), .skipOptional)?.step == .practiceComplete)
        #expect(reduce(record(at: .whisperPractice), .skipOptional)?.step == .practiceComplete)
        #expect(reduce(record(at: .defaultStyle), .skipOptional)?.step == .notifications)
        #expect(reduce(record(at: .notifications), .skipOptional)?.step == .desktopOffer)
        #expect(reduce(record(at: .dataChoice), .skipOptional) == nil)
        #expect(reduce(record(at: .referralSource), .skipOptional) == nil)
    }

    // MARK: Permissions and the keyboard

    @Test func addingTheKeyboardInSettingsMovesOn() {
        let waiting = record(at: .keyboardInstructions)
        #expect(reduce(waiting, .keyboardStatusChanged(added: false, fullAccess: false))?.step == .keyboardInstructions)
        let moved = reduce(waiting, .keyboardStatusChanged(added: true, fullAccess: false))
        #expect(moved?.step == .practiceIntro)
        #expect(moved?.permissions.keyboardAdded == true)
    }

    @Test func aKeyboardThatWasAlreadyAddedDoesNotSkipTheScreen() {
        let returning = record(at: .keyboardInstructions) { $0.permissions.keyboardAdded = true }
        #expect(reduce(returning, .keyboardStatusChanged(added: true, fullAccess: true))?.step == .keyboardInstructions)
    }

    @Test func confirmedKeyboardRequirementsStick() {
        let confirmed = record(at: .wrapUpIntro) {
            $0.permissions.keyboardAdded = true
            $0.permissions.fullAccessConfirmed = true
        }
        let after = reduce(confirmed, .keyboardStatusChanged(added: false, fullAccess: false))
        #expect(after?.permissions.keyboardAdded == true)
        #expect(after?.permissions.fullAccessConfirmed == true)
    }

    @Test func microphoneGrantOnThePrimerStartsPractice() {
        #expect(reduce(record(at: .microphonePrimer), .permissionChanged(.microphone, .granted))?.step == .basicPractice)
        #expect(reduce(record(at: .microphonePrimer), .permissionChanged(.microphone, .denied))?.step == .microphonePrimer)
        // A grant noticed elsewhere is recorded but doesn't move the user.
        let elsewhere = reduce(record(at: .dataChoice), .permissionChanged(.microphone, .granted))
        #expect(elsewhere?.step == .dataChoice)
        #expect(elsewhere?.permissions.microphone == .granted)
    }

    @Test func aDeniedMicrophoneCanSkipTheExercises() {
        #expect(reduce(record(at: .microphonePrimer), .skipOptional) == nil)
        let denied = record(at: .microphonePrimer) { $0.permissions.microphone = .denied }
        let skipped = reduce(denied, .skipOptional)
        #expect(skipped?.step == .wrapUpIntro)
        #expect(skipped?.practiceCommittedAt == nil)
    }

    @Test func sessionLinkGoesToTheMissingRequirementOnceSignedIn() {
        #expect(reduce(record(at: .useCases), .sessionLinkOpened)?.step == .useCases)
        #expect(reduce(record(at: .setupIntro), .sessionLinkOpened)?.step == .keyboardInstructions)
        let keyboardOnly = record(at: .dataChoice) { $0.permissions.keyboardAdded = true }
        #expect(reduce(keyboardOnly, .sessionLinkOpened)?.step == .microphonePrimer)
        let ready = record(at: .dataChoice) {
            $0.permissions.keyboardAdded = true
            $0.permissions.microphone = .granted
        }
        #expect(reduce(ready, .sessionLinkOpened)?.step == .dataChoice)
    }

    /// The keyboard's Log in, after a sign-out restarted onboarding: straight to signing in from
    /// the pages before it, and Back still leads to them. On a sign-in page or past them it does
    /// nothing (the app opens the sign-in sheet there instead).
    @Test func logInJumpsToSigningInFromThePagesBeforeIt() {
        for step: OnboardingStep in [.welcome, .useCases, .personalizedExplainer] {
            let jumped = reduce(record(at: step), .signInRequested)
            #expect(jumped?.step == .signIn, "from \(step)")
            #expect(jumped?.answers.useCases.isEmpty == true)
        }
        #expect(reduce(record(at: .welcome), .signInRequested, .back)?.step == .personalizedExplainer)
        for step: OnboardingStep in [.signIn, .signInOptions, .emailSignIn, .setupIntro, .basicPractice, .trialOffer] {
            #expect(reduce(record(at: step), .signInRequested) == nil, "from \(step)")
        }
    }

    // MARK: Answers

    @Test func dataChoiceRecordsPolicyVersionAndTime() {
        let decided = reduce(record(at: .dataChoice), .selectDataChoice(.improveModel, at: now))
        #expect(decided?.answers.dataChoice == DataChoiceDecision(
            choice: .improveModel, policyVersion: DataChoiceDecision.currentPolicyVersion, decidedAt: now))
    }

    @Test func dataSharingStartsUnchosen() {
        #expect(OnboardingRecord().answers.dataChoice == nil)
    }

    @Test func referralDetailOnlyFollowsSourcesThatHaveOne() {
        #expect(reduce(record(at: .referralSource), .selectReferral(.tikTok), .next)?.step == .ready)
        #expect(reduce(record(at: .referralSource), .selectReferral(.searchEngine), .next)?.step == .referralDetail)
        let detail = record(at: .referralDetail) { $0.answers.referralSource = .searchEngine }
        #expect(reduce(detail, .selectReferralDetail("AltaVista")) == nil)
        #expect(reduce(detail, .selectReferralDetail("Bing"), .next)?.step == .ready)
    }

    @Test func changingTheSourceClearsTheDetail() {
        let answered = record(at: .referralSource) {
            $0.answers.referralSource = .searchEngine
            $0.answers.referralDetail = "Google"
        }
        #expect(reduce(answered, .selectReferral(.searchEngine))?.answers.referralDetail == "Google")
        #expect(reduce(answered, .selectReferral(.linkedIn))?.answers.referralDetail == nil)
    }

    @Test func languagesAreDeduplicatedInOrder() {
        let set = reduce(record(at: .languages), .setLanguages(["ru-RU", "en-US", "ru-RU"]))
        #expect(set?.answers.languages == ["ru-RU", "en-US"])
    }

    @Test func desktopOfferNeedsAnExplicitAnswer() {
        #expect(reduce(record(at: .desktopOffer), .desktopLinkRequested(at: now))?.answers.desktopLink == .requested(now))
        #expect(reduce(record(at: .desktopOffer), .desktopLinkDeclined)?.step == .referralSource)
    }

    @Test func completionNeedsTheServerAnswer() {
        #expect(reduce(record(at: .ready), .offerResolved(.subscriber))?.answers.offer == .subscriber)
        #expect(reduce(record(at: .welcome), .offerResolved(.free)) == nil)
        let done = reduce(record(at: .trialOffer), .offerResolved(.trial(days: 14)), .next)
        #expect(done?.isComplete == true)
        #expect(done?.completedAt == now)
    }
}
