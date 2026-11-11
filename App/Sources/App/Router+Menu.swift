import Foundation

extension MainTab {
    /// The menu's places, top to bottom.
    static let menuOrder: [MainTab] = [.home, .scratchpad, .dictionary, .snippets, .style]

    /// The place's name in the menu and at the top of its screen. The scratchpad is called Notes.
    var title: String {
        switch self {
        case .home: "Home"
        case .scratchpad: "Notes"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .style: "Style"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .scratchpad: "doc.text"
        case .dictionary: "character.book.closed"
        case .snippets: "bolt"
        case .style: "pencil"
        }
    }
}

extension Router {
    /// The menu's choice of a place: closes the menu and shows the place, with whatever was open
    /// in it. Choosing the place already on screen returns it to its root.
    func select(_ place: MainTab) {
        isMenuOpen = false
        if tab == place {
            popToRoot()
        } else {
            tab = place
        }
    }
}
