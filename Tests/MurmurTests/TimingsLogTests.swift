import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
struct TimingsLogTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("timings-\(UUID().uuidString)", isDirectory: true)

    /// Whole seconds, so the dates survive the log's millisecond encoding exactly.
    private func entry(_ index: Int = 0, kind: DictationTimings.Kind = .dictation) -> DictationTimings {
        DictationTimings(requestId: UUID(), createdAt: Date(timeIntervalSince1970: 1_762_600_000 + Double(index)),
                         kind: kind, audioSeconds: 4, stopToResultMs: 1_000 + index, status: "cleaned",
                         insertable: true)
    }

    @Test func appendsAndReadsOldestFirst() {
        let log = TimingsLog(directory: directory)
        #expect(log.all().isEmpty)
        #expect(log.exportURL == nil)
        let first = entry(1)
        let second = entry(2, kind: .translation)
        log.append(first)
        log.append(second)
        #expect(log.all() == [first, second])
        #expect(TimingsLog(directory: directory).all() == [first, second])
        #expect(log.exportURL == log.fileURL)
    }

    @Test func keepsTheNewestEntries() {
        let log = TimingsLog(directory: directory)
        let entries = (0..<550).map { entry($0) }
        for timings in entries { log.append(timings) }
        #expect(log.all() == Array(entries.suffix(TimingsLog.capacity)))

        // After a relaunch the lines already there count too; past 600 only the newest 400 stay.
        let relaunched = TimingsLog(directory: directory)
        let more = (550..<601).map { entry($0) }
        for timings in more { relaunched.append(timings) }
        #expect(relaunched.all() == Array((entries + more).suffix(TimingsLog.trimmedCount)))
        #expect(TimingsLog(directory: directory).all().count == TimingsLog.trimmedCount)
    }

    @Test func clearRemovesEverything() {
        let log = TimingsLog(directory: directory)
        log.append(entry())
        log.clear()
        #expect(log.all().isEmpty)
        #expect(log.exportURL == nil)
        #expect(TimingsLog(directory: directory).all().isEmpty)
        log.append(entry(1))
        #expect(log.all().count == 1)
    }

    /// A write cut short by the app being killed costs that line only, also once more follow it.
    @Test func skipsALineThatDoesNotDecode() throws {
        let log = TimingsLog(directory: directory)
        let first = entry(1)
        log.append(first)
        let handle = try FileHandle(forWritingTo: log.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"requestId":"#.utf8))
        try handle.close()

        let relaunched = TimingsLog(directory: directory)
        #expect(relaunched.all() == [first])
        let second = entry(2)
        relaunched.append(second)
        #expect(TimingsLog(directory: directory).all() == [first, second])
    }

    /// A log that is there but won't open keeps what it has; only the new entry is lost.
    @Test func aLogThatWontOpenIsNotReplaced() throws {
        let log = TimingsLog(directory: directory)
        let first = entry(1)
        log.append(first)
        #expect(log.all() == [first])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: log.fileURL.path)
        let revision = log.revision

        log.append(entry(2))
        #expect(log.revision == revision)
        #expect(log.all() == [first])
        #expect(TimingsLog(directory: directory).all() == [first])
    }

    /// The claim markers are pruned after a day, so their dates are copied into the log, where
    /// the insert rows and the export read them.
    @Test func claimsAreCopiedInAndOutliveTheMarkers() throws {
        let log = TimingsLog(directory: directory)
        let payloads = IPCPayloadStore(container: .temporary())
        var inserted = entry()
        inserted.createdAt = Date().addingTimeInterval(-0.5)
        var old = entry(1)
        old.createdAt = Date().addingTimeInterval(-25 * 3600)
        log.append(inserted)
        log.append(old)
        log.append(entry(2))
        payloads.claim(inserted.requestId)
        payloads.claim(old.requestId)

        log.recordClaims(from: payloads)
        payloads.prune(olderThan: 0)
        let reread = TimingsLog(directory: directory).all()
        let claimed = try #require(reread.first { $0.requestId == inserted.requestId }?.claimedAt)
        #expect((300...5_000).contains(claimed.milliseconds(since: inserted.createdAt)))
        // Older than a day: its claim isn't looked up.
        #expect(reread.first { $0.requestId == old.requestId }?.claimedAt == nil)
        #expect(reread.count == 3)

        let summary = TimingsLog(directory: directory).summary(.dictation)
        #expect(summary.count == 3)
        #expect(summary.resultToInsert.count == 1)
    }

    /// With no new claim the file stays as it is.
    @Test func recordingNoClaimsChangesNothing() {
        let log = TimingsLog(directory: directory)
        log.append(entry(1))
        let revision = log.revision
        log.recordClaims(from: IPCPayloadStore(container: .temporary()))
        #expect(log.revision == revision)
    }
}
