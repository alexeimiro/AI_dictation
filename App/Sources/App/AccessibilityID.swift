/// Anchors for UI tests and screenshot harnesses that don't change when the copy does. This file
/// is compiled into the app and into the UI tests.
enum AccessibilityID {
    /// The button at the top left of a root screen that opens the menu.
    static let menuButton = "menu.open"
    /// The ✕ in the menu; it is there exactly while the menu is open.
    static let menuClose = "menu.close"
    /// One of the menu's five places: `menu.place.home`, `menu.place.scratchpad`, …
    static func menuPlace(_ name: String) -> String { "menu.place.\(name)" }
    static let menuUpgrade = "menu.upgrade"
    static let menuInvite = "menu.invite"
    static let menuHelp = "menu.help"
    static let menuSupport = "menu.support"
    static let menuSettings = "menu.settings"
    static let menuAccount = "menu.account"

    /// The element that tells which screen is showing: `screen.home`, `screen.settings`, …
    static func screen(_ name: String) -> String { "screen.\(name)" }

    /// Home's session control, in the bar at the bottom.
    static let sessionControl = "home.session"
    static let newNote = "home.newNote"
}
