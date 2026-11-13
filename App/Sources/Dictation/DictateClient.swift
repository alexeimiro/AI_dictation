import Foundation
import MurmurCore

/// What `dictate` needs to have the model write a dictation's text in the request that
/// transcribes it: its translation (`targetLanguage`), or, with no target, the text in `style`.
struct ModelRequest: Sendable {
    /// The dictation's `requestId`: its usage is counted once, however often it's sent.
    let dictationId: UUID
    /// Nil for a style written in the spoken language.
    let targetLanguage: String?
    let style: StylePreset
    let dictionary: [DictionaryTerm]
    let snippets: [SnippetDefinition]
}

/// A dictation transcribed and written (translated, or put in its style) in one `dictate` request.
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
    /// A Word for word dictation can be transcribed here too: available, and the function hasn't
    /// refused one in this process (see `transcribe`).
    var transcribesAlone: Bool { get }
    /// When `dictate` last answered, for the warm-up's debounce.
    var lastReplyAt: ContinuousClock.Instant? { get }
    /// `language`: BCP-47 tag of the dictation, nil to detect it; `languageHints`: then, the user's
    /// languages to detect it among; `keywords`: personal dictionary terms. Throws `.notDeployed`
    /// on a 404, and when unavailable.
    func dictate(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                 keywords: [String], request: ModelRequest) async throws(CloudTranscriptionError) -> DictateReply
    /// A Word for word dictation's transcript alone: no model writes it, but the function checks
    /// the token and the limits while the audio uploads, which `transcribe` does one after the
    /// other. Throws `.notDeployed` when the function can't take it, or its checks couldn't run:
    /// the same audio then goes to `transcribe`.
    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                    keywords: [String], dictationId: UUID) async throws(CloudTranscriptionError) -> CloudTranscript
    func warm() async -> WarmupResult
}

/// Calls the `dictate` Edge Function: the audio of a dictation the model writes (a translation, or
/// any style but Word for word) goes up once, and the function transcribes and writes it on one worker, instead of `transcribe`
/// then `cleanup` (two round trips, each checking the token and the limits). A 404 (not deployed, or switched off
/// with `DICTATE_DISABLED`) turns it off until the app restarts, and dictations go back to those two.
/// A Word for word dictation goes up the same way and comes back as its transcript alone.
@MainActor
final class DictateClient: Dictating {
    /// Where the functions' database is. `dictate` is asked to run there (`x-region`): from another
    /// region each of its database calls crosses regions, about 100 ms a dictation in the November
    /// 2026 timings, and one region's workers are warm more often than two regions' are.
    static let region = "eu-central-1"

    /// The "metadata" part.
    private struct Metadata: Encodable {
        let dictationId: UUID
        let format: String
        let language: String?
        /// The user's languages while `language` is detected; left out when empty.
        let languages: [String]?
        let keywords: [String]
        /// Left out for a style written in the spoken language.
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
    /// The function answered a Word for word dictation 400: a deployment from before it took one.
    private var refusesPlain = false
    private(set) var lastReplyAt: ContinuousClock.Instant?
    /// URLRequest's timeout counts from the last byte sent or received, so a slow upload doesn't use
    /// it up. Once the audio is in, the function gives the transcription 20 s and the translation
    /// what is left of 26 s (`DICTATE_DEADLINE_MS`).
    private let timeout: TimeInterval = 30
    /// With no model to write the text, only the transcription's 20 s are left, as in `transcribe`.
    private let plainTimeout: TimeInterval = 25
    /// The function bounds each of its warm-up round trips at 3 s.
    private let warmTimeout: TimeInterval = 5

    /// `settings`: tests pass their own, so the Debug switch is the default one.
    init(functions: EdgeFunctionClient?, settings: SharedSettings = .shared) {
        self.functions = functions
        self.settings = settings
    }

    var isAvailable: Bool { functions != nil && deployed && settings.translateInOneRequest }

    var transcribesAlone: Bool { isAvailable && !refusesPlain }

