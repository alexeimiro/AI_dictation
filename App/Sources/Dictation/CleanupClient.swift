import Foundation
import MurmurCore
import Supabase

/// Calls the `cleanup` Edge Function (Claude) with the on-device transcript.
@MainActor
final class CleanupClient {
    struct Response: Decodable, Sendable {
        let text: String
        /// "cleaned", or "raw" when the model output was unusable and the transcript came back.
        let status: String
        let words: Int
        let model: String?
        let ttftMs: Int?
        let totalMs: Int?
        let remaining: Int?
    }

    enum Failure: Error {
        case notConfigured
        case limitReached
        case rateLimited
        case unavailable(String)
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
        let style: String
        let dictionary: [Entry]
        let snippets: [Snippet]
    }

    private let backend: Backend?
    /// Leaves ~2 s for the server's own 6 s model timeout plus network.
    private let timeout: TimeInterval = 8

    init(backend: Backend?) {
        self.backend = backend
    }

    var isConfigured: Bool { backend != nil }

    func clean(
        dictationId: UUID,
        transcript: String,
        language: String?,
        style: StylePreset,
        dictionary: [DictionaryTerm],
        snippets: [SnippetDefinition]
    ) async throws(Failure) -> Response {
        guard let backend else { throw .notConfigured }
        let body = RequestBody(
            dictationId: dictationId,
            transcript: transcript,
            language: language,
            style: style.rawValue,
            dictionary: dictionary.prefix(300).map { .init(term: $0.term, misspelling: $0.misspelling) },
            snippets: snippets.prefix(200).map { .init(token: SnippetPlaceholders.token(for: $0), trigger: $0.trigger) })
        do {
            try await backend.ensureSession()
            return try await backend.client.functions.invoke(
                "cleanup", options: FunctionInvokeOptions(body: body, timeoutInterval: timeout))
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
