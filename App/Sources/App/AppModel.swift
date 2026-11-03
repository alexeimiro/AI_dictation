import Foundation
import MurmurCore
import Observation
import SwiftUI

/// Root state shared through the environment.
@MainActor
@Observable
final class AppModel {
    let transport: IPCTransport
    let session: SessionController
    let setup: SetupStatus
    let assets: SpeechAssetManager
    let languages: LanguageSettingsModel
    let history: HistoryStore
    let settings = SettingsModel()
    let pipeline: DictationPipeline
    let onboarding: OnboardingStore
    let onboardingServices: OnboardingServices
    /// Holds practice dictations until onboarding completes; passes everything else to history.
    let practiceBuffer: PracticeTranscriptBuffer
    let practice: any PracticeDictationClient

    /// "Murmur is on — swipe back" after the keyboard opened us.
    var showSwipeBack = false
    /// A start link arrived without a valid one-time token (e.g. from a web page).
    var confirmUntrustedStart = false
    let router = Router()
    /// `-route <name>` and `-fixtures` launch arguments (screenshot runs).
    let launchOptions: LaunchOptions
    var launchRoute: LaunchRoute? { launchOptions.route }
    /// When the app last became active; nil while inactive or in the background.
    @ObservationIgnored private var activeSince: Date?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let container = SharedContainer.appGroup() ?? .temporary()
        let transport = DarwinIPCTransport(container: container)
        self.transport = transport
        let launchOptions = LaunchOptions(arguments: arguments)
        self.launchOptions = launchOptions
        let history = HistoryStore.open(inMemory: launchOptions.useFixtures || launchOptions.isOnboardingScreenshot)
        self.history = history
        if launchOptions.useFixtures { HistoryFixtures.seed(history) }
        if launchOptions.onboardingStep == .complete { OnboardingFixtures.seedCompletedHistory(history) }
        let backend = Backend.fromInfoPlist()
        let cleanup = CleanupClient(backend: backend)
        let pipeline = DictationPipeline(cleanup: cleanup)
        self.pipeline = pipeline
        let assets = SpeechAssetManager()
        self.assets = assets
        let practiceBuffer = PracticeTranscriptBuffer(
            history: history, fileURL: launchOptions.usesOnboardingFixtures ? nil : PracticeTranscriptBuffer.defaultFileURL)
        self.practiceBuffer = practiceBuffer
        let session = SessionController(transport: transport, pipeline: pipeline, assets: assets, history: practiceBuffer)
        self.session = session
        self.languages = LanguageSettingsModel(assets: assets, session: session)
        self.setup = SetupStatus(payloads: transport.payloads)
        if launchOptions.usesOnboardingFixtures {
            onboardingServices = .fixtures(offer: OnboardingFixtures.offer(variant: launchOptions.onboardingVariant))
            practice = ScriptedPracticeClient(
                state: OnboardingFixtures.practiceState(step: launchOptions.onboardingStep,
                                                        variant: launchOptions.onboardingVariant))
        } else {
            onboardingServices = .production(backend: backend)
            practice = SessionPracticeClient(session: session, buffer: practiceBuffer)
        }
        onboarding = Self.makeOnboardingStore(
            launchOptions: launchOptions,
            legacyInstall: !history.isEmpty || transport.payloads.readKeyboardStatus() != nil)
        LiveActivityActions.session = session
        settings.onRetentionChange = { [weak self] in self?.history.applyRetention() }
        onboarding.onComplete = { [weak self] record in self?.onboardingDidComplete(record) }
        if !launchOptions.usesOnboardingFixtures {
            setup.onChange = { [weak self] in self?.forwardSetupStatus() }
            forwardSetupStatus()
        }
        onboarding.resumePendingCompletion()
        router.path = Router.initialPath(for: launchOptions.route)
        if launchOptions.route == .swipeBack { showSwipeBack = true }
        if launchOptions.route == .transcript, let first = history.recent(limit: 1).first {
            router.path = [.transcript(first.id)]
        }
        history.applyRetention()
        recoverInterruptedDictations()
    }

    /// The persisted checkpoint, or a throwaway one for screenshot routes and UI tests.
    private static func makeOnboardingStore(launchOptions: LaunchOptions, legacyInstall: Bool) -> OnboardingStore {
        if let step = launchOptions.onboardingStep {
            let record = OnboardingFixtures.record(
                step: step, variant: launchOptions.onboardingVariant, permissions: launchOptions.permissionFixtures)
            return OnboardingStore(persistence: InMemoryOnboardingPersistence(record))
        }
        if launchOptions.route != nil || launchOptions.useFixtures {
            var done = OnboardingRecord()
            done.step = .complete
            done.historySeeded = true
            return OnboardingStore(persistence: InMemoryOnboardingPersistence(done))
        }
        if launchOptions.onboardingFixtures {
            // UI tests: a separate suite, so the journey can be terminated and resumed.
            let persistence = DefaultsOnboardingPersistence(defaults: UserDefaults(suiteName: "murmur.uitests.onboarding"))
            if launchOptions.resetOnboarding { persistence.clear() }
            return OnboardingStore(persistence: persistence)
        }
        let persistence = DefaultsOnboardingPersistence()
        if launchOptions.resetOnboarding { persistence.clear() }
        return OnboardingStore(persistence: persistence, legacyInstall: legacyInstall && !launchOptions.resetOnboarding)
    }

    /// Keeps the onboarding checkpoint in step with what the user changed in Settings.
    private func forwardSetupStatus() {
        guard !onboarding.isComplete else { return }
        // A keyboard that has reported Full Access has necessarily been added, even when the
        // input-mode check (best effort) misses it.
        onboarding.send(.keyboardStatusChanged(
            added: setup.keyboardAdded || setup.fullAccessConfirmed, fullAccess: setup.fullAccessConfirmed))
        onboarding.send(.permissionChanged(.microphone, PermissionState(setup.microphone)))
    }

    private func refreshNotificationPermission() {
        guard !onboarding.isComplete, !launchOptions.usesOnboardingFixtures else { return }
        Task {
            let state = await onboardingServices.notifications.status()
            onboarding.send(.permissionChanged(.notifications, state))
        }
    }

    // MARK: Onboarding actions (faked under -onboarding-fixtures, so tests never leave the app)

    /// "Go to Settings" on the keyboard setup screen.
    func openKeyboardSettings() {
        if launchOptions.usesOnboardingFixtures {
            onboarding.send(.keyboardStatusChanged(added: true, fullAccess: true))
        } else {
            setup.openSettings()
        }
    }

    /// The system microphone prompt (shown once; later calls report the decision).
    func requestMicrophone() async -> PermissionState {
        if launchOptions.usesOnboardingFixtures {
            let state = PermissionState.granted
            onboarding.send(.permissionChanged(.microphone, state))
            return state
        }
        await setup.requestMicrophone()
        return PermissionState(setup.microphone)
    }

    func requestNotifications() async -> PermissionState {
        let state = await onboardingServices.notifications.request()
        onboarding.send(.permissionChanged(.notifications, state))
        return state
    }

    /// After the final screen: practice takes go to history (once), answers to the profile.
    private func onboardingDidComplete(_ record: OnboardingRecord) {
        practiceBuffer.activeExercise = nil
        practiceBuffer.flushToHistory()
        onboarding.markHistorySeeded()
        let answers = record.answers
        Task { await onboardingServices.profile.sync(answers) }
    }

    /// Dictations whose cleanup never finished keep their raw transcript; a recent one is
    /// offered to the keyboard again, which makes "Your dictation will be saved in Murmur" true.
    private func recoverInterruptedDictations() {
        let now = Date()
        for transcript in history.recoverInterrupted(now: now)
        where transcript.isInsertable && now.timeIntervalSince(transcript.createdAt) < 600 {
            history.republish(transcript.id, payloads: transport.payloads, transport: transport, now: now)
        }
    }

    /// Re-runs the cleanup on a stored transcript. Returns a message when it failed.
    func regenerate(_ id: UUID) async -> String? {
        guard let transcript = history.snapshot(id) else { return "Transcript not found" }
        do {
            let updated = try await pipeline.recleanup(transcript)
            history.upsert(updated)
            return nil
        } catch {
            switch error {
            case .notConfigured: return "Cleanup isn't configured on this build"
            case .limitReached: return "Dictation limit reached"
            case .rateLimited: return "Too many requests; try again in a minute"
            case .unavailable(let reason): return "Cleanup unavailable: \(reason)"
            }
        }
    }

    /// Offers a transcript to the keyboard as "Insert last dictation".
    func insertViaKeyboard(_ id: UUID) -> Bool {
        history.republish(id, payloads: transport.payloads, transport: transport)
    }

    func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        switch link {
        case .startSession(let token):
            if !onboarding.isComplete {
                setup.refresh()
                onboarding.send(.sessionLinkOpened)
                // Without the microphone there is no session to start; onboarding now shows
                // the missing step instead.
                guard setup.microphone == .granted else { return }
            }
            if let token, transport.payloads.consumeLaunchToken(token, maxAge: 20, now: Date()) != nil {
                startSessionFromKeyboard(showSwipeBack: openedByAnotherApp)
            } else {
                confirmUntrustedStart = true
            }
        case .openSettings:
            showSwipeBack = false
            guard onboarding.isComplete else { return }
            router.popToRoot()
            router.open(.settings)
        case .authCallback(let url):
            Task { _ = await onboardingServices.auth.handleCallback(url) }
        }
    }

    /// The keyboard opened us to start a session. When it was used in another app, show
    /// "swipe back"; when it was used inside Murmur itself there's nowhere to go back to, so just
    /// start the session (the keyboard starts recording once the session is ready).
    func startSessionFromKeyboard(showSwipeBack: Bool = true) {
        self.showSwipeBack = showSwipeBack
        Task { await session.start() }
    }

    /// True unless the app had already been active for a while when the link arrived, which
    /// means it came from our own keyboard in one of Murmur's text fields.
    private var openedByAnotherApp: Bool {
        guard let activeSince else { return true }
        return Date().timeIntervalSince(activeSince) < 1
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if activeSince == nil { activeSince = Date() }
            setup.refresh()
            refreshNotificationPermission()
            session.appDidBecomeActive()
            history.applyRetention()
            history.reconcileInsertions(payloads: transport.payloads)
        case .background:
            activeSince = nil
            showSwipeBack = false
        case .inactive:
            activeSince = nil
        default:
            break
        }
    }
}

