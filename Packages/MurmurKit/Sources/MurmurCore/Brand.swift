import Foundation

/// Product identity. The display name, URL scheme and App Group come from each target's
/// Info.plist (set from Config/Base.xcconfig), so renaming the app is a config change.
public enum Brand {
    public static let name = "Murmur"

    public static var urlScheme: String {
        infoValue("MurmurURLScheme") ?? "murmur"
    }

    public static var appGroupID: String {
        infoValue("MurmurAppGroupID") ?? "group.com.antonmironenko.murmur"
    }

    /// Deep link the keyboard opens to start a dictation session in the app.
    public static func sessionStartURL(token: String) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "session"
        components.path = "/start"
        components.queryItems = [URLQueryItem(name: "t", value: token)]
        return components.url!
    }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
