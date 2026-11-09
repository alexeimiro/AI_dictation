import Foundation
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

    @Test func ignoresOtherSchemesAndPaths() {
        #expect(DeepLink(url: URL(string: "https://session/start?t=x")!) == nil)
        #expect(DeepLink(url: URL(string: "murmur://session/stop")!) == nil)
    }

    @Test func parsesLaunchRoutes() {
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "swipeBack"]) == .swipeBack)
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "languages"]) == .languages)
        #expect(LaunchRoute(arguments: ["Murmur"]) == nil)
        for name in ["home", "settings", "languages", "debug", "transcript", "swipeBack"] {
            #expect(LaunchRoute(rawValue: name) != nil)
        }
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

    @Test @MainActor func initialPathOpensNestedScreens() {
        #expect(Router.initialPath(for: .languages) == [.settings, .languages])
        #expect(Router.initialPath(for: .debug) == [.settings, .debug])
        #expect(Router.initialPath(for: .home) == [])
        #expect(Router.initialPath(for: nil) == [])
        #expect(Router.initialPath(for: .account) == [.account])
        #expect(Router.initialTab(for: .snippets) == .snippets)
        #expect(Router.initialTab(for: .settings) == .home)
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
}
