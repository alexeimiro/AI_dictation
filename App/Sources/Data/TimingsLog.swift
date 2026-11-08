import Foundation
import MurmurCore
import Observation
import os

/// Recent dictations' timings for the Debug screen: JSON lines (`timings.jsonl`) in the app's
/// Application Support folder, next to history and never in the App Group. An entry holds numbers
/// and identifiers only, never any text. Cleared together with history.
@MainActor
@Observable
final class TimingsLog {
    /// The most `all()` returns.
    static let capacity = 500
    /// Once the file passes this many lines it is cut back to `trimmedCount`, so it isn't
    /// rewritten at every append.
    static let trimThreshold = 600
    static let trimmedCount = 400

    /// Bumped after every change, so the Debug screen reads the log again.
    private(set) var revision = 0

    let fileURL: URL
    /// Loaded at the first `all()`; appends go to the file whatever it holds.
    @ObservationIgnored private var entries: [DictationTimings]?
    @ObservationIgnored private var lineCount: Int?
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "Timings")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Murmur", directoryHint: .isDirectory)) {
        fileURL = directory.appending(path: "timings.jsonl")
    }

    // MARK: Reads

    /// Oldest first, at most `capacity`. A line that doesn't decode (a write cut short) is skipped.
    func all() -> [DictationTimings] {
        if entries == nil {
            let lines = readLines()
            lineCount = lines.count
            entries = lines.compactMap { try? Self.decoder.decode(DictationTimings.self, from: $0) }
        }
        return Array((entries ?? []).suffix(Self.capacity))
    }

    /// The Debug screen's rows for `kind`. The insert rows count the claims `recordClaims` has
    /// copied in.
    func summary(_ kind: DictationTimings.Kind) -> TimingsSummary {
        TimingsSummary.summarize(all(), kind: kind)
    }

    /// The file "Export timings" shares; nil until something was logged.
    var exportURL: URL? {
        FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    // MARK: Writes

    /// A file that is there but won't open (permissions, too many open files) keeps what it has,
    /// and this entry is dropped.
    func append(_ timings: DictationTimings) {
        let existing = lineCount ?? readLines().count
        do {
            var line = try Self.encoder.encode(timings)
            line.append(UInt8(ascii: "\n"))
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forUpdating: fileURL)
                defer { try? handle.close() }
                // A last line cut short (the app killed mid-write) gets its end first, or this
                // entry would join it and be lost too.
                let end = try handle.seekToEnd()
                if end > 0 {
                    try handle.seek(toOffset: end - 1)
                    if try handle.read(upToCount: 1) != Data("\n".utf8) { line.insert(UInt8(ascii: "\n"), at: 0) }
                }
                try handle.write(contentsOf: line)
            } else {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            logger.error("Couldn't log timings: \(error.localizedDescription, privacy: .public)")
            return
        }
        lineCount = existing + 1
        entries?.append(timings)
        if existing + 1 > Self.trimThreshold { trim() }
        revision += 1
    }

    /// Copies the keyboard's claim dates (`IPCPayloadStore.claimDate`) into the last day's entries
    /// that have none, so the insert times outlive the markers, which are pruned after a day. The
    /// Debug screen calls it when it opens and before it prunes. Rewrites the file only when it
    /// found a claim.
    func recordClaims(from payloads: IPCPayloadStore, now: Date = Date()) {
        _ = all()
        guard var updated = entries else { return }
        var found = false
        for index in updated.indices
        where updated[index].claimedAt == nil && now.timeIntervalSince(updated[index].createdAt) < 24 * 3600 {
            guard let claimed = payloads.claimDate(updated[index].requestId) else { continue }
            updated[index].claimedAt = claimed
            found = true
        }
        guard found else { return }
        do {
            var data = Data()
            for entry in updated {
                data.append(try Self.encoder.encode(entry))
                data.append(UInt8(ascii: "\n"))
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Couldn't record the claims: \(error.localizedDescription, privacy: .public)")
            return
        }
        entries = updated
        lineCount = updated.count
        revision += 1
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        entries = []
        lineCount = 0
        revision += 1
    }

    // MARK: Helpers

    private func readLines() -> [Data] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    /// Keeps the newest `trimmedCount` lines.
    private func trim() {
        let kept = readLines().suffix(Self.trimmedCount)
        var data = Data()
        for line in kept {
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            lineCount = kept.count
            entries = nil
        } catch {
            logger.error("Couldn't trim the timings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
