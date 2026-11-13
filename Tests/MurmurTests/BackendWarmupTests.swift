import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class FakeSession: SessionRenewing {
    var failure: (any Error)?
    private(set) var renewals: [TimeInterval] = []

    func ensureSession(validFor seconds: TimeInterval) async throws {
        renewals.append(seconds)
        if let failure { throw failure }
    }
}

@MainActor
private final class WarmedDictate: Dictating {
    var isAvailable = true
    /// A deployment that takes Word for word; false for one from before it did.
    var takesPlain = true
    var transcribesAlone: Bool { isAvailable && takesPlain }
    var lastReplyAt: ContinuousClock.Instant?
    var result = WarmupResult.warmed(RequestTiming(function: "dictate", status: 200, totalMs: 400,
                                                   server: ServerTiming(executionId: "w1")))
    /// Warm-ups wait for `release()`.
    var holds = false
    private(set) var warmUps = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    func dictate(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                 keywords: [String], request: ModelRequest) async throws(CloudTranscriptionError) -> DictateReply {
        throw .notDeployed
    }

    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                    keywords: [String], dictationId: UUID) async throws(CloudTranscriptionError) -> CloudTranscript {
        throw .notDeployed
    }

    func warm() async -> WarmupResult {
        warmUps += 1
        if holds { await withCheckedContinuation { held.append($0) } }
        return result
    }

    func release() {
        held.forEach { $0.resume() }
        held.removeAll()
    }
}

@MainActor
struct BackendWarmupTests {
    private let session = FakeSession()
    private let dictate = WarmedDictate()

    private func warmup() -> BackendWarmup {
        BackendWarmup(session: session, dictate: dictate)
    }

    @Test func aTranslationRenewsTheTokenAndWarmsDictate() async throws {
        let warmup = warmup()
        let id = UUID()
        warmup.dictationDidStart(id, cloud: true, writesWithModel: true)
        await warmup.waitUntilIdle()

        #expect(session.renewals == [360])
        #expect(dictate.warmUps == 1)
        #expect(warmup.takeTiming(for: UUID()) == nil)
        #expect(try #require(warmup.takeTiming(for: id)).server?.executionId == "w1")
        // Once.
        #expect(warmup.takeTiming(for: id) == nil)
    }

    /// Word for word is `dictate`'s request too, so its worker is warmed like any other's.
    @Test func aWordForWordDictationWarmsDictateToo() async throws {
        let warmup = warmup()
        let id = UUID()
        warmup.dictationDidStart(id, cloud: true, writesWithModel: false)
        await warmup.waitUntilIdle()

        #expect(session.renewals == [360])
        #expect(dictate.warmUps == 1)
        #expect(try #require(warmup.takeTiming(for: id)).server?.executionId == "w1")
    }

    /// A deployment from before `dictate` took Word for word: that dictation goes to `transcribe`,
    /// which a warm-up of `dictate` does nothing for. The styles the model writes still get theirs.
    @Test func noWarmUpForWordForWordWhileDictateCannotTranscribeAlone() async {
        dictate.takesPlain = false
        let warmup = warmup()
        warmup.dictationDidStart(UUID(), cloud: true, writesWithModel: false)
        await warmup.waitUntilIdle()

        #expect(session.renewals == [360])
        #expect(dictate.warmUps == 0)

        warmup.dictationDidStart(UUID(), cloud: true, writesWithModel: true)
        await warmup.waitUntilIdle()
        #expect(dictate.warmUps == 1)
    }

    /// The iPhone transcribes: nothing is `dictate`'s, and only the token is renewed, for `cleanup`.
    @Test func anOnDeviceDictationOnlyRenewsTheToken() async {
        let warmup = warmup()
        warmup.dictationDidStart(UUID(), cloud: false, writesWithModel: false)
        await warmup.waitUntilIdle()
        warmup.dictationDidStart(UUID(), cloud: false, writesWithModel: true)
        await warmup.waitUntilIdle()

        #expect(session.renewals == [360, 360])
        #expect(dictate.warmUps == 0)
    }

    @Test func noWarmUpRightAfterDictateAnswered() async {
        dictate.lastReplyAt = .now
        let warmup = warmup()
        warmup.dictationDidStart(UUID(), cloud: true, writesWithModel: true)
        await warmup.waitUntilIdle()

        #expect(dictate.warmUps == 0)

        dictate.lastReplyAt = ContinuousClock.now.advanced(by: .seconds(-21))
        warmup.dictationDidStart(UUID(), cloud: true, writesWithModel: true)
        await warmup.waitUntilIdle()
        #expect(dictate.warmUps == 1)
    }

    @Test func noWarmUpWhenDictateIsUnavailable() async {
        dictate.isAvailable = false
        let warmup = warmup()
        warmup.dictationDidStart(UUID(), cloud: true, writesWithModel: true)
        await warmup.waitUntilIdle()
        warmup.dictationDidStart(UUID(), cloud: true, writesWithModel: false)
        await warmup.waitUntilIdle()

        #expect(session.renewals == [360, 360])
        #expect(dictate.warmUps == 0)
    }

    /// Signed out, or offline: nothing else goes out.
    @Test func noWarmUpWithoutASession() async {
        session.failure = BackendError.signedOut
        let warmup = warmup()
        warmup.dictationDidStart(UUID(), cloud: true, writesWithModel: true)
        await warmup.waitUntilIdle()

        #expect(dictate.warmUps == 0)
    }

    @Test func aRejectedTokenIsReplacedRightAway() async {
        dictate.result = .rejected
        let warmup = warmup()
        let id = UUID()
        warmup.dictationDidStart(id, cloud: true, writesWithModel: true)
        await warmup.waitUntilIdle()

        #expect(session.renewals == [360, .infinity])
        #expect(warmup.takeTiming(for: id) == nil)
    }

    @Test func oneWarmUpAtATime() async {
        dictate.holds = true
        let warmup = warmup()
        warmup.dictationDidStart(UUID(), cloud: true, writesWithModel: true)
        for _ in 0..<1_000 where dictate.warmUps == 0 { await Task.yield() }
        warmup.dictationDidStart(UUID(), cloud: true, writesWithModel: false)
        dictate.release()
        await warmup.waitUntilIdle()

        #expect(dictate.warmUps == 1)
        #expect(session.renewals == [360])
    }
}
