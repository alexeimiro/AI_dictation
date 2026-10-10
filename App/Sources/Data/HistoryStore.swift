import Foundation
import MurmurCore
import os
import SwiftData

/// On-device dictation history in the app's private container (never the App Group: the
/// keyboard stays lean and raw transcripts never leave the app).
@MainActor
@Observable
final class HistoryStore: TranscriptSink {
    let container: ModelContainer
    /// Bumped after every write so lists that don't use `@Query` can re-fetch.
    private(set) var revision = 0

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: SharedSettings
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "History")

    init(inMemory: Bool = false, settings: SharedSettings = .shared) throws {
        let schema = Schema(versionedSchema: HistorySchemaV1.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration("History", schema: schema, isStoredInMemoryOnly: true)
        } else {
            let directory = URL.applicationSupportDirectory.appending(path: "Murmur", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(
                "History", schema: schema, url: directory.appending(path: "History.store"))
        }
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = container.mainContext
        context.autosaveEnabled = false
        self.settings = settings
    }

    /// The on-disk store, or an in-memory one when the disk store can't be opened (the app
    /// still works; history just doesn't persist).
    static func open(inMemory: Bool, settings: SharedSettings = .shared) -> HistoryStore {
        do {
            return try HistoryStore(inMemory: inMemory, settings: settings)
        } catch {
            Logger(subsystem: "Murmur", category: "History")
                .error("Couldn't open the history store: \(error.localizedDescription, privacy: .public)")
            // swiftlint:disable:next force_try
            return try! HistoryStore(inMemory: true, settings: settings)
        }
    }

    // MARK: Reads

    var isEmpty: Bool {
        count == 0
    }

    var count: Int {
        (try? context.fetchCount(FetchDescriptor<TranscriptRecord>())) ?? 0
    }

    func snapshot(_ id: UUID) -> Transcript? {
        record(id)?.snapshot
    }

    /// Newest first.
    func recent(limit: Int = 100) -> [Transcript] {
        var descriptor = FetchDescriptor<TranscriptRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).map(\.snapshot)
    }

    /// Latency numbers over the most recent dictations, for the Debug screen.
    func metricsSummary(limit: Int = 100) -> (asr: MetricsSummary, cleanup: MetricsSummary, total: MetricsSummary) {
        let metrics = recent(limit: limit).map(\.metrics)
        return (MetricsSummary.summarize(metrics.compactMap(\.asrMs)),
                MetricsSummary.summarize(metrics.compactMap(\.cleanupMs)),
                MetricsSummary.summarize(metrics.compactMap(\.totalMs)))
    }

    // MARK: Writes

    func record(_ transcript: Transcript) {
        upsert(transcript)
    }

    func upsert(_ transcript: Transcript) {
        if let existing = record(transcript.id) {
            existing.apply(transcript)
        } else {
            context.insert(TranscriptRecord(transcript))
        }
        save()
    }

    func delete(_ id: UUID) {
        guard let existing = record(id) else { return }
        context.delete(existing)
        save()
    }

    func deleteAll() {
        try? context.delete(model: TranscriptRecord.self)
        save()
    }

    /// Removes transcripts older than the "Auto-delete transcripts" setting.
    func applyRetention(now: Date = Date()) {
        guard let cutoff = RetentionPolicy.cutoff(now: now, retention: settings.transcriptRetention) else { return }
        do {
            try context.delete(model: TranscriptRecord.self, where: #Predicate { $0.createdAt < cutoff })
            save()
        } catch {
            logger.error("Retention failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks transcripts the keyboard has claimed (inserted or dismissed) as inserted. Claim
    /// markers are pruned after 24 h, which is why `insertedAt` is persisted.
    func reconcileInsertions(payloads: IPCPayloadStore, now: Date = Date()) {
        let since = now.addingTimeInterval(-24 * 3600)
        let descriptor = FetchDescriptor<TranscriptRecord>(
            predicate: #Predicate { $0.insertedAt == nil && $0.createdAt > since })
        guard let candidates = try? context.fetch(descriptor), !candidates.isEmpty else { return }
        var changed = false
        for candidate in candidates where payloads.isClaimed(candidate.id) {
            candidate.insertedAt = now
            changed = true
        }
        if changed { save() }
    }

    /// Offers a transcript to the keyboard again as a fresh result ("Insert last dictation"
    /// chip for 120 s). A new request id is needed because the original is probably claimed.
    @discardableResult
    func republish(_ id: UUID, payloads: IPCPayloadStore, transport: IPCTransport, now: Date = Date()) -> Bool {
        guard let transcript = snapshot(id), transcript.isInsertable else { return false }
        let result = DictationResult(
            requestId: UUID(), documentIdentifier: nil, text: transcript.displayText,
            status: transcript.status == .cleaned ? .cleaned : .raw, createdAt: now,
            language: transcript.language)
        do {
            try payloads.write(result: result)
        } catch {
            logger.error("Couldn't republish \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        transport.post(.resultReady)
        return true
    }

    /// Dictations whose cleanup never finished (the app was killed): keep the raw transcript.
    func recoverInterrupted(now: Date = Date()) -> [Transcript] {
        let processing = TranscriptStatus.processing.rawValue
        let descriptor = FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.status == processing })
        guard let stuck = try? context.fetch(descriptor), !stuck.isEmpty else { return [] }
        var recovered: [Transcript] = []
        for record in stuck {
            var transcript = record.snapshot
            transcript.cleanedText = LocalFormatter(language: transcript.language).format(transcript.rawText)
            transcript.status = transcript.rawText.isEmpty ? .failed : .raw
            transcript.errorReason = "Murmur closed before the cleanup finished."
            record.apply(transcript)
            recovered.append(transcript)
        }
        save()
        return recovered
    }

    // MARK: Helpers

    private func record(_ id: UUID) -> TranscriptRecord? {
        var descriptor = FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func save() {
        do {
            try context.save()
            revision += 1
        } catch {
            logger.error("Couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
