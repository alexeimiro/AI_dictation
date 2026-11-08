import Foundation
import MurmurCore

/// Calls the `cleanup` Edge Function (an OpenAI model) with the transcript.
@MainActor
final class CleanupClient: Cleaning {
    struct Response: Decodable, Sendable {
        let text: String
        /// "cleaned", or "raw" when the model output was unusable and the transcript came back.
        let status: String
        let words: Int
        let model: String?
        let ttftMs: Int?
        let totalMs: Int?
        let remaining: Int?
        /// Why a reply is "raw": "refusal", or "untranslated" when a translation came back in the
        /// spoken language.
        var reason: String? = nil
        /// The language a translation was written in; nil for a cleanup. A cleanup function
        /// deployed before translation leaves it out: it ignores `targetLanguage` and cleans up in
        /// the spoken language.
        var targetLanguage: String? = nil
        /// What the function measured; a function deployed before timings leaves it out.
        var timings: ServerTiming? = nil
        /// How the request went. Set by the client, never decoded from the reply.
        var request: RequestTiming? = nil

        private enum CodingKeys: String, CodingKey {
            case text, status, words, model, ttftMs, totalMs, remaining, reason, targetLanguage, timings
        }
    }

    enum Failure: Error {
        case notConfigured
        case limitReached
        case rateLimited
        case unavailable(String)
        /// The server rejected the signed-in account's session (`BackendError.signedOut`). Nothing
        /// was sent, and nothing will be until the user signs in again.
        case signedOut
    }

    private struct RequestBody: Encodable {
        struct Entry: Encodable {
            let term: String
            let misspelling: String?
        }

        struct Snippet: Encodable {
            let token: String
            let trigger: String
        }

        let dictationId: UUID
        let transcript: String
        let language: String?
        let targetLanguage: String?
        let style: String
        let dictionary: [Entry]
        let snippets: [Snippet]
    }

    private let functions: EdgeFunctionClient?
    /// The server bounds the whole model call at 9 s (`CLEANUP_DEADLINE_MS`); this leaves ~2 s
    /// for the edge function and the network. Russian costs more tokens per word, so long
    /// dictations use most of it.
    private let timeout: TimeInterval = 11

    init(functions: EdgeFunctionClient?) {
        self.functions = functions
    }

    var isConfigured: Bool { functions != nil }

    func clean(
        dictationId: UUID,
        transcript: String,
        language: String?,
        targetLanguage: String?,
        style: StylePreset,
        dictionary: [DictionaryTerm],
        snippets: [SnippetDefinition]
    ) async throws(Failure) -> Response {
        guard let functions else { throw .notConfigured }
        let body = RequestBody(
            dictationId: dictationId,
            transcript: transcript,
            language: language,
            targetLanguage: targetLanguage,
            style: style.rawValue,
            dictionary: dictionary.prefix(300).map { .init(term: $0.term, misspelling: $0.misspelling) },
            snippets: snippets.prefix(200).map { .init(token: SnippetPlaceholders.token(for: $0), trigger: $0.trigger) })
        do {
            let reply = try await functions.post("cleanup", body: body, timeout: timeout)
            var response = try JSONDecoder().decode(Response.self, from: reply.data)
            response.request = reply.timing
            return response
        } catch EdgeFunctionError.httpError(let code) {
            switch code {
            case 402: throw .limitReached
            case 429: throw .rateLimited
            default: throw .unavailable("HTTP \(code)")
            }
        } catch EdgeFunctionError.transport(BackendError.signedOut) {
            throw .signedOut
        } catch {
            throw .unavailable(error.localizedDescription)
        }
    }
}
