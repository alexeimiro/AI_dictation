import Foundation
import MurmurCore

/// What `dictate` needs to have the model write a dictation's text in the request that
/// transcribes it: its translation (`targetLanguage`), or, with no target, its grammar improved.
struct ModelRequest: Sendable {
    /// The dictation's `requestId`: its usage is counted once, however often it's sent.
    let dictationId: UUID
    /// Nil for Improve my grammar in the spoken language.
    let targetLanguage: String?
    let style: StylePreset
    let dictionary: [DictionaryTerm]
    let snippets: [SnippetDefinition]
}

/// A dictation transcribed and written (translated, or its grammar improved) in one `dictate` request.
struct DictateReply: Sendable {
    let transcript: String
    /// The languages the transcription heard, first the main one (ISO 639-1); empty when unsure.
    let languages: [String]
    /// The model's text as `cleanup` answers it. `.unavailable` when the function kept the
    /// transcript but couldn't write it (an OpenAI error, or out of time).
    let modelReply: Result<CleanupClient.Response, CleanupClient.Failure>
    let timing: RequestTiming

    init(transcript: String, languages: [String] = [],
         modelReply: Result<CleanupClient.Response, CleanupClient.Failure>, timing: RequestTiming) {
        self.transcript = transcript
        self.languages = languages
        self.modelReply = modelReply
        self.timing = timing
    }
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
                 request: ModelRequest) async throws(CloudTranscriptionError) -> DictateReply
    func warm() async -> WarmupResult
}

/// Calls the `dictate` Edge Function: a translated or Improve my grammar dictation's audio goes
/// up once, and the function transcribes and writes it on one worker, instead of `transcribe`
/// then `cleanup` (two round trips, each checking the token and the limits). A 404 (not deployed, or switched off
/// with `DICTATE_DISABLED`) turns it off until the app restarts, and dictations go back to those two.
@MainActor
final class DictateClient: Dictating {
    /// The "metadata" part.
    private struct Metadata: Encodable {
        let dictationId: UUID
        let format: String
        let language: String?
        let keywords: [String]
        /// Left out for Improve my grammar.
        let targetLanguage: String?
        let style: String
        let dictionary: [CleanupClient.Entry]
        let snippets: [CleanupClient.Snippet]
    }

    /// The reply's transcription; the rest of it is `cleanup`'s reply.
    private struct Transcription: Decodable {
        let transcript: String?
        let languages: [String]?
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
                 request: ModelRequest) async throws(CloudTranscriptionError) -> DictateReply {
        guard let functions, isAvailable else { throw .notDeployed }
        let metadata = Metadata(
            dictationId: request.dictationId, format: format.rawValue, language: language,
            keywords: Array(keywords.prefix(100)), targetLanguage: request.targetLanguage,
            style: request.style.rawValue, dictionary: CleanupClient.Entry.wire(request.dictionary),
            snippets: CleanupClient.Snippet.wire(request.snippets))
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
                extraHeaders: ["x-murmur-dictation": request.dictationId.uuidString], timeout: timeout)
            lastReplyAt = .now
            let decoder = JSONDecoder()
            let transcription = try decoder.decode(Transcription.self, from: reply.data)
            let response = try decoder.decode(CleanupClient.Response.self, from: reply.data)
            return DictateReply(transcript: transcription.transcript ?? "", languages: transcription.languages ?? [],
                                modelReply: Self.modelReply(response), timing: reply.timing)
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

    /// "unavailable": the transcript came back without its text, and nothing was counted.
    private static func modelReply(_ response: CleanupClient.Response)
        -> Result<CleanupClient.Response, CleanupClient.Failure> {
        guard response.status == "unavailable" else { return .success(response) }
        return .failure(.unavailable("dictate couldn't write the text (\(response.reason ?? "no reason given"))"))
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
