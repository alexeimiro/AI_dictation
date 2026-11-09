import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
struct DictateClientTests {
    private let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.dictate.\(UUID().uuidString)"))
    private let reply = Data(#"""
        {"transcript":"привет всем","languages":["ru"],"transcribeModel":"gpt-transcribe","text":"Hi everyone.",
         "status":"cleaned","reason":null,"targetLanguage":"en-US","words":2,"model":"gpt-6.1-terra","ttftMs":null,
         "totalMs":690,"remaining":null,"timings":{"authMs":1,"transcribeMs":700,"modelMs":690,"executionId":"w1"}}
        """#.utf8)

    private func client() -> DictateClient {
        let functions = EdgeFunctionClient(
            baseURL: URL(string: "https://\(host)")!, headers: ["Apikey": "sb_publishable_test"],
            session: StubURLProtocol.session(), accessToken: { "user-jwt" })
        return DictateClient(functions: functions, settings: settings)
    }

    private func translation(id: UUID = UUID()) -> ModelRequest {
        ModelRequest(dictationId: id, targetLanguage: "en-US", style: .grammar,
                           dictionary: [DictionaryTerm(term: "Окафор", misspelling: "окофор")],
                           snippets: [])
    }

    private func dictate(with client: DictateClient, id: UUID = UUID()) async throws(CloudTranscriptionError) -> DictateReply {
        try await client.dictate(audio: Data([0x00, 0x01, 0x02]), format: .m4a, language: "ru-RU", languageHints: [],
                                 keywords: ["Окафор"], request: translation(id: id))
    }

    /// The parts of a multipart body by name: their headers and bytes.
    private func parts(of body: Data, boundary: String) -> [String: (headers: String, value: Data)] {
        var parts: [String: (String, Data)] = [:]
        var rest = body[...]
        let separator = Data("--\(boundary)\r\n".utf8)
        let blank = Data("\r\n\r\n".utf8)
        while let start = rest.range(of: separator) {
            rest = rest[start.upperBound...]
            guard let headersEnd = rest.range(of: blank) else { break }
            let headers = String(decoding: rest[..<headersEnd.lowerBound], as: UTF8.self)
            let valueStart = headersEnd.upperBound
            let end = rest.range(of: Data("\r\n--\(boundary)".utf8), in: valueStart..<rest.endIndex)?.lowerBound ?? rest.endIndex
            let name = headers.firstMatch(of: /name="([^"]+)"/).map { String($0.1) } ?? ""
            parts[name] = (headers, Data(rest[valueStart..<end]))
            rest = rest[end...]
        }
        return parts
    }

    @Test func sendsTheAudioAndWhatToTranslateInOneMultipartRequest() async throws {
        StubURLProtocol.answer(host, with: .init(body: reply))
        let id = UUID()
        _ = try await dictate(with: client(), id: id)

        let sent = try #require(StubURLProtocol.sent(to: host).first)
        #expect(sent.request.url?.path() == "/functions/v1/dictate")
        #expect(sent.request.timeoutInterval == 30)
        #expect(sent.request.value(forHTTPHeaderField: "x-murmur-dictation") == id.uuidString)
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        let contentType = try #require(sent.request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.firstMatch(of: /^multipart\/form-data; boundary=(.+)$/)).1
        let parts = parts(of: sent.body, boundary: String(boundary))

        let audio = try #require(parts["audio"])
        // Without a filename the function reads the part as text and answers 400.
        #expect(audio.headers.contains(#"filename="audio.m4a""#))
        #expect(audio.headers.contains("Content-Type: audio/mp4"))
        #expect(audio.value == Data([0x00, 0x01, 0x02]))

        let metadata = try #require(parts["metadata"])
        let fields = try #require(try JSONSerialization.jsonObject(with: metadata.value) as? [String: Any])
        #expect((fields["dictationId"] as? String).flatMap(UUID.init(uuidString:)) == id)
        #expect(fields["format"] as? String == "m4a")
        #expect(fields["language"] as? String == "ru-RU")
        #expect(fields["keywords"] as? [String] == ["Окафор"])
        #expect(fields["targetLanguage"] as? String == "en-US")
        #expect(fields["style"] as? String == "grammar")
        let dictionary = try #require(fields["dictionary"] as? [[String: String]])
        #expect(dictionary == [["term": "Окафор", "misspelling": "окофор"]])
        #expect(fields["snippets"] as? [Any] != nil)
    }

    @Test func aReplyCarriesTheTranscriptTheTranslationAndTheTiming() async throws {
        StubURLProtocol.answer(host, with: .init(body: reply))
        let dictated = try await dictate(with: client())

        #expect(dictated.transcript == "привет всем")
        let translation = try dictated.modelReply.get()
        #expect(translation.text == "Hi everyone.")
        #expect(translation.status == "cleaned")
        #expect(translation.targetLanguage == "en-US")
        #expect(translation.model == "gpt-6.1-terra")
        #expect(dictated.timing.function == "dictate")
        #expect(dictated.timing.server?.modelMs == 690)
        #expect(dictated.timing.server?.transcribeMs == 700)
    }

    /// The transcript came back without its translation: that's the translation's failure, not
    /// the transcription's.
    @Test func anUnavailableTranslationKeepsTheTranscript() async throws {
        StubURLProtocol.answer(host, with: .init(body: Data(#"""
            {"transcript":"привет всем","languages":["ru"],"text":"","status":"unavailable","reason":"deadline",
             "targetLanguage":"en-US","words":0,"model":null,"ttftMs":null,"totalMs":0,"remaining":null}
            """#.utf8)))
        let dictated = try await dictate(with: client())

        #expect(dictated.transcript == "привет всем")
        guard case .failure(.unavailable(let reason)) = dictated.modelReply else {
            Issue.record("expected an unavailable translation")
            return
        }
        #expect(reason.contains("deadline"))
    }

    /// A 404, from a project without `dictate` or with it switched off, turns it off for good.
    @Test func notDeployedTurnsItOff() async {
        StubURLProtocol.answer(host, with: .init(status: 404, body: Data(#"{"error":"dictate_disabled"}"#.utf8)))
        let client = client()
        #expect(client.isAvailable)

        await #expect(throws: CloudTranscriptionError.notDeployed) { try await dictate(with: client) }
        #expect(!client.isAvailable)
        await #expect(throws: CloudTranscriptionError.notDeployed) { try await dictate(with: client) }
        guard case .skipped = await client.warm() else { Issue.record("a warm-up went out"); return }
        #expect(StubURLProtocol.sent(to: host).count == 1)
    }

    @Test func statusesMapAsTranscribesDo() async {
        for (status, expected) in [(402, CloudTranscriptionError.limitReached), (429, .rateLimited),
                                   (502, .unavailable("HTTP 502")), (503, .unavailable("HTTP 503"))] {
            StubURLProtocol.answer(host, with: .init(status: status, body: Data(#"{"error":"x"}"#.utf8)))
            await #expect(throws: expected) { try await dictate(with: client()) }
        }
    }

    @Test func theDebugSwitchTurnsItOff() async {
        settings.translateInOneRequest = false
        let client = client()
        #expect(!client.isAvailable)
        await #expect(throws: CloudTranscriptionError.notDeployed) { try await dictate(with: client) }
        #expect(StubURLProtocol.sent(to: host).isEmpty)
    }

    @Test func aWarmUpSendsOnlyTheHeader() async throws {
        StubURLProtocol.answer(host, with: .init(body: Data(#"""
            {"warm":true,"cold":true,"region":"eu-central-1","workerAgeMs":5,"executionId":"w1",
             "timings":{"authMs":120,"openaiMs":580,"dbMs":150,"totalMs":760}}
            """#.utf8)))
        let client = client()
        guard case .warmed(let timing) = await client.warm() else {
            Issue.record("expected a warm-up")
            return
        }
        #expect(timing.function == "dictate")
        #expect(timing.server?.executionId == "w1")
        #expect(timing.server?.cold == true)
        #expect(timing.server?.authMs == 120)
        #expect(client.lastReplyAt != nil)
        let sent = try #require(StubURLProtocol.sent(to: host).first)
        #expect(sent.request.value(forHTTPHeaderField: "x-murmur-warm") == "1")
        #expect(sent.request.value(forHTTPHeaderField: "x-murmur-dictation") == nil)
        #expect(sent.request.timeoutInterval == 5)
        #expect(sent.body.isEmpty)
    }

    @Test func aRejectedTokenIsReported() async {
        StubURLProtocol.answer(host, with: .init(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)))
        guard case .rejected = await client().warm() else {
            Issue.record("expected the token to be rejected")
            return
        }
    }
}
