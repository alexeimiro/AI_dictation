import Foundation
import Testing
@testable import Murmur

struct DeepLinkTests {
    @Test func parsesSessionStartWithToken() {
        let url = URL(string: "murmur://session/start?t=abc123")!
        #expect(DeepLink(url: url) == .startSession(token: "abc123"))
    }

    @Test func ignoresOtherSchemesAndPaths() {
        #expect(DeepLink(url: URL(string: "https://session/start?t=x")!) == nil)
        #expect(DeepLink(url: URL(string: "murmur://session/stop")!) == nil)
    }

    @Test func parsesLaunchRoute() {
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "swipeBack"]) == .swipeBack)
        #expect(LaunchRoute(arguments: ["Murmur"]) == nil)
    }
}
