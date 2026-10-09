import Foundation

/// Directory in the App Group container shared by the app, keyboard and widgets.
///
/// Without Full Access the keyboard can read this container but not write to it.
public struct SharedContainer: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// The App Group container, or nil if the entitlement is missing (e.g. unsigned builds).
    public static func appGroup(_ identifier: String = Brand.appGroupID) -> SharedContainer? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return nil
        }
        return SharedContainer(rootURL: url.appendingPathComponent("IPC", isDirectory: true))
    }

    /// A throwaway container for tests and previews.
    public static func temporary() -> SharedContainer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-ipc-\(UUID().uuidString)", isDirectory: true)
        return SharedContainer(rootURL: url)
    }

    public func url(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    public func directory(_ name: String) -> URL {
        rootURL.appendingPathComponent(name, isDirectory: true)
    }
}

/// Small JSON documents written atomically (write to temp file + rename), so a reader in the
/// other process never sees a half-written file.
public enum JSONFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
