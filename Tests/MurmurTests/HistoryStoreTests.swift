import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class FakeCleanup: Cleaning {
    var isConfigured = true
    var result: Result<CleanupClient.Response, CleanupClient.Failure> = .success(
        CleanupClient.Response(text: "Cleaned.", status: "cleaned", words: 1, model: "test", ttftMs: 10, totalMs: 20, remaining: nil))

    func clean(
        dictationId: UUID, transcript: String, language: String?, style: StylePreset,
        dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        switch result {
        case .success(let response): return response
        case .failure(let failure): throw failure
        }
    }
}

@MainActor
struct HistoryStoreTests {
    private let settings: SharedSettings
    private let store: HistoryStore

    init() throws {
        settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.history.\(UUID().uuidString)"))
        store = try HistoryStore(inMemory: true, settings: settings)
    }

    @Test func recordsAndFetchesNewestFirst() {
        let now = Date()
        store.record(Transcript(id: UUID(), createdAt: now.addingTimeInterval(-60), rawText: "old", status: .raw))
        store.record(Transcript(id: UUID(), createdAt: now, rawText: "new", status: .cleaned))
        #expect(store.recent().map(\.rawText) == ["new", "old"])
        #expect(store.count == 2)
        #expect(!store.isEmpty)
    }

    @Test func upsertsByID() {
        var transcript = Transcript(id: UUID(), rawText: "raw", status: .processing)
        store.record(transcript)
        transcript.status = .cleaned
        transcript.cleanedText = "Clean"
        store.upsert(transcript)
        #expect(store.count == 1)
        #expect(store.snapshot(transcript.id)?.status == .cleaned)
        #expect(store.snapshot(transcript.id)?.displayText == "Clean")
        store.delete(transcript.id)
        #expect(store.isEmpty)
    }

    @Test func retentionDeletesOnlyOldRows() {
        settings.transcriptRetention = .week
        let now = Date()
        let old = Transcript(id: UUID(), createdAt: now.addingTimeInterval(-8 * 24 * 3600), rawText: "old", status: .raw)
        let recent = Transcript(id: UUID(), createdAt: now.addingTimeInterval(-24 * 3600), rawText: "recent", status: .raw)
        store.record(old)
        store.record(recent)
        store.applyRetention(now: now)
        #expect(store.recent().map(\.id) == [recent.id])
        settings.transcriptRetention = .never
        store.applyRetention(now: now.addingTimeInterval(365 * 24 * 3600))
        #expect(store.count == 1)
    }

    @Test func reconcilesInsertionsFromClaimMarkers() {
        let payloads = IPCPayloadStore(container: .temporary())
        let claimed = Transcript(id: UUID(), rawText: "a", cleanedText: "A", status: .cleaned)
        let unclaimed = Transcript(id: UUID(), rawText: "b", cleanedText: "B", status: .cleaned)
        store.record(claimed)
        store.record(unclaimed)
        payloads.claim(claimed.id)
        let now = Date()
        store.reconcileInsertions(payloads: payloads, now: now)
        #expect(store.snapshot(claimed.id)?.insertedAt == now)
        #expect(store.snapshot(unclaimed.id)?.insertedAt == nil)
        #expect(store.snapshot(unclaimed.id)?.insertState(now: now, claimed: false) == .pending)
    }

    @Test func republishWritesAFreshUnclaimedResult() {
        let transport = InMemoryIPCTransport()
        let transcript = Transcript(id: UUID(), language: "ru-RU", rawText: "привет", cleanedText: "Привет!", status: .cleaned)
        store.record(transcript)
        #expect(store.republish(transcript.id, payloads: transport.payloads, transport: transport))
        let latest = transport.payloads.latestResult()
        #expect(latest?.text == "Привет!")
        #expect(latest?.language == "ru-RU")
        #expect(latest?.requestId != transcript.id)
        #expect(latest.map { !transport.payloads.isClaimed($0.requestId) } == true)
        #expect(transport.postedEvents.contains(.resultReady))

        let failed = Transcript(id: UUID(), rawText: "", status: .failed)
        store.record(failed)
        #expect(!store.republish(failed.id, payloads: transport.payloads, transport: transport))
    }

    @Test func recoversInterruptedDictations() {
        let stuck = Transcript(id: UUID(), language: "ru-RU", rawText: "э-э привет", status: .processing)
        store.record(stuck)
        let recovered = store.recoverInterrupted()
        #expect(recovered.map(\.id) == [stuck.id])
        #expect(store.snapshot(stuck.id)?.status == .raw)
        #expect(store.snapshot(stuck.id)?.cleanedText == "Привет")
        #expect(store.recoverInterrupted().isEmpty)
    }

    @Test func metricsSummaryUsesStoredLatencies() {
        for ms in [100, 200, 300] {
            store.record(Transcript(id: UUID(), rawText: "x", status: .cleaned,
                                    metrics: TranscriptMetrics(audioSeconds: 1, words: 1, asrMs: ms, cleanupMs: ms * 2, totalMs: ms * 3)))
        }
        let summary = store.metricsSummary()
        #expect(summary.asr.count == 3)
        #expect(summary.asr.median == 200)
        #expect(summary.total.p95 == 900)
    }

    @Test func regenerateUpdatesOnlyOnSuccess() async throws {
        let cleanup = FakeCleanup()
        let pipeline = DictationPipeline(cleanup: cleanup)
        let transcript = Transcript(id: UUID(), language: "en-US", rawText: "hello there friend", status: .raw)

        var updated = try await pipeline.recleanup(transcript)
        #expect(updated.status == .cleaned)
        #expect(updated.cleanedText == "Cleaned.")
        #expect(updated.cleanupModel == "test")
        #expect(updated.regeneratedAt != nil)

        cleanup.result = .failure(.limitReached)
        updated = try await pipeline.recleanup(transcript)
        #expect(updated.status == .limitReached)
        #expect(updated.cleanedText == "Hello there friend")

        cleanup.result = .failure(.unavailable("offline"))
        await #expect(throws: CleanupClient.Failure.self) {
            _ = try await pipeline.recleanup(transcript)
        }

        cleanup.isConfigured = false
        await #expect(throws: CleanupClient.Failure.self) {
            _ = try await pipeline.recleanup(transcript)
        }
    }
}
