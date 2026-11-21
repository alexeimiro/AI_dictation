import Foundation

/// Takes out the empty space Core Audio leaves in the M4A files it writes.
///
/// `AVAudioFile` keeps the file's first 24 KB for the header (`moov`), so the header can go ahead
/// of the audio (`mdat`), and fills what the header doesn't use with a `free` box of zeros: about
/// 23 KB in every recording, most of a short dictation's upload. A recording too long for its
/// header to fit there (about 5½ minutes) gets the header after the audio, and the whole 24 KB
/// stays empty.
///
/// The empty boxes go, and the track's chunk offsets, the only positions such a file records,
/// move back by the bytes that went ahead of each chunk. The audio and the rest of the header
/// stay byte for byte as written, so the file decodes to the same samples and states the same
/// length. A file laid out any other way is left as written.
enum M4AFreeSpace {
    /// `file` without its top-level `free` and `skip` boxes; the same bytes when it has none; nil
    /// when it isn't laid out as Core Audio writes it, to be sent as written.
    static func removed(from file: Data) -> Data? {
        let bytes = [UInt8](file)
        guard let top = boxes(in: bytes, from: 0, to: bytes.count),
              top.first?.type == "ftyp",
              top.allSatisfy({ topLevel.contains($0.type) }) else { return nil }
        let empty = top.filter { emptyTypes.contains($0.type) }
        guard !empty.isEmpty else { return file }
        let movies = top.filter { $0.type == "moov" }
        let audio = top.filter { $0.type == "mdat" }
        guard movies.count == 1, let movie = movies.first, !audio.isEmpty,
              let tables = chunkOffsetTables(in: bytes, movie: movie) else { return nil }

        var patched = bytes
        for table in tables {
            for index in 0..<table.count {
                let at = table.firstEntry + index * table.entrySize
                let offset = table.entrySize == 4
                    ? Int(readUInt32(bytes, at)) : Int(truncatingIfNeeded: readUInt64(bytes, at))
                // A chunk is audio: it starts inside an `mdat`, and so never inside a box that goes.
                guard offset >= 0, audio.contains(where: { $0.contentStart <= offset && offset < $0.end }) else {
                    return nil
                }
                let moved = offset - empty.filter { $0.end <= offset }.reduce(0) { $0 + $1.size }
                if table.entrySize == 4 {
                    writeUInt32(UInt32(moved), into: &patched, at: at)
                } else {
                    writeUInt64(UInt64(moved), into: &patched, at: at)
                }
            }
        }

        var output = Data(capacity: bytes.count - empty.reduce(0) { $0 + $1.size })
        for box in top where !emptyTypes.contains(box.type) {
            output.append(contentsOf: patched[box.start..<box.end])
        }
        return output
    }

    /// The only top-level boxes Core Audio's M4A files hold.
    private static let topLevel: Set<String> = ["ftyp", "moov", "mdat", "free", "skip"]
    /// Boxes a reader skips by definition.
    private static let emptyTypes: Set<String> = ["free", "skip"]

    private struct Box {
        let type: String
        /// The box's first byte, its content's first byte, and the byte after it.
        let start: Int
        let contentStart: Int
        let end: Int

        var size: Int { end - start }
    }

    /// A `stco` (32-bit) or `co64` (64-bit) table: where its entries are.
    private struct ChunkOffsets {
        let firstEntry: Int
        let count: Int
        let entrySize: Int
    }

    /// The boxes laid out from `from` to `to`, or nil when one runs past `to` or a few bytes are left over.
    private static func boxes(in bytes: [UInt8], from: Int, to: Int) -> [Box]? {
        var found: [Box] = []
        var offset = from
        while offset < to {
            guard to - offset >= 8 else { return nil }
            var size = Int(readUInt32(bytes, offset))
            var header = 8
            if size == 1 {
                // A 64-bit size follows the type.
                guard to - offset >= 16 else { return nil }
                let large = readUInt64(bytes, offset + 8)
                guard large <= UInt64(to - offset) else { return nil }
                size = Int(large)
                header = 16
            } else if size == 0 {
                // The box runs to the end.
                size = to - offset
            }
            guard size >= header, size <= to - offset else { return nil }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            found.append(Box(type: type, start: offset, contentStart: offset + header, end: offset + size))
            offset += size
        }
        return found
    }

    /// Every track's chunk offset table, or nil when a track has none, or the movie is fragmented
    /// (its samples are found another way).
    private static func chunkOffsetTables(in bytes: [UInt8], movie: Box) -> [ChunkOffsets]? {
        guard let children = boxes(in: bytes, from: movie.contentStart, to: movie.end),
              !children.contains(where: { $0.type == "mvex" }) else { return nil }
        let tracks = children.filter { $0.type == "trak" }
        guard !tracks.isEmpty else { return nil }
        var tables: [ChunkOffsets] = []
        for track in tracks {
            guard let media = child("mdia", of: track, in: bytes),
                  let information = child("minf", of: media, in: bytes),
                  let sampleTable = child("stbl", of: information, in: bytes),
                  let sampleBoxes = boxes(in: bytes, from: sampleTable.contentStart, to: sampleTable.end) else {
                return nil
            }
            let offsetBoxes = sampleBoxes.filter { $0.type == "stco" || $0.type == "co64" }
            guard offsetBoxes.count == 1, let table = offsetBoxes.first else { return nil }
            let entrySize = table.type == "stco" ? 4 : 8
            // Version and flags, then the number of entries.
            guard table.end - table.contentStart >= 8 else { return nil }
            let count = Int(readUInt32(bytes, table.contentStart + 4))
            guard count <= (table.end - table.contentStart - 8) / entrySize else { return nil }
            tables.append(ChunkOffsets(firstEntry: table.contentStart + 8, count: count, entrySize: entrySize))
        }
        return tables
    }

    /// `parent`'s one child of `type`.
    private static func child(_ type: String, of parent: Box, in bytes: [UInt8]) -> Box? {
        guard let children = boxes(in: bytes, from: parent.contentStart, to: parent.end) else { return nil }
        let matching = children.filter { $0.type == type }
        return matching.count == 1 ? matching.first : nil
    }

    private static func readUInt32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func writeUInt32(_ value: UInt32, into bytes: inout [UInt8], at: Int) {
        for index in 0..<4 { bytes[at + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
    }

    private static func writeUInt64(_ value: UInt64, into bytes: inout [UInt8], at: Int) {
        for index in 0..<8 { bytes[at + index] = UInt8(truncatingIfNeeded: value >> (56 - 8 * index)) }
    }
}