enum DeepLink: Equatable {
    /// `murmur://session/start?t=<one-time token>` — opened by the keyboard.
    case startSession(token: String?)
    /// `murmur://settings` — the keyboard's settings button.
    case openSettings
    /// `murmur://auth-callback?…` — the emailed sign-in link and OAuth redirects.
    case authCallback(URL)

    init?(url: URL) {
        guard url.scheme == Brand.urlScheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch (url.host, url.path) {
        case ("session", "/start"):
            self = .startSession(token: components?.queryItems?.first { $0.name == "t" }?.value)
        case ("settings", ""), ("settings", "/"):
            self = .openSettings
        case ("auth-callback", _):
            self = .authCallback(url)
        default:
            return nil
        }
    }
}

/// Screens reachable with `-route <name>` for screenshot comparison.
enum LaunchRoute: String {
    case home, settings, languages, debug, transcript, swipeBack

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-route"), arguments.indices.contains(index + 1) else {
            return nil
        }
        self.init(rawValue: arguments[index + 1])
    }
}

/// Launch arguments: `-route <name>` opens a screen, `-fixtures` seeds an in-memory history.
///
/// Onboarding (screenshots and UI tests only):
/// - `-onboarding-step <step>` opens that screen with fixture data and services
/// - `-onboarding-variant <name>` picks one of its states (see `OnboardingFixtures`)
/// - `-permission-fixtures <list>` fixes the setup state, e.g. `keyboard,fullAccess,mic=granted`
/// - `-onboarding-fixtures` runs the whole journey on fake services with its own checkpoint
/// - `-onboarding-reset` starts the journey over
struct LaunchOptions: Equatable {
    var route: LaunchRoute?
    var useFixtures = false
    var onboardingStep: OnboardingStep?
    var onboardingVariant: String?
    var permissionFixtures: PermissionSnapshot?
    var onboardingFixtures = false
    var resetOnboarding = false

    init(arguments: [String]) {
        route = LaunchRoute(arguments: arguments)
        useFixtures = arguments.contains("-fixtures")
        onboardingStep = Self.value(after: "-onboarding-step", in: arguments).flatMap(OnboardingStep.init(rawValue:))
        onboardingVariant = Self.value(after: "-onboarding-variant", in: arguments)
        permissionFixtures = Self.value(after: "-permission-fixtures", in: arguments).map(PermissionSnapshot.init(fixture:))
        onboardingFixtures = arguments.contains("-onboarding-fixtures")
        resetOnboarding = arguments.contains("-onboarding-reset")
    }

    /// A screenshot route into onboarding: nothing persists and nothing prompts.
    var isOnboardingScreenshot: Bool { onboardingStep != nil }

    /// Fake auth, offers, permissions and dictation.
    var usesOnboardingFixtures: Bool { isOnboardingScreenshot || onboardingFixtures }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