    func dictate(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                 keywords: [String], request: ModelRequest) async throws(CloudTranscriptionError) -> DictateReply {
        guard let functions, isAvailable else { throw .notDeployed }
        let metadata = Metadata(
            dictationId: request.dictationId, format: format.rawValue, language: language,
            languages: language == nil && !languageHints.isEmpty ? languageHints : nil,
            keywords: Array(keywords.prefix(100)), targetLanguage: request.targetLanguage,
            style: request.style.rawValue, dictionary: CleanupClient.Entry.wire(request.dictionary),
            snippets: CleanupClient.Snippet.wire(request.snippets))
        let body: MultipartBody
        do {
            body = try Self.body(metadata, audio: audio, format: format)
        } catch {
            throw .unavailable(error.localizedDescription)
        }
        do {
            let reply = try await functions.send(
                "dictate", payload: body.finalized(), contentType: body.contentType,
                extraHeaders: Self.headers(naming: request.dictationId), timeout: timeout)
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

    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                    keywords: [String], dictationId: UUID) async throws(CloudTranscriptionError) -> CloudTranscript {
        guard let functions, transcribesAlone else { throw .notDeployed }
        // Word for word by name and no target: the function stops at the transcript.
        let metadata = Metadata(
            dictationId: dictationId, format: format.rawValue, language: language,
            languages: language == nil && !languageHints.isEmpty ? languageHints : nil,
            keywords: Array(keywords.prefix(100)), targetLanguage: nil,
            style: StylePreset.verbatim.rawValue, dictionary: [], snippets: [])
        let body: MultipartBody
        do {
            body = try Self.body(metadata, audio: audio, format: format)
        } catch {
            throw .unavailable(error.localizedDescription)
        }
        do {
            let reply = try await functions.send(
                "dictate", payload: body.finalized(), contentType: body.contentType,
                extraHeaders: Self.headers(naming: dictationId), timeout: plainTimeout)
            lastReplyAt = .now
            let transcription = try JSONDecoder().decode(Transcription.self, from: reply.data)
            return CloudTranscript(text: transcription.transcript ?? "", languages: transcription.languages ?? [],
                                   timing: reply.timing)
        } catch EdgeFunctionError.httpError(code: 404) {
            deployed = false
            throw .notDeployed
        } catch EdgeFunctionError.httpError(code: 400) {
            // A deployment from before `dictate` took Word for word refuses one for naming no
            // target. Not asked again until the app restarts.
            refusesPlain = true
            throw .notDeployed
        } catch EdgeFunctionError.httpError(code: 503) {
            // Its checks couldn't run, or it has no key. `transcribe` lets a dictation through when
            // its own checks can't run, so this one gets that chance.
            throw .notDeployed
        } catch {
            throw CloudTranscriptionError(error)
        }
    }

    /// The request's body: the metadata, then the audio as a file.
    private static func body(_ metadata: Metadata, audio: Data, format: EncodedAudio.Format) throws -> MultipartBody {
        var body = MultipartBody()
        body.appendField(name: "metadata", contentType: "application/json", try JSONEncoder().encode(metadata))
        body.appendFile(name: "audio", filename: "audio.\(format.rawValue)", contentType: format.mimeType, audio)
        return body
    }

    /// The dictation's id lets the function check the token and the limits while the audio uploads.
    private static func headers(naming dictationId: UUID) -> [String: String] {
        ["x-murmur-dictation": dictationId.uuidString, "x-region": region]
    }

    /// Checks the token and opens the connections, here and on the function's side, while the
    /// user speaks (`x-murmur-warm`). The function writes nothing and counts nothing for it.
    func warm() async -> WarmupResult {
        guard let functions, isAvailable else { return .skipped }
        do {
            // In the region the dictation's own request will ask for, or it warms another's workers.
            let reply = try await functions.send(
                "dictate", extraHeaders: ["x-murmur-warm": "1", "x-region": Self.region], timeout: warmTimeout)
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
