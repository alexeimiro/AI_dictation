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
    /// `dictate` answered 404: not deployed, or switched off (`DICTATE_DISABLED`). The same audio
    /// goes to `transcribe` instead, so the user never sees it.
    case notDeployed

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Transcription isn't configured in this build."
        case .limitReached: "Dictation limit reached."
        case .rateLimited: "Too many dictations in a minute."
        case .unavailable(let reason): "Transcription unavailable: \(reason)"
        case .cancelled: "Transcription was cancelled."
        case .signedOut: BackendError.signedOut.localizedDescription
        case .notDeployed: "Translating in one request isn't available."
        }
    }

    /// What a failed `transcribe` or `dictate` request comes to: what `EdgeFunctionClient` threw,
    /// or the reply that didn't decode.
    init(_ error: any Error) {
        if case EdgeFunctionError.httpError(let code) = error {
            switch code {
            case 402: self = .limitReached
            case 429: self = .rateLimited
            default: self = .unavailable("HTTP \(code)")
            }
            return
        }
        // What URLSession or the token threw, which `EdgeFunctionClient` wraps.
        let cause = if case EdgeFunctionError.transport(let inner) = error { inner } else { error }
        if Task.isCancelled || cause is CancellationError || (cause as? URLError)?.code == .cancelled {
            self = .cancelled
        } else if cause as? BackendError == .signedOut {
            self = .signedOut
        } else {
            self = .unavailable(error.localizedDescription)
        }
    }
}

/// A cloud transcript, and how its request went (nil from a fake).
struct CloudTranscript: Sendable {
    let text: String
    /// The languages OpenAI heard, first the main one (ISO 639-1: "tr"); empty when it couldn't tell.
    let languages: [String]
    let timing: RequestTiming?

    init(text: String, languages: [String] = [], timing: RequestTiming?) {
        self.text = text
        self.languages = languages
        self.timing = timing
    }
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
        let languages: [String]?
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
            return CloudTranscript(text: response.text, languages: response.languages ?? [], timing: reply.timing)
        } catch {
            throw CloudTranscriptionError(error)
        }
    }
}
