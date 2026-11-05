import Foundation
import Testing
@testable import Murmur

struct HostReturnTests {
    private let linkAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// A canary: when an iOS update removes what auto-return reads, this fails before users
    /// quietly lose it (they'd get the swipe-back screen every time).
    @MainActor
    @Test func uikitStillHasWhatAutoReturnReads() {
        #expect(HostReturn().isAvailable)
    }

    @Test func knownAppsReopenByTheirScheme() {
        #expect(HostAppCatalog.entry(forBundleID: "net.whatsapp.WhatsApp")?.url.absoluteString == "whatsapp://")
        #expect(HostAppCatalog.entry(forBundleID: "com.apple.mobilenotes")?.name == "Notes")
        #expect(HostAppCatalog.entry(forBundleID: "COM.APPLE.MOBILENOTES")?.name == "Notes")
        #expect(HostAppCatalog.entry(forBundleID: "com.apple.mobilesafari") == nil, "its scheme starts a search")
        #expect(HostAppCatalog.entry(forBundleID: "com.example.unknown") == nil)
    }

    @Test func murmurItselfIsNeverTheAppToGoBackTo() {
        var log = KeyboardHostLog(ownBundleID: "com.antonmironenko.murmur")
        log.record("net.whatsapp.WhatsApp", at: linkAt)
        log.record("com.antonmironenko.murmur", at: linkAt.addingTimeInterval(1))
        log.record("com.antonmironenko.murmur.keyboard", at: linkAt.addingTimeInterval(1))
        log.record("  ", at: linkAt.addingTimeInterval(1))
        #expect(log.recent(since: linkAt) == "net.whatsapp.WhatsApp")
    }

    @Test func onlyAFreshReportCounts() {
        var log = KeyboardHostLog(ownBundleID: "com.antonmironenko.murmur")
        let since = linkAt.addingTimeInterval(-KeyboardHostLog.lookBack)
        log.record("com.apple.mobilenotes", at: linkAt.addingTimeInterval(-60))
        #expect(log.recent(since: since) == nil, "from an earlier visit")

        log.record("ph.telegra.Telegraph", at: linkAt.addingTimeInterval(-2))
        #expect(log.recent(since: since) == "ph.telegra.Telegraph", "just before the link, as on a cold launch")

        log.record(" com.apple.MobileSMS\n", at: linkAt.addingTimeInterval(0.7))
        #expect(log.recent(since: since) == "com.apple.MobileSMS")
    }
}
