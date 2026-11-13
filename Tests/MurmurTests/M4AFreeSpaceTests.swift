@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Murmur

struct M4AFreeSpaceTests {
    // MARK: Recordings, through the app's own encoder

    @Test(arguments: [EncodedAudio.standardBitRate, EncodedAudio.lowDataBitRate])
    func aDictationUploadsWithoutTheEmptySpace(bitRate: Int) throws {
        let samples = voiceLike(seconds: 7.8)
        let written = try EncodedAudio.writtenAAC(samples, sampleRate: 16_000, bitRate: bitRate)
        let upload = try EncodedAudio(samples: samples, sampleRate: 16_000, bitRate: bitRate)

        #expect(upload.format == .m4a)
        #expect(topLevelTypes(written) == ["ftyp", "moov", "free", "mdat"])
        #expect(topLevelTypes(upload.data) == ["ftyp", "moov", "mdat"])
        // What goes is the box of zeros Core Audio keeps for the header to grow into.
        let free = try #require(topLevelBox("free", in: written))
        #expect(free.count > 20_000)
        #expect(free.dropFirst(8).allSatisfy { $0 == 0 })
        #expect(upload.data.count == written.count - free.count)
    }

    @Test func theAudioDecodesToTheSameSamples() throws {
        let written = try EncodedAudio.writtenAAC(voiceLike(seconds: 7.8), sampleRate: 16_000)
        let compact = try #require(M4AFreeSpace.removed(from: written))

        #expect(topLevelBox("mdat", in: compact) == topLevelBox("mdat", in: written))
        expectChunksStartAtTheSameBytes(compact, as: written)
        let before = try decoded(written)
        #expect(before.count >= 124_800)
        #expect(try decoded(compact) == before)
    }

    @Test func theServerReadsTheSameLength() throws {
        let written = try EncodedAudio.writtenAAC(voiceLike(seconds: 7.8), sampleRate: 16_000)
        let compact = try #require(M4AFreeSpace.removed(from: written))

        let stated = try #require(movieDurationMs(written))
        #expect(movieDurationMs(compact) == stated)
        // The encoder's lead-in and its last frame's padding count too: 124 frames of 1,024 samples.
        #expect(stated == 7_936)
    }

    /// Past about 5½ minutes the header no longer fits ahead of the audio: Core Audio writes it at
    /// the end, and the space it kept at the start stays empty.
    @Test func aLongDictationWithItsHeaderAtTheEndLosesTheEmptySpaceToo() throws {
        let written = try EncodedAudio.writtenAAC(voiceLike(seconds: 400), sampleRate: 16_000)
        let compact = try #require(M4AFreeSpace.removed(from: written))

        #expect(topLevelTypes(written) == ["ftyp", "free", "mdat", "moov"])
        #expect(topLevelTypes(compact) == ["ftyp", "mdat", "moov"])
        #expect(written.count - compact.count > 24_000)
        expectChunksStartAtTheSameBytes(compact, as: written)
        #expect(movieDurationMs(compact) == movieDurationMs(written))
        #expect(try decoded(compact) == decoded(written))
    }

    // MARK: Files built box by box

    @Test(arguments: [false, true])
    func eachChunkMovesBackByTheSpaceAheadOfIt(sixtyFourBit: Bool) throws {
        let headerFirst = BuiltFile([.ftyp, .moov, .free(300), .mdat], sixtyFourBit: sixtyFourBit)
        let headerLast = BuiltFile([.ftyp, .skip(40), .free(500), .mdat, .moov], sixtyFourBit: sixtyFourBit)
        for built in [headerFirst, headerLast] {
            let compact = try #require(M4AFreeSpace.removed(from: built.data))
            #expect(!topLevelTypes(compact).contains("free"))
            #expect(!topLevelTypes(compact).contains("skip"))
            #expect(compact.count == built.data.count - built.emptyBytes)
            let offsets = try #require(chunkOffsets(in: compact))
            #expect(offsets.count == BuiltFile.chunks.count)
            for (offset, chunk) in zip(offsets, BuiltFile.chunks) {
                #expect(compact[offset..<(offset + chunk.count)] == chunk)
            }
        }
    }

