import Foundation
import MurmurCore
import Testing
@testable import Murmur

struct DeepLinkTests {
    @Test func parsesSessionStartWithToken() {
        let url = URL(string: "murmur://session/start?t=abc123")!
        #expect(DeepLink(url: url) == .startSession(token: "abc123"))
    }

    @Test func parsesSettings() {
        #expect(DeepLink(url: URL(string: "murmur://settings")!) == .openSettings)
        #expect(DeepLink(url: URL(string: "murmur://settings/")!) == .openSettings)
    }

    /// The keyboard's limit message opens "Get unlimited words".
    @Test func parsesPro() {
        #expect(DeepLink(url: Brand.proURL) == .pro)
        #expect(DeepLink(url: URL(string: "murmur://pro/")!) == .pro)
        #expect(LaunchRoute(rawValue: "paywall") == .paywall)
    }

    @Test func ignoresOtherSchemesAndPaths() {
        #expect(DeepLink(url: URL(string: "https://session/start?t=x")!) == nil)
        #expect(DeepLink(url: URL(string: "murmur://session/stop")!) == nil)
    }

    @Test func parsesLaunchRoutes() {
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "swipeBack"]) == .swipeBack)
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "languages"]) == .languages)
        #expect(LaunchRoute(arguments: ["Murmur"]) == nil)
        for name in ["home", "settings", "languages", "debug", "transcript", "swipeBack", "dictionary", "snippets",
                     "style", "scratchpad", "menu", "account", "paywall", "referral", "note"] {
            #expect(LaunchRoute(arguments: ["Murmur", "-route", name])?.rawValue == name)
        }
        // What two screens are called now; their old names above still open them.
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "notes"]) == .scratchpad)
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "invite"]) == .referral)
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "nope"]) == nil)
    }

    @Test func parsesLaunchOptions() {
        let options = LaunchOptions(arguments: ["Murmur", "-route", "debug", "-fixtures"])
        #expect(options.route == .debug)
        #expect(options.useFixtures)
        #expect(!LaunchOptions(arguments: ["Murmur"]).useFixtures)
    }

    /// Screenshot runs fake the account and open the sign-in sheet (DEBUG builds only).
    @Test func parsesAccountLaunchOptions() {
        let options = LaunchOptions(arguments: [
            "Murmur", "-route", "home", "-account-state", "signedOut", "-account-email", "olga@example.com",
            "-account-sheet", "-fixtures",
        ])
        guard case .signedOut(let account) = options.accountState else {
            Issue.record("Expected a signed-out account, got \(String(describing: options.accountState))")
            return
        }
        #expect(account.email == "olga@example.com")
        #expect(options.accountSheet == .options)
        #expect(options.useFixtures)
        #expect(LaunchOptions(arguments: ["Murmur", "-account-sheet", "email"]).accountSheet == .email)
        #expect(LaunchOptions(arguments: ["Murmur", "-account-sheet", "guest"]).accountSheet == .confirmGuest)
        #expect(LaunchOptions(arguments: ["Murmur", "-account-state", "guest"]).accountState?.account.email == nil)
        let apple = LaunchOptions(arguments: ["Murmur", "-account-state", "guest", "-account-provider", "apple"])
        #expect(apple.accountState?.account.provider == "apple")
        #expect(LaunchOptions(arguments: ["Murmur", "-account-state", "nope"]).accountState == nil)
        // A signed-in account can't be faked without a session, which Auth would end at launch.
        #expect(LaunchOptions(arguments: ["Murmur", "-account-state", "signedIn"]).accountState == nil)
        #expect(LaunchOptions(arguments: ["Murmur"]).accountSheet == nil)
    }

    /// Screenshot runs pin the session's phase, so Home shows each state without a microphone
    /// (DEBUG builds only).
    @Test func parsesSessionFixtures() {
        func fixture(_ name: String) -> SessionController.Phase? {
            LaunchOptions(arguments: ["Murmur", "-route", "home", "-session-fixture", name]).sessionFixture
        }
        #expect(fixture("off") == .off)
        #expect(fixture("starting") == .starting)
        #expect(fixture("on") == .ready)
        #expect(fixture("reconnect") == .needsReconnect)
        if case .recording = fixture("listening") {} else { Issue.record("listening should pin a recording") }
        if case .processing = fixture("writing") {} else { Issue.record("writing should pin processing") }
        if case .failed(let message) = fixture("failed") {
            #expect(!message.isEmpty)
        } else {
            Issue.record("failed should pin a failure")
        }
        #expect(fixture("nope") == nil)
        #expect(LaunchOptions(arguments: ["Murmur"]).sessionFixture == nil)
    }

    /// Screenshot runs pick the plan and can leave the history empty (DEBUG builds only).
    @Test func parsesQuotaAndHistoryFixtures() {
        func quota(_ name: String) -> AccountService.Quota? {
            LaunchOptions(arguments: ["Murmur", "-fixtures", "-quota-fixture", name]).quotaFixture
        }
        #expect(quota("trial")?.onTrial == true)
        #expect(quota("basic")?.remaining == 360)
        #expect(quota("limit")?.remaining == 0)
        #expect(quota("pro")?.chip() == "Pro")
        #expect(quota("nope") == nil)
        #expect(LaunchOptions(arguments: ["Murmur", "-fixtures"]).quotaFixture == nil)
        #expect(LaunchOptions(arguments: ["Murmur", "-fixtures", "-history-fixture", "empty"]).emptyHistory)
        #expect(!LaunchOptions(arguments: ["Murmur", "-fixtures"]).emptyHistory)
        #expect(LaunchOptions(arguments: ["Murmur", "-fixtures", "-library-fixture", "empty"]).emptyLibrary)
        #expect(!LaunchOptions(arguments: ["Murmur", "-fixtures"]).emptyLibrary)
    }

    @Test @MainActor func initialPathOpensNestedScreens() {
        #expect(Router.initialPath(for: .languages) == [.settings, .debug, .languages])
        #expect(Router.initialPath(for: .debug) == [.settings, .debug])
        #expect(Router.initialPath(for: .home) == [])
        #expect(Router.initialPath(for: nil) == [])
        #expect(Router.initialPath(for: .account) == [.account])
        #expect(Router.initialTab(for: .snippets) == .snippets)
        #expect(Router.initialTab(for: .settings) == .home)
        #expect(Router.initialTab(for: .note) == .scratchpad)
    }

    @Test @MainActor func eachTabKeepsItsOwnStackAndTheMenuOpensOnHome() {
        let router = Router()
        let note = UUID()
        router.tab = .scratchpad
        router.open(.note(note))
        router.tab = .home
        #expect(router.path == [])
        router.isMenuOpen = true
        router.tab = .dictionary
        router.openFromMenu(.settings)
        #expect(!router.isMenuOpen)
        #expect(router.tab == .home)
        #expect(router.path == [.settings])
        #expect(router.paths[.scratchpad] == [.note(note)])
        router.popToRoot()
        #expect(router.path == [])
    }

    /// The menu lists the five places. Choosing one closes the menu and shows the place with
    /// whatever was open in it; choosing the place already on screen returns it to its root.
    @Test @MainActor func theMenuChoosesAPlace() {
        #expect(MainTab.menuOrder == [.home, .scratchpad, .dictionary, .snippets, .style])
        #expect(Set(MainTab.menuOrder) == Set(MainTab.allCases))
        #expect(MainTab.scratchpad.title == "Notes")
        let router = Router()
        let note = UUID()
        router.tab = .scratchpad
        router.open(.note(note))
        router.tab = .home
        router.isMenuOpen = true
        router.select(.scratchpad)
        #expect(!router.isMenuOpen)
        #expect(router.tab == .scratchpad)
        #expect(router.path == [.note(note)])
        router.isMenuOpen = true
        router.select(.scratchpad)
        #expect(!router.isMenuOpen)
        #expect(router.tab == .scratchpad)
        #expect(router.path == [])
    }
}
