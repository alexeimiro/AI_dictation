import Foundation
import Testing
@testable import MurmurCore

struct SessionPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Idle stop

    @Test func noCountdownWhileTheAppIsOnScreen() {
        #expect(IdleStop.date(timeout: 300, idleSince: now, backgroundSince: nil, keyboard: nil) == nil)
    }

    @Test func countsFromTheLastDictationOrTheAppLeavingTheScreen() {
        let left = now.addingTimeInterval(60)
        #expect(IdleStop.date(timeout: 300, idleSince: now, backgroundSince: left, keyboard: nil)
            == left.addingTimeInterval(300))
        #expect(IdleStop.date(timeout: 300, idleSince: left, backgroundSince: now, keyboard: nil)
            == left.addingTimeInterval(300))
    }

    @Test func typingOnTheKeyboardKeepsTheSessionOn() {
        // Dictated at `now`, then typed for ten minutes; the last heartbeat was just now.
        let lastSeen = now.addingTimeInterval(600)
        let keyboard = KeyboardStatus(fullAccessAt: lastSeen, lastSeenAt: lastSeen)
        let stop = IdleStop.date(timeout: 300, idleSince: now, backgroundSince: now, keyboard: keyboard)
        #expect(stop == lastSeen.addingTimeInterval(IdleStop.keyboardGrace + 300))
    }

    @Test func theCountdownRestartsWhenTheKeyboardGoesAway() {
        let hidden = now.addingTimeInterval(600)
        let keyboard = KeyboardStatus(fullAccessAt: hidden, lastSeenAt: hidden, hiddenAt: hidden)
        #expect(IdleStop.date(timeout: 300, idleSince: now, backgroundSince: now, keyboard: keyboard)
            == hidden.addingTimeInterval(300))
    }

    @Test func anOldHiddenKeyboardDoesNotDelayTheStop() {
        let keyboard = KeyboardStatus(fullAccessAt: nil, lastSeenAt: now.addingTimeInterval(-3600),
                                      hiddenAt: now.addingTimeInterval(-3600))
        #expect(IdleStop.date(timeout: 300, idleSince: now, backgroundSince: now, keyboard: keyboard)
            == now.addingTimeInterval(300))
    }

    @Test func aKeyboardThatVanishedWithoutSayingSoCountsAsGoneSoon() {
        // A hide from an earlier visit, then heartbeats until it was suspended.
        let keyboard = KeyboardStatus(fullAccessAt: nil, lastSeenAt: now, hiddenAt: now.addingTimeInterval(-900))
        #expect(keyboard.inactiveSince == now.addingTimeInterval(IdleStop.keyboardGrace))
    }

    // MARK: Interruptions

    @Test func interruptionsResumeLikeWisprFlow() {
        #expect(DisableAfter.never.resumesAfterInterruption(lasting: 7200))
        #expect(DisableAfter.fiveMinutes.resumesAfterInterruption(lasting: 120))
        #expect(!DisableAfter.fiveMinutes.resumesAfterInterruption(lasting: 400))
        #expect(DisableAfter.oneHour.resumesAfterInterruption(lasting: 1800))
        #expect(!DisableAfter.immediately.resumesAfterInterruption(lasting: 1))
    }

    // MARK: Files from the previous version

    @Test func filesWrittenBeforeTheseFieldsStillDecode() throws {
        let container = SharedContainer.temporary()
        let requestId = UUID()
        let pendingURL = container.url("pending.json")
        try FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"requestId":"\#(requestId.uuidString)","createdAt":1800000000000}"#.utf8).write(to: pendingURL)
        let pending = try #require(JSONFile.read(PendingStart.self, from: pendingURL))
        #expect(pending.requestId == requestId)
        #expect(pending.autoStart == nil)
        #expect(pending.styleOverride == nil)

        let statusURL = container.url("status.json")
        try Data(#"{"lastSeenAt":1800000000000}"#.utf8).write(to: statusURL)
        let status = try #require(JSONFile.read(KeyboardStatus.self, from: statusURL))
        #expect(status.hiddenAt == nil)
        #expect(status.inactiveSince == status.lastSeenAt.addingTimeInterval(IdleStop.keyboardGrace))
    }

    @Test func clearingAnotherRequestsPendingStartKeepsIt() throws {
        let payloads = IPCPayloadStore(container: .temporary())
        let pending = PendingStart(requestId: UUID(), documentIdentifier: nil, createdAt: now, autoStart: true)
        try payloads.write(pendingStart: pending)
        payloads.clearPendingStart(UUID())
        #expect(payloads.readPendingStart() == pending)
        payloads.clearPendingStart(pending.requestId)
        #expect(payloads.readPendingStart() == nil)
    }

    @Test func aDroppedDictationDoesNotReplaceTheLatestResult() throws {
        let payloads = IPCPayloadStore(container: .temporary())
        let kept = DictationResult(requestId: UUID(), documentIdentifier: nil, text: "Kept.", status: .cleaned,
                                   createdAt: now)
        let dropped = DictationResult(requestId: UUID(), documentIdentifier: nil, text: "", status: .cancelled,
                                      createdAt: now)
        try payloads.write(result: kept)
        try payloads.write(result: dropped, updatesLatest: false)
        #expect(payloads.latestResult() == kept)
        #expect(payloads.readResult(dropped.requestId) == dropped)
    }
}
