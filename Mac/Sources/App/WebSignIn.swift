import AppKit
import AuthenticationServices

/// Apple's web sign-in sheet for Google, run here rather than by supabase-swift's own helper: on
/// the Mac, ASWebAuthenticationSession answers on a background queue, and the helper's reply
/// closure is main-actor isolated, so Swift 6 stopped the app there (crash 2026-11-16). This
/// reply closure is `@Sendable`, so it runs wherever it's called and only resumes the wait.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    /// The window the sheet attaches to, picked before it opens: macOS may ask for it from any
    /// thread.
    nonisolated(unsafe) private var anchor: ASPresentationAnchor?

    /// Opens `url` and returns the callback URL the provider redirects to.
    func run(_ url: URL, callbackScheme: String) async throws -> URL {
        anchor = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) {
                @Sendable callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: ASWebAuthenticationSessionError(.presentationContextInvalid))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
