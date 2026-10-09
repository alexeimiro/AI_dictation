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

    /// "Murmur is on — swipe back" after the keyboard opened us.
    var showSwipeBack = false
    /// A start link arrived without a valid one-time token (e.g. from a web page).
    var confirmUntrustedStart = false
    /// Screen forced with the `-route <name>` launch argument (screenshot tests).
    let launchRoute: LaunchRoute?
    /// When the app last became active; nil while inactive or in the background.
    @ObservationIgnored private var activeSince: Date?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let container = SharedContainer.appGroup() ?? .temporary()
        let transport = DarwinIPCTransport(container: container)
        self.transport = transport
        let cleanup = CleanupClient(backend: Backend.fromInfoPlist())
        self.session = SessionController(transport: transport, pipeline: DictationPipeline(cleanup: cleanup))
        self.setup = SetupStatus(payloads: transport.payloads)
        self.launchRoute = LaunchRoute(arguments: arguments)
        LiveActivityActions.session = session
        if launchRoute == .swipeBack { showSwipeBack = true }
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

    init?(url: URL) {
        guard url.scheme == Brand.urlScheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch (url.host, url.path) {
        case ("session", "/start"):
            self = .startSession(token: components?.queryItems?.first { $0.name == "t" }?.value)
        default:
            return nil
        }
    }
}

/// Screens reachable with `-route <name>` for screenshot comparison.
enum LaunchRoute: String {
    case swipeBack

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-route"), arguments.indices.contains(index + 1) else {
            return nil
        }
        self.init(rawValue: arguments[index + 1])
    }
}
