import Foundation
import os
import Supabase

/// The Supabase project the app talks to, configured from `SUPABASE_HOST` / `SUPABASE_ANON_KEY`
/// (Config/Local.xcconfig → Info.plist). Nil when not configured, in which case dictation still
/// works with on-device formatting only.
@MainActor
final class Backend {
    let client: SupabaseClient
    private let logger = Logger(subsystem: "Murmur", category: "Backend")

    init(url: URL, anonKey: String) {
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }

    static func fromInfoPlist(_ bundle: Bundle = .main) -> Backend? {
        guard let host = infoString("MurmurSupabaseHost", bundle),
              let key = infoString("MurmurSupabaseAnonKey", bundle),
              let url = baseURL(forHost: host) else { return nil }
        return Backend(url: url, anonKey: key)
    }

    /// `abcd.supabase.co` → https; a local stack (`127.0.0.1:54321`, LAN IPs, `*.local`) → http.
    static func baseURL(forHost host: String) -> URL? {
        if host.hasPrefix("http://") || host.hasPrefix("https://") { return URL(string: host) }
        let isLocal = host.hasPrefix("127.") || host.hasPrefix("localhost") || host.hasPrefix("192.168.")
            || host.hasPrefix("10.") || host.contains(".local")
        return URL(string: "\(isLocal ? "http" : "https")://\(host)")
    }

    /// Makes sure requests carry a user JWT. Until real sign-in exists (Phase 3) this is an
    /// anonymous user, which still gets per-user quota and rate limits.
    func ensureSession() async throws {
        if let session = client.auth.currentSession, !session.isExpired { return }
        do {
            _ = try await client.auth.session // refreshes if possible
        } catch {
            logger.info("No session; signing in anonymously")
            _ = try await client.auth.signInAnonymously()
        }
    }

    private static func infoString(_ key: String, _ bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
