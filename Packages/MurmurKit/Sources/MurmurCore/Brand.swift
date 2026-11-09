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

    /// Deep link the keyboard's Settings button opens (`murmur://settings`).
    public static var settingsURL: URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "settings"
        return components.url!
    }

    /// "Get unlimited words" in Murmur (`murmur://pro`), from the keyboard's limit message.
    public static var proURL: URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "pro"
        return components.url!
    }

    /// What a dictation past Basic's weekly words says; the keyboard turns it into a way to Pro.
    public static let limitReachedMessage = "Dictation limit reached. Get unlimited access in Murmur."

    /// Linked from the sign-in screen; nil until `MURMUR_TERMS_URL` / `MURMUR_PRIVACY_URL` are set.
    public static var termsURL: URL? {
        infoValue("MurmurTermsURL").flatMap(URL.init(string:))
    }

    public static var privacyURL: URL? {
        infoValue("MurmurPrivacyURL").flatMap(URL.init(string:))
    }

    /// The menu's Help center; nil until `MURMUR_SUPPORT_URL` is set.
    public static var supportURL: URL? {
        infoValue("MurmurSupportURL").flatMap(URL.init(string:))
    }

    /// The page an invite shares (`MURMUR_INVITE_URL?code=a1b2c3d4`); nil until it's set.
    public static func inviteURL(code: String) -> URL? {
        guard let base = infoValue("MurmurInviteURL"),
              var components = URLComponents(string: base) else { return nil }
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url
    }

    /// Opening an invite in Murmur (`murmur://invite?code=a1b2c3d4`), from the invite page.
    public static func inviteDeepLink(code: String) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "invite"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url!
    }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
