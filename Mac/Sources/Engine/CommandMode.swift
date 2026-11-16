@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import MurmurCore

/// The spoken instruction, kept as 16 kHz mono 16-bit WAV: small, and what `command` takes.
final class WavRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = Data()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let converter else { return }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = output.int16ChannelData?[0] else { return }
            samples.append(Data(bytes: channel, count: Int(output.frameLength) * 2))
        }
    }

    /// The recording so far as a WAV file.
    func wav() -> Data {
        let pcm = lock.withLock { samples }
        var header = Data()
        func add<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); add(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8)); header.append(contentsOf: Array("fmt ".utf8))
        add(UInt32(16)); add(UInt16(1)); add(UInt16(1)); add(UInt32(16_000)); add(UInt32(32_000)); add(UInt16(2)); add(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); add(UInt32(pcm.count))
        return header + pcm
    }

    var seconds: Double { lock.withLock { Double(samples.count) / 32_000 } }
}

/// What's selected in the app in front: through Accessibility, or (for apps that don't say)
/// by copying it with ⌘C and putting the clipboard back.
@MainActor
enum SelectionReader {
    static func read() async -> String? {
        if let app = NSWorkspace.shared.frontmostApplication {
            let (_, element) = TextInserter.focused(in: app)
            if let element, let selected = string(element, kAXSelectedTextAttribute), !selected.isEmpty {
                return selected
            }
        }
        return await copySelection()
    }

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        let before = pasteboard.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: down) // C
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        for _ in 0..<12 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard pasteboard.changeCount != before else { return nil }
        let copied = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if !saved.isEmpty {
            pasteboard.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }
        return copied?.isEmpty == false ? copied : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// The `command` function: the selection and the spoken instruction in, the new text out.
@MainActor
struct CommandClient {
    struct Reply: Decodable {
        let instruction: String
        let text: String
        let status: String
        let words: Int?
    }

    enum Failure: Error {
        case proRequired, signedOut, unavailable
    }

    let functions: EdgeFunctionClient?

    func send(selection: String, audio: Data, language: String?, hints: [String]) async throws(Failure) -> Reply {
        guard let functions else { throw .unavailable }
        let id = UUID()
        struct Metadata: Encodable {
            let commandId: String
            let format = "wav"
            let language: String?
            let languages: [String]
            let selection: String
        }
        var body = MultipartBody()
        let metadata = Metadata(commandId: id.uuidString.lowercased(), language: language, languages: hints, selection: selection)
        guard let json = try? JSONEncoder().encode(metadata) else { throw .unavailable }
        body.appendField(name: "metadata", contentType: "application/json", json)
        body.appendFile(name: "audio", filename: "instruction.wav", contentType: "audio/wav", audio)
        do {
            let reply = try await functions.send("command", payload: body.finalized(), contentType: body.contentType,
                                                 extraHeaders: ["x-murmur-dictation": id.uuidString.lowercased()],
                                                 timeout: 35)
            guard let decoded = try? JSONDecoder().decode(Reply.self, from: reply.data) else { throw Failure.unavailable }
            return decoded
        } catch EdgeFunctionError.httpError(code: 402) {
            throw .proRequired
        } catch EdgeFunctionError.httpError(code: 401) {
            throw .signedOut
        } catch {
            throw .unavailable
        }
    }
}