    @Test func spaceAfterTheAudioGoesWithoutMovingAChunk() throws {
        let built = BuiltFile([.ftyp, .moov, .mdat, .free(64)])
        let compact = try #require(M4AFreeSpace.removed(from: built.data))

        #expect(topLevelTypes(compact) == ["ftyp", "moov", "mdat"])
        #expect(chunkOffsets(in: compact) == chunkOffsets(in: built.data))
    }

    @Test func aFileWithoutEmptySpaceIsLeftAsItIs() throws {
        let built = BuiltFile([.ftyp, .moov, .mdat])
        #expect(M4AFreeSpace.removed(from: built.data) == built.data)
    }

    @Test func aFileLaidOutAnyOtherWayIsLeftAsWritten() throws {
        let fragmented = BuiltFile([.ftyp, .moov, .free(100), .mdat], movieExtra: box("mvex", []))
        let otherBox = BuiltFile([.ftyp, .moov, .free(100), .mdat, .other("uuid")])
        let twoMovies = BuiltFile([.ftyp, .moov, .free(100), .mdat, .moov])
        let noFileType = BuiltFile([.moov, .free(100), .mdat])
        let noAudio = BuiltFile([.ftyp, .moov, .free(100)])
        let noTable = BuiltFile([.ftyp, .moov, .free(100), .mdat], table: .missing)
        let pastItsTable = BuiltFile([.ftyp, .moov, .free(100), .mdat], table: .countTooLarge)
        let outsideTheAudio = BuiltFile([.ftyp, .moov, .free(100), .mdat], table: .pointingAt(50))

        for built in [fragmented, otherBox, twoMovies, noFileType, noAudio, noTable, pastItsTable, outsideTheAudio] {
            #expect(M4AFreeSpace.removed(from: built.data) == nil, "\(built.parts)")
        }
        let whole = BuiltFile([.ftyp, .moov, .free(100), .mdat]).data
        #expect(M4AFreeSpace.removed(from: whole.prefix(whole.count - 3)) == nil, "cut short")
        #expect(M4AFreeSpace.removed(from: whole + [0, 0, 0]) == nil, "bytes left over")
        #expect(M4AFreeSpace.removed(from: Data("fake m4a bytes".utf8)) == nil)
        #expect(M4AFreeSpace.removed(from: Data()) == nil)
    }
}

// MARK: - Reading files

/// The types of a file's top-level boxes, in order.
private func topLevelTypes(_ file: Data) -> [String] {
    (boxes(in: [UInt8](file), from: 0, to: file.count) ?? []).map(\.type)
}

/// The first top-level box of `type`, whole.
private func topLevelBox(_ type: String, in file: Data) -> Data? {
    let bytes = [UInt8](file)
    return boxes(in: bytes, from: 0, to: bytes.count)?.first { $0.type == type }.map { Data(bytes[$0.start..<$0.end]) }
}

private struct ReadBox {
    let type: String
    let start: Int
    let contentStart: Int
    let end: Int
}

private func boxes(in bytes: [UInt8], from: Int, to: Int) -> [ReadBox]? {
    var found: [ReadBox] = []
    var offset = from
    while offset + 8 <= to {
        var size = Int(uint32(bytes, offset))
        var header = 8
        if size == 1 {
            size = Int(uint64(bytes, offset + 8))
            header = 16
        } else if size == 0 {
            size = to - offset
        }
        guard size >= header, offset + size <= to else { return nil }
        found.append(ReadBox(type: String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self),
                             start: offset, contentStart: offset + header, end: offset + size))
        offset += size
    }
    return offset == to ? found : nil
}

