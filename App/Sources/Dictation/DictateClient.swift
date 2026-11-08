import Foundation
import MurmurCore

/// What `dictate` needs to translate a dictation in the request that transcribes it.
struct TranslationRequest: Sendable {
    /// The dictation's `requestId`: its usage is counted once, however often it's sent.
    let dictationId: UUID
    let targetLanguage: String
    let style: StylePreset
    let dictionary: [DictionaryTerm]
    let snippets: [SnippetDefinition]
}

/// A dictation transcribed and translated in one `dictate` request.
struct DictateReply: Sendable {
    let transcript: String
    /// The translation as `cleanup` answers one. `.unavailable` when the function kept the
    /// transcript but couldn't translate it (an OpenAI error, or out of time).
    let translation: Result<CleanupClient.Response, CleanupClient.Failure>
    let timing: RequestTiming
}

/// How a warm-up went, for `BackendWarmup`.
enum WarmupResult: Sendable {
    /// The function answered: the connection, its worker and the token check are warm.
    case warmed(RequestTiming)
    /// The function rejected the access token (401).
    case rejected
    /// Not sent (`dictate` unavailable), or it failed.
    case skipped
}

/// `dictate`'s audio and warm modes as `OpenAITranscriber` and `BackendWarmup` see them
/// (`DictateClient`, or a fake).
@MainActor
protocol Dictating: AnyObject, Sendable {
    /// Configured, switched on (`translateInOneRequest`), and not answered 404 in this process.
    var isAvailable: Bool { get }
    /// When `dictate` last answered, for the warm-up's debounce.
    var lastReplyAt: ContinuousClock.Instant? { get }
    /// `language`: BCP-47 tag of the dictation, nil to detect it; `keywords`: personal dictionary
    /// terms. Throws `.notDeployed` on a 404, and when unavailable.
    func dictate(audio: Data, format: EncodedAudio.Format, language: String?, keywords: [String],
                 translation: TranslationRequest) async throws(CloudTranscriptionError) -> DictateReply
    func warm() async -> WarmupResult
}

/// Calls the `dictate` Edge Function: a translation's audio goes up once, and the function
/// transcribes and translates it on one worker, instead of `transcribe` then `cleanup` (two
/// round trips, each checking the token and the limits). A 404 (not deployed, or switched off
/// with `DICTATE_DISABLED`) turns it off until the app restarts, and dictations go back to those two.
@MainActor
final class DictateClient: Dictating {
    /// The "metadata" part.
    private struct Metadata: Encodable {
        let dictationId: UUID
        let format: String
        let language: String?
        let keywords: [String]
        let targetLanguage: String
        let style: String
        let dictionary: [CleanupClient.Entry]
        let snippets: [CleanupClient.Snippet]
    }

    /// The reply's transcription; the rest of it is `cleanup`'s reply.
    private struct Transcription: Decodable {
        let transcript: String?
    }

    /// A warm-up's reply names its worker beside `timings`, not in them.
    private struct Warmed: Decodable {
        let cold: Bool?
        let region: String?
        let workerAgeMs: Int?
        let executionId: String?
    }

    private let functions: EdgeFunctionClient?
    private let settings: SharedSettings
    private var deployed = true
    private(set) var lastReplyAt: ContinuousClock.Instant?
    /// URLRequest's timeout counts from the last byte sent or received, so a slow upload doesn't use
    /// it up. Once the audio is in, the function gives the transcription 20 s and the translation
    /// what is left of 26 s (`DICTATE_DEADLINE_MS`).
    private let timeout: TimeInterval = 30
    /// The function bounds each of its warm-up round trips at 3 s.
    private let warmTimeout: TimeInterval = 5

    /// `settings`: tests pass their own, so the Debug switch is the default one.
    init(functions: EdgeFunctionClient?, settings: SharedSettings = .shared) {
        self.functions = functions
        self.settings = settings
    }

    var isAvailable: Bool { functions != nil && deployed && settings.translateInOneRequest }

    func dictate(audio: Data, format: EncodedAudio.Format, language: String?, keywords: [String],
                 translation: TranslationRequest) async throws(CloudTranscriptionError) -> DictateReply {
        guard let functions, isAvailable else { throw .notDeployed }
        let metadata = Metadata(
            dictationId: translation.dictationId, format: format.rawValue, language: language,
            keywords: Array(keywords.prefix(100)), targetLanguage: translation.targetLanguage,
            style: translation.style.rawValue, dictionary: CleanupClient.Entry.wire(translation.dictionary),
            snippets: CleanupClient.Snippet.wire(translation.snippets))
        var body = MultipartBody()
        do {
            body.appendField(name: "metadata", contentType: "application/json", try JSONEncoder().encode(metadata))
        } catch {
            throw .unavailable(error.localizedDescription)
        }
        body.appendFile(name: "audio", filename: "audio.\(format.rawValue)", contentType: format.mimeType, audio)
        do {
            // The header lets the function check the token and the limits while the audio uploads.
            let reply = try await functions.send(
                "dictate", payload: body.finalized(), contentType: body.contentType,
                extraHeaders: ["x-murmur-dictation": translation.dictationId.uuidString], timeout: timeout)
            lastReplyAt = .now
            let decoder = JSONDecoder()
            let transcript = try decoder.decode(Transcription.self, from: reply.data).transcript ?? ""
            let response = try decoder.decode(CleanupClient.Response.self, from: reply.data)
            return DictateReply(transcript: transcript, translation: Self.translation(response), timing: reply.timing)
        } catch EdgeFunctionError.httpError(code: 404) {
            deployed = false
            throw .notDeployed
        } catch {
            throw CloudTranscriptionError(error)
        }
    }

    /// Checks the token and opens the connections, here and on the function's side, while the
    /// user speaks (`x-murmur-warm`). The function writes nothing and counts nothing for it.
    func warm() async -> WarmupResult {
        guard let functions, isAvailable else { return .skipped }
        do {
            let reply = try await functions.send("dictate", extraHeaders: ["x-murmur-warm": "1"], timeout: warmTimeout)
            lastReplyAt = .now
            var timing = reply.timing
            if let worker = try? JSONDecoder().decode(Warmed.self, from: reply.data) {
                var server = timing.server ?? ServerTiming()
                server.cold = worker.cold ?? server.cold
                server.region = worker.region ?? server.region
                server.workerAgeMs = worker.workerAgeMs ?? server.workerAgeMs
                server.executionId = worker.executionId ?? server.executionId
                timing.server = server
            }
            return .warmed(timing)
        } catch .httpError(code: 401) {
            return .rejected
        } catch .httpError(code: 404) {
            deployed = false
            return .skipped
        } catch {
            return .skipped
        }
    }

    /// "unavailable": the transcript came back without its translation, and nothing was counted.
    private static func translation(_ response: CleanupClient.Response)
        -> Result<CleanupClient.Response, CleanupClient.Failure> {
        guard response.status == "unavailable" else { return .success(response) }
        return .failure(.unavailable("dictate couldn't translate (\(response.reason ?? "no reason given"))"))
    }
}

private extension EncodedAudio.Format {
    var mimeType: String {
        switch self {
        case .m4a: "audio/mp4"
        case .wav: "audio/wav"
        }
    }
}
