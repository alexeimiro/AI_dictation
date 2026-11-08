import Foundation
import MurmurCore

enum CloudTranscriptionError: LocalizedError, Equatable {
    case notConfigured
    /// The free plan's weekly words are used up.
    case limitReached
    case rateLimited
    case unavailable(String)
    /// The request was cancelled because its dictation is being dropped, or another path already
    /// answered. Unlike `unavailable` it says nothing about the service, so it never pauses it.
    case cancelled
    /// The server rejected the signed-in user's session (`BackendError.signedOut`). It answered,
    /// so the cloud isn't paused; the on-device fallback can still transcribe the dictation.
    case signedOut

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Transcription isn't configured in this build."
        case .limitReached: "Dictation limit reached."
        case .rateLimited: "Too many dictations in a minute."
        case .unavailable(let reason): "Transcription unavailable: \(reason)"
        case .cancelled: "Transcription was cancelled."
        case .signedOut: BackendError.signedOut.localizedDescription
        }
    }
}

/// A cloud transcript, and how its request went (nil from a fake).
struct CloudTranscript: Sendable {
    let text: String
    let timing: RequestTiming?
}

/// Speech-to-text in the cloud, as `OpenAITranscriber` sees it (`TranscriptionClient`, or a fake).
@MainActor
protocol CloudTranscribing: AnyObject, Sendable {
    var isConfigured: Bool { get }
    /// `language`: BCP-47 tag of the dictation; `keywords`: personal dictionary terms.
    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?,
                    keywords: [String]) async throws(CloudTranscriptionError) -> CloudTranscript
}

/// Calls the `transcribe` Edge Function, which passes the audio to OpenAI. The OpenAI key lives
/// in the function's secrets, never in the app.
@MainActor
final class TranscriptionClient: CloudTranscribing {
    private struct Response: Decodable, Sendable {
        let text: String
    }

    private struct RequestBody: Encodable {
        let dictationId: UUID
        let audio: String
        let format: String
        let language: String?
        let keywords: [String]
    }

    private let functions: EdgeFunctionClient?
    /// The function gives OpenAI 20 s (`TRANSCRIBE_DEADLINE_MS`); the rest is for the upload.
    private let timeout: TimeInterval = 25

    init(functions: EdgeFunctionClient?) {
        self.functions = functions
    }

    var isConfigured: Bool { functions != nil }

    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?,
                    keywords: [String]) async throws(CloudTranscriptionError) -> CloudTranscript {
        guard let functions else { throw .notConfigured }
        let body = RequestBody(
            dictationId: UUID(), audio: audio.base64EncodedString(), format: format.rawValue,
            language: language, keywords: Array(keywords.prefix(100)))
        do {
            let reply = try await functions.post("transcribe", body: body, timeout: timeout)
            let response = try JSONDecoder().decode(Response.self, from: reply.data)
            return CloudTranscript(text: response.text, timing: reply.timing)
        } catch EdgeFunctionError.httpError(let code) {
            switch code {
            case 402: throw .limitReached
            case 429: throw .rateLimited
            default: throw .unavailable("HTTP \(code)")
            }
        } catch {
            if Task.isCancelled || Self.isCancellation(error) { throw .cancelled }
            if Self.underlying(error) as? BackendError == .signedOut { throw .signedOut }
            throw .unavailable(error.localizedDescription)
        }
    }

    /// What URLSession or the token threw, which `EdgeFunctionClient` wraps.
    private static func underlying(_ error: any Error) -> any Error {
        if case EdgeFunctionError.transport(let inner) = error { inner } else { error }
    }

    /// What they throw when the request's task is cancelled.
    private static func isCancellation(_ error: any Error) -> Bool {
        let cause = underlying(error)
        return cause is CancellationError || (cause as? URLError)?.code == .cancelled
    }
}
