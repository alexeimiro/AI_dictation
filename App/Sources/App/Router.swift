import Foundation
import Observation

/// Screens pushed on top of Home.
enum Route: Hashable {
    case settings
    case languages
    case debug
    case transcript(UUID)
}

@MainActor
@Observable
final class Router {
    var path: [Route] = []

    func open(_ route: Route) {
        path.append(route)
    }

    func popToRoot() {
        path.removeAll()
    }

    /// The stack to show for a `-route` launch argument (screenshot runs).
    static func initialPath(for route: LaunchRoute?) -> [Route] {
        switch route {
        case .settings: [.settings]
        case .languages: [.settings, .languages]
        case .debug: [.settings, .debug]
        case .home, .transcript, .swipeBack, nil: []
        }
    }
}