/// The boxes along `path`, from the top level down: the last one's.
private func box(at path: [String], in bytes: [UInt8]) -> ReadBox? {
    var range = (from: 0, to: bytes.count)
    var current: ReadBox?
    for type in path {
        guard let found = boxes(in: bytes, from: range.from, to: range.to)?.first(where: { $0.type == type }) else {
            return nil
        }
        current = found
        range = (found.contentStart, found.end)
    }
    return current
}

/// The first track's chunk offsets, from its `stco` or `co64`.
private func chunkOffsets(in file: Data) -> [Int]? {
    let bytes = [UInt8](file)
    let stbl = ["moov", "trak", "mdia", "minf", "stbl"]
    if let table = box(at: stbl + ["stco"], in: bytes) {
        let count = Int(uint32(bytes, table.contentStart + 4))
        return (0..<count).map { Int(uint32(bytes, table.contentStart + 8 + 4 * $0)) }
    }
    if let table = box(at: stbl + ["co64"], in: bytes) {
        let count = Int(uint32(bytes, table.contentStart + 4))
        return (0..<count).map { Int(uint64(bytes, table.contentStart + 8 + 8 * $0)) }
    }
    return nil
}

/// What the server's length reader (`supabase/functions/_shared/audio_duration.ts`) reads: the
/// movie header's duration over its timescale, in whole milliseconds.
private func movieDurationMs(_ file: Data) -> Int? {
    let bytes = [UInt8](file)
    guard let header = box(at: ["moov", "mvhd"], in: bytes) else { return nil }
    let version = bytes[header.contentStart]
    let timescaleAt = header.contentStart + 4 + (version == 1 ? 16 : 8)
    let timescale = Double(uint32(bytes, timescaleAt))
    let duration = version == 1 ? Double(uint64(bytes, timescaleAt + 4)) : Double(uint32(bytes, timescaleAt + 4))
    guard timescale > 0, duration > 0 else { return nil }
    return Int((duration / timescale * 1000).rounded())
}

/// Every chunk of `compact` starts with the bytes its chunk started with in `written`.
private func expectChunksStartAtTheSameBytes(_ compact: Data, as written: Data,
                                             sourceLocation: SourceLocation = #_sourceLocation) {
    guard let before = chunkOffsets(in: written), let after = chunkOffsets(in: compact) else {
        Issue.record("No chunk offsets", sourceLocation: sourceLocation)
        return
    }
    #expect(after.count == before.count, sourceLocation: sourceLocation)
    #expect(!before.isEmpty, sourceLocation: sourceLocation)
    let mismatched = zip(before, after).filter { old, new in
        written[old..<min(old + 16, written.count)] != compact[new..<min(new + 16, compact.count)]
    }
    #expect(mismatched.isEmpty, "\(mismatched.count) chunks moved to other bytes", sourceLocation: sourceLocation)
}

private struct UnreadableAudio: Error {}

/// The file's samples, decoded by Core Audio.
private func decoded(_ m4a: Data) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("free-space-\(UUID().uuidString).m4a")
    try m4a.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forReading: url)
    let frames = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
        throw UnreadableAudio()
    }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// `seconds` of something like a voice at 16 kHz: a buzz rising and falling three times a second,
/// over a little hiss. The same samples every time.
private func voiceLike(seconds: Double) -> [Float] {
    var noise: UInt32 = 12_345
    return (0..<Int(16_000 * seconds)).map { index in
        let time = Float(index) / 16_000
        noise = noise &* 1_664_525 &+ 1_013_904_223
        let hiss = (Float(noise >> 8) / Float(1 << 24) - 0.5) * 0.02
        let syllable = max(0, sin(2 * .pi * 3 * time))
        let buzz = sin(2 * .pi * 180 * time) + 0.5 * sin(2 * .pi * 360 * time) + 0.25 * sin(2 * .pi * 720 * time)
        return 0.17 * syllable * buzz + hiss
    }
}

private func uint32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
}

private func uint64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
    bytes[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
}

// MARK: - Building files

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian, Array.init)
}

private func box(_ type: String, _ content: [UInt8]) -> [UInt8] {
    bigEndian(UInt32(8 + content.count)) + Array(type.utf8) + content
}

