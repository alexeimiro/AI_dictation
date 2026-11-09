import Foundation
import Observation

/// The tab bar's tabs, in order.
enum MainTab: String, Hashable, CaseIterable {
    case home, dictionary, snippets, style, scratchpad
}

/// Screens pushed on top of a tab's root.
enum Route: Hashable {
    case settings
    case languages
    case debug
    case transcript(UUID)
    case account
    case referral
    case note(UUID)
}

@MainActor
@Observable
final class Router {
    var tab: MainTab = .home
    /// Each tab keeps its own stack, like the system's tab bar apps.
    var paths: [MainTab: [Route]] = [:]
    /// The side menu (hamburger) is open.
    var isMenuOpen = false

    /// The selected tab's stack.
    var path: [Route] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue }
    }

    func open(_ route: Route) {
        path.append(route)
    }

    func popToRoot() {
        path.removeAll()
    }

    /// Closes the side menu and pushes `route` on Home, where the menu's screens live.
    func openFromMenu(_ route: Route) {
        isMenuOpen = false
        tab = .home
        paths[.home] = [route]
    }

    /// The stack to show for a `-route` launch argument (screenshot runs).
    static func initialPath(for route: LaunchRoute?) -> [Route] {
        switch route {
        case .settings: [.settings]
        case .languages: [.settings, .debug, .languages]
        case .debug: [.settings, .debug]
        case .account: [.account]
        case .referral: [.referral]
        case .home, .transcript, .swipeBack, .dictionary, .snippets, .style, .scratchpad, .menu, .paywall, nil: []
        }
    }

    /// The tab a `-route` launch argument opens.
    static func initialTab(for route: LaunchRoute?) -> MainTab {
        switch route {
        case .dictionary: .dictionary
        case .snippets: .snippets
        case .style: .style
        case .scratchpad: .scratchpad
        default: .home
        }
    }
}
