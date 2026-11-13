import Foundation
import Testing
@testable import Murmur

struct HostReturnTests {
    private let linkAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// A canary: when an iOS update removes what auto-return reads, this fails before users
    /// quietly lose it (they'd have to swipe back every time).
    @MainActor
    @Test func uikitStillHasWhatAutoReturnReads() {
        #expect(HostReturn().isAvailable)
    }

    @Test func knownAppsReopenByTheirScheme() {
        #expect(HostAppCatalog.entry(forBundleID: "net.whatsapp.WhatsApp")?.url.absoluteString == "whatsapp://")
        #expect(HostAppCatalog.entry(forBundleID: "com.apple.mobilenotes")?.name == "Notes")
        #expect(HostAppCatalog.entry(forBundleID: "com.apple.MobileSMS")?.url.absoluteString == "ichat://",
                "sms: and messages:// put a New Message sheet over the conversation")
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

    @Test func safariIsNamedThoughItCantBeReopened() {
        #expect(HostAppCatalog.name(forBundleID: safari) == "Safari")
        #expect(HostAppCatalog.name(forBundleID: telegram) == "Telegram")
        #expect(HostAppCatalog.name(forBundleID: "com.example.unknown") == nil)
    }

    // MARK: The return's rules (`ReturnPlan`)

    private let request = UUID()
    private let telegram = "ph.telegra.Telegraph"
    private let safari = "com.apple.mobilesafari"

    private func open(_ bundleID: String) -> ReturnPlan.Step {
        .open(HostAppCatalog.entry(forBundleID: bundleID)!)
    }