/// A box with a version and flags.
private func fullBox(_ type: String, _ content: [UInt8]) -> [UInt8] {
    box(type, [0, 0, 0, 0] + content)
}

/// An M4A file of one track, built from `parts` in order, whose audio is three chunks of
/// different bytes: so a chunk offset that points anywhere but its own chunk is caught.
private struct BuiltFile {
    enum Part: CustomStringConvertible {
        case ftyp, moov, mdat
        case free(Int), skip(Int)
        case other(String)

        var description: String {
            switch self {
            case .ftyp: "ftyp"
            case .moov: "moov"
            case .mdat: "mdat"
            case .free(let size): "free(\(size))"
            case .skip(let size): "skip(\(size))"
            case .other(let type): type
            }
        }
    }

    enum Table {
        case chunks
        case missing
        /// Says it holds more entries than it does.
        case countTooLarge
        /// One chunk at this position in the file instead.
        case pointingAt(Int)
    }

    static let chunks = [Data(repeating: 0xA1, count: 30), Data(repeating: 0xB2, count: 45),
                         Data(repeating: 0xC3, count: 20)]

    let parts: [Part]
    let data: Data
    /// The bytes of the `free` and `skip` boxes.
    let emptyBytes: Int

    init(_ parts: [Part], sixtyFourBit: Bool = false, table: Table = .chunks, movieExtra: [UInt8] = []) {
        self.parts = parts
        let chunks = Self.chunks
        let audio = box("mdat", chunks.flatMap { [UInt8]($0) })

        func movie(offsets: [Int]) -> [UInt8] {
            var listed = offsets
            var count = offsets.count
            var hasTable = true
            switch table {
            case .chunks: break
            case .missing: hasTable = false
            case .countTooLarge: count += 1
            case .pointingAt(let position): (listed, count) = ([position], 1)
            }
            let offsetTable = fullBox(sixtyFourBit ? "co64" : "stco", bigEndian(UInt32(count)) + listed.flatMap(entry))
            let sampleTable = box("stbl", fullBox("stsz", bigEndian(UInt32(0)) + bigEndian(UInt32(0)))
                                  + (hasTable ? offsetTable : []))
            let header = fullBox("mvhd", [UInt8](repeating: 0, count: 8) + bigEndian(UInt32(16_000))
                                 + bigEndian(UInt32(16_000)) + [UInt8](repeating: 0, count: 80))
            return box("moov", header + box("trak", box("mdia", box("minf", sampleTable))) + movieExtra)
        }
        func entry(_ offset: Int) -> [UInt8] {
            sixtyFourBit ? bigEndian(UInt64(offset)) : bigEndian(UInt32(offset))
        }
        func bytes(of part: Part, offsets: [Int]) -> [UInt8] {
            switch part {
            case .ftyp: box("ftyp", Array("M4A ".utf8) + bigEndian(UInt32(0)) + Array("M4A mp42isom".utf8))
            case .moov: movie(offsets: offsets)
            case .mdat: audio
            case .free(let size): box("free", [UInt8](repeating: 0, count: size - 8))
            case .skip(let size): box("skip", [UInt8](repeating: 0, count: size - 8))
            case .other(let type): box(type, [1, 2, 3, 4])
            }
        }

        // The movie's size doesn't depend on the offsets it holds: lay the file out once to find
        // where the audio lands, then again with the offsets.
        let placeholder = Array(repeating: 0, count: chunks.count)
        var audioStart = 0
        for part in parts {
            if case .mdat = part { break }
            audioStart += bytes(of: part, offsets: placeholder).count
        }
        var offsets: [Int] = []
        var position = audioStart + 8
        for chunk in chunks {
            offsets.append(position)
            position += chunk.count
        }
        data = Data(parts.flatMap { bytes(of: $0, offsets: offsets) })
        emptyBytes = parts.reduce(0) { total, part in
            switch part {
            case .free(let size), .skip(let size): total + size
            default: total
            }
        }
    }
}
