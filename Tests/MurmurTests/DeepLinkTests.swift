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

    @Test @MainActor func initialPathOpensNestedScreens() {
        #expect(Router.initialPath(for: .languages) == [.settings, .languages])
        #expect(Router.initialPath(for: .debug) == [.settings, .debug])
        #expect(Router.initialPath(for: .home) == [])
        #expect(Router.initialPath(for: nil) == [])
    }
}
