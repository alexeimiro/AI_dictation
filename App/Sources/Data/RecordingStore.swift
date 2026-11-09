import Foundation
import os

/// Each dictation's audio as it was uploaded, kept beside the history in the app's private
/// container ("Keep recordings"), so its transcript can play it back. A recording goes when its
/// transcript is deleted or ages out.
final class RecordingStore: Sendable {
    let directory: URL
    private let logger = Logger(subsystem: "Murmur", category: "Recordings")

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Murmur/Recordings", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    /// A store in a fresh temporary folder (fixtures and tests).
    static func temporary() -> RecordingStore {
        RecordingStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "Recordings-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    func save(_ audio: EncodedAudio, for id: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try audio.data.write(to: fileURL(for: id, format: audio.format), options: [.atomic, .completeFileProtection])
        } catch {
            logger.error("Couldn't save a recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The recording of transcript `id`, if one was kept.
    func url(for id: UUID) -> URL? {
        EncodedAudio.Format.allCases.lazy
            .map { self.fileURL(for: id, format: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func delete(_ id: UUID) {
        for format in EncodedAudio.Format.allCases {
            try? FileManager.default.removeItem(at: fileURL(for: id, format: format))
        }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes recordings saved before `cutoff` (auto-delete transcripts).
    func prune(olderThan cutoff: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            if created < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func fileURL(for id: UUID, format: EncodedAudio.Format) -> URL {
        directory.appending(path: "\(id.uuidString).\(format.rawValue)")
    }
}