    /// The fault these rules replaced: the return had 3 s from the keyboard's link, so a start
    /// that took longer (the question "Before Murmur listens", a permission alert) sent nobody
    /// back.
    @Test func aStartHoweverSlowStillReturns() {
        var plan = ReturnPlan(requestId: request, autoReturn: true)
        #expect(plan.next(phase: .starting, presence: .active, host: nil, sinceLink: 0.1) == .wait)
        #expect(plan.next(phase: .starting, presence: .active, host: telegram, sinceLink: 19.9) == .wait)
        #expect(plan.next(phase: .recording(request), presence: .active, host: telegram, sinceLink: 20)
                == open(telegram))
        #expect(plan.recordingAt == 20)
    }

    /// As measured on an iPhone 16 Pro: the app is named about 0.9 s after the link, and the
    /// recording begins at about 1.1 s.
    @Test func aNormalStartReturnsAsSoonAsItRecords() {
        var plan = ReturnPlan(requestId: request, autoReturn: true)
        #expect(plan.next(phase: .starting, presence: .inactive, host: nil, sinceLink: 0.05) == .wait)
        #expect(plan.next(phase: .starting, presence: .active, host: telegram, sinceLink: 0.9) == .wait)
        #expect(plan.next(phase: .recording(request), presence: .active, host: telegram, sinceLink: 1.1)
                == open(telegram))
    }

    @Test func anAppNamedAfterTheRecordingBeganStillReturns() {
        var plan = ReturnPlan(requestId: request, autoReturn: true)
        #expect(plan.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 0.6) == .wait)
        #expect(plan.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 2.9) == .wait)
        #expect(plan.next(phase: .recording(request), presence: .active, host: telegram, sinceLink: 2.95)
                == open(telegram))
    }

    @Test func anAppNeverNamedIsGivenUpOnAfterTheWindow() {
        // After a quick start: 3 s from the link.
        var quick = ReturnPlan(requestId: request, autoReturn: true)
        #expect(quick.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 1) == .wait)
        #expect(quick.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 2.99) == .wait)
        #expect(quick.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 3)
                == .stop(.notLearned))
        // After a slow one: 1.5 s from the recording.
        var slow = ReturnPlan(requestId: request, autoReturn: true)
        #expect(slow.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 10) == .wait)
        #expect(slow.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 11.4) == .wait)
        #expect(slow.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 11.5)
                == .stop(.notLearned))
        #expect(ReturnOutcome.notLearned.hint == ReturnHint(appName: nil))
    }

    @Test func anAppThatCantBeReopenedIsGivenUpOnAtOnce() {
        var plan = ReturnPlan(requestId: request, autoReturn: true)
        #expect(plan.next(phase: .recording(request), presence: .active, host: safari, sinceLink: 1.1)
                == .stop(.notListed(host: safari)))
        #expect(ReturnOutcome.notListed(host: safari).hint?.text
                == "Swipe right along the bottom edge to go back to Safari")
        #expect(ReturnOutcome.notListed(host: "com.example.unknown").hint?.text
                == "Swipe right along the bottom edge to go back to your app")
    }

    @Test func withTheSwitchOffNothingIsOpenedButTheAppIsNamed() {
        var plan = ReturnPlan(requestId: request, autoReturn: false)
        #expect(plan.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 1) == .wait)
        #expect(plan.next(phase: .recording(request), presence: .active, host: telegram, sinceLink: 1.1)
                == .stop(.turnedOff(host: telegram)))
        #expect(ReturnOutcome.turnedOff(host: telegram).hint == ReturnHint(appName: "Telegram"))
        var unnamed = ReturnPlan(requestId: request, autoReturn: false)
        #expect(unnamed.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 1) == .wait)
        #expect(unnamed.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 3)
                == .stop(.turnedOff(host: nil)))
        #expect(ReturnOutcome.turnedOff(host: nil).hint == ReturnHint(appName: nil))
    }

    @Test func aStartThatFailedOrWasTurnedOffLeavesNothingToGoBackFor() {
        var plan = ReturnPlan(requestId: request, autoReturn: true)
        #expect(plan.next(phase: .failed("No microphone"), presence: .active, host: telegram, sinceLink: 1)
                == .stop(.sessionOff))
        #expect(plan.next(phase: .off, presence: .active, host: telegram, sinceLink: 1) == .stop(.sessionOff))
        #expect(ReturnOutcome.sessionOff.hint == nil)
    }

    /// Under an alert Murmur isn't in front and can't open another app, so it waits for the alert
    /// to go. Once the user has left Murmur, or a newer link took over, there is nothing to do.
    @Test func itWaitsUnderAnAlertAndStopsOnceMurmurIsLeft() {
        var plan = ReturnPlan(requestId: request, autoReturn: true)
        #expect(plan.next(phase: .recording(request), presence: .inactive, host: telegram, sinceLink: 1.1) == .wait)
        #expect(plan.next(phase: .recording(request), presence: .inactive, host: telegram, sinceLink: 6) == .wait)
        #expect(plan.next(phase: .recording(request), presence: .active, host: telegram, sinceLink: 6.1)
                == open(telegram))
        var left = ReturnPlan(requestId: request, autoReturn: true)
        #expect(left.next(phase: .starting, presence: .gone, host: nil, sinceLink: 0.5) == .stop(.left))
        #expect(left.next(phase: .recording(request), presence: .gone, host: telegram, sinceLink: 1.1)
                == .stop(.left))
        #expect(ReturnOutcome.left.hint == nil)
    }

    /// Right after some starts the audio route is rebuilt: the dictation stops and begins again.
    @Test func aDictationThatBeginsAgainWithinAMomentStillReturns() {
        var plan = ReturnPlan(requestId: request, autoReturn: true)
        #expect(plan.next(phase: .recording(request), presence: .active, host: nil, sinceLink: 1) == .wait)
        #expect(plan.next(phase: .ready, presence: .active, host: telegram, sinceLink: 1.2) == .wait)
        #expect(plan.next(phase: .needsReconnect, presence: .active, host: telegram, sinceLink: 1.9) == .wait)
        #expect(plan.next(phase: .recording(request), presence: .active, host: telegram, sinceLink: 2.4)
                == open(telegram))
    }

    @Test func aSessionThatIsOnWithoutTheDictationIsGivenUpOnAfterAMoment() {
        var plan = ReturnPlan(requestId: request, autoReturn: true)
        #expect(plan.next(phase: .ready, presence: .active, host: telegram, sinceLink: 1) == .wait)
        #expect(plan.next(phase: .ready, presence: .active, host: telegram, sinceLink: 2.4) == .wait)
        #expect(plan.next(phase: .ready, presence: .active, host: telegram, sinceLink: 2.5)
                == .stop(.notRecording(host: telegram)))
        // Another dictation is not this one, and this one being written is over.
        var other = ReturnPlan(requestId: request, autoReturn: true)
        #expect(other.next(phase: .recording(UUID()), presence: .active, host: telegram, sinceLink: 1) == .wait)
        #expect(other.next(phase: .processing(request), presence: .active, host: telegram, sinceLink: 2.5)
                == .stop(.notRecording(host: telegram)))
        #expect(ReturnOutcome.notRecording(host: telegram).hint == ReturnHint(appName: "Telegram"))
    }

    /// Every build logs the outcome's word, so it must not say which app someone types in.
    @Test func theLogWordNamesNoApp() {
        let outcomes: [ReturnOutcome] = [
            .returned(app: "Telegram"), .turnedOff(host: telegram), .notLearned, .notListed(host: safari),
            .couldNotOpen(app: "Telegram"), .notRecording(host: telegram), .sessionOff, .left,
        ]
        #expect(Set(outcomes.map(\.code)).count == outcomes.count)
        for outcome in outcomes {
            let lettersOnly = outcome.code.allSatisfy { $0.isLetter }
            #expect(lettersOnly, "\(outcome.code)")
            #expect(!outcome.code.localizedCaseInsensitiveContains("telegra"))
            #expect(!outcome.code.localizedCaseInsensitiveContains("safari"))
        }
        #expect(ReturnOutcome.returned(app: "Telegram").hint == nil)
        #expect(ReturnOutcome.couldNotOpen(app: "Telegram").hint == ReturnHint(appName: "Telegram"))
    }
}
