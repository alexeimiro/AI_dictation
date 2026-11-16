import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Sign in with Apple on the Mac: Apple's own sheet, then the identity token goes to Supabase
/// (`signInWithIdToken`), which accepts the Mac app's bundle ID next to the iPhone's.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Result {
        let idToken: String
        let nonce: String
        let fullName: String?
    }

    private var continuation: CheckedContinuation<Result, any Error>?
    private var nonce = ""
    nonisolated(unsafe) private var anchor: ASPresentationAnchor?

    func run() async throws -> Result {
        nonce = Self.randomNonce()
        anchor = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let token = credential?.identityToken.flatMap { String(data: $0, encoding: .utf8) }
        let name = credential?.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
        Task { @MainActor in
            guard let token else {
                self.finish(.failure(AppleSignInError.noToken))
                return
            }
            self.finish(.success(Result(idToken: token, nonce: self.nonce, fullName: name?.isEmpty == false ? name : nil)))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }

    private func finish(_ result: Swift.Result<Result, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    enum AppleSignInError: LocalizedError {
        case noToken
        var errorDescription: String? { "Apple didn't return an identity token. Please try again." }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).map { _ in characters[Int.random(in: 0..<characters.count)] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
