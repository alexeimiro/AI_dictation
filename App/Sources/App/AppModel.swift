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
        let history = HistoryStore.open(inMemory: launchOptions.useFixtures)
        self.history = history
        if launchOptions.useFixtures { HistoryFixtures.seed(history) }
        let cleanup = CleanupClient(backend: Backend.fromInfoPlist())
        let pipeline = DictationPipeline(cleanup: cleanup)
        self.pipeline = pipeline
        let assets = SpeechAssetManager()
        self.assets = assets
        let session = SessionController(transport: transport, pipeline: pipeline, assets: assets, history: history)
        self.session = session
        self.languages = LanguageSettingsModel(assets: assets, session: session)
        self.setup = SetupStatus(payloads: transport.payloads)
        LiveActivityActions.session = session
        settings.onRetentionChange = { [weak self] in self?.history.applyRetention() }
        router.path = Router.initialPath(for: launchOptions.route)
        if launchOptions.route == .swipeBack { showSwipeBack = true }
        if launchOptions.route == .transcript, let first = history.recent(limit: 1).first {
            router.path = [.transcript(first.id)]
        }
        history.applyRetention()
        recoverInterruptedDictations()
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
            if let token, transport.payloads.consumeLaunchToken(token, maxAge: 20, now: Date()) != nil {
                startSessionFromKeyboard(showSwipeBack: openedByAnotherApp)
            } else {
                confirmUntrustedStart = true
            }
        case .openSettings:
            showSwipeBack = false
            router.popToRoot()
            router.open(.settings)
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

    init?(url: URL) {
        guard url.scheme == Brand.urlScheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch (url.host, url.path) {
        case ("session", "/start"):
            self = .startSession(token: components?.queryItems?.first { $0.name == "t" }?.value)
        case ("settings", ""), ("settings", "/"):
            self = .openSettings
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
struct LaunchOptions: Equatable {
    var route: LaunchRoute?
    var useFixtures = false

    init(arguments: [String]) {
        route = LaunchRoute(arguments: arguments)
        useFixtures = arguments.contains("-fixtures")
    }
}
