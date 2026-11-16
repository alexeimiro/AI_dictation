import Foundation

/// Which app each Mac dictation went into, and whether it was pasted or only copied: the
/// history's "· Slack" and "Copied, not inserted", and Insights' "Where you dictate". Kept beside
/// the history (Application Support/Murmur) rather than in it, so the history's schema, shared
/// with the iPhone app, doesn't change.
@MainActor
@Observable
final class DictationAppLog {
    struct Entry: Codable, Equatable, Sendable {
        var app: String?
        var bundleID: String?
        var copied: Bool
    }

    private(set) var entries: [UUID: Entry] = [:]
    @ObservationIgnored private let url: URL?
    /// The oldest are dropped past this; the history keeps no more than that either.
    static let limit = 5000

    init(url: URL? = DictationAppLog.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
    }

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Murmur/MacDictationApps.json")
    }

    func entry(for id: UUID) -> Entry? { entries[id] }

    func record(_ id: UUID, app: String?, bundleID: String?, copied: Bool) {
        entries[id] = Entry(app: app, bundleID: bundleID, copied: copied)
        if entries.count > Self.limit {
            // Keys don't sort by age; dropping arbitrary old ones is fine for a display hint.
            for key in entries.keys.prefix(entries.count - Self.limit) { entries[key] = nil }
        }
        save()
    }

    func remove(_ id: UUID) {
        entries[id] = nil
        save()
    }

    func removeAll() {
        entries = [:]
        save()
    }

    private func save() {
        guard let url else { return }
        let stored = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        } catch {
            // A display hint only; nothing to tell the user.
        }
    }
}
