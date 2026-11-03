import Foundation
import MurmurCore
import Supabase

enum CloudTranscriptionError: LocalizedError, Equatable {
    case notConfigured
    /// The free plan's weekly words are used up.
    case limitReached
    case rateLimited
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Transcription isn't configured in this build."
        case .limitReached: "Dictation limit reached."
        case .rateLimited: "Too many dictations in a minute."
        case .unavailable(let reason): "Transcription unavailable: \(reason)"
        }
    }
}

/// Speech-to-text in the cloud, as `OpenAITranscriber` sees it (`TranscriptionClient`, or a fake).
@MainActor
protocol CloudTranscribing: AnyObject, Sendable {
    var isConfigured: Bool { get }
    /// `language`: BCP-47 tag of the dictation; `keywords`: personal dictionary terms.
    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?,
                    keywords: [String]) async throws(CloudTranscriptionError) -> String
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

    private let backend: Backend?
    /// The function gives OpenAI 20 s (`TRANSCRIBE_DEADLINE_MS`); the rest is for the upload.
    private let timeout: TimeInterval = 25

    init(backend: Backend?) {
        self.backend = backend
    }

    var isConfigured: Bool { backend != nil }

    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?,
                    keywords: [String]) async throws(CloudTranscriptionError) -> String {
        guard let backend else { throw .notConfigured }
        let body = RequestBody(
            dictationId: UUID(), audio: audio.base64EncodedString(), format: format.rawValue,
            language: language, keywords: Array(keywords.prefix(100)))
        do {
            try await backend.ensureSession()
            let response: Response = try await backend.client.functions.invoke(
                "transcribe", options: FunctionInvokeOptions(body: body, timeoutInterval: timeout))
            return response.text
        } catch let FunctionsError.httpError(code, _) {
            switch code {
            case 402: throw .limitReached
            case 429: throw .rateLimited
            default: throw .unavailable("HTTP \(code)")
            }
        } catch {
            throw .unavailable(error.localizedDescription)
        }
    }
}
