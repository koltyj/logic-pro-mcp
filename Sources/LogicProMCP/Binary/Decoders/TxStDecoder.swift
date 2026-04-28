import Foundation

// MARK: - TxSt Score Notation Style Decoder

/// A single decoded `TxSt` record — one entry in Logic Pro's score-notation
/// text-style table. Each record describes the font pairing, sample text,
/// and style-specific descriptor for a particular notation element
/// (e.g. "Plain Text", "Tuplets", "Chord Root").
///
/// Projects consistently ship 32 `TxSt` chunks with OIDs at step-4 (0, 4, 8,
/// …, 124). The OID indexes into a fixed label table; see
/// ``TxStDecoder/styleLabel(forOid:)`` for the mapping.
public struct TxStRecord: Sendable, Codable, Equatable {
    /// Chunk OID. Steps by 4 across the 32 style slots (0, 4, 8, …, 124).
    public let oid: UInt32
    /// Name of the primary (non-italic / body) font — e.g. `"Chicago"`.
    public let font1: String
    /// Name of the secondary / italic font — e.g. `"Times"` or `"Times-Italic"`.
    public let font2: String
    /// The literal sample text Logic renders in the style preview. In every
    /// project observed so far this is `"abcABC123456"`.
    public let sampleText: String
    /// Human-readable style label — e.g. `"Plain Text"`, `"Tuplets"`.
    public let styleLabel: String
    /// `font1` point size multiplied by 2 (i.e. 0x1E == 30 == 15pt).
    public let font1Size: Int
    /// `font2` point size multiplied by 2.
    public let font2Size: Int
    /// Raw style flags from offset 0x0E (bold/italic/underline bits, TBD).
    public let flags: UInt16
}

/// Decoder for `TxSt` (Text Style) chunks. Call ``TxStDecoder/decode(data:)``
/// with the full `ProjectData` blob; the decoder scans for chunks, filters
/// to `TxSt`, and parses each body independently.
///
/// Layout (see `reference/LOGIC_BINARY_SPEC.md` — "TxSt Score Notation Styles"):
/// ```
/// body[0x00..0x04]  u32 length indicator (low u16 is the meaningful field)
/// body[0x08..0x0A]  u16 font1 size scaled (size * 2)
/// body[0x0A..0x0C]  u16 font2 size scaled
/// body[0x0E..0x10]  u16 style flags
/// body[0x34..]      null-terminated ASCII font-1 name (max 40 bytes)
/// <after null, zero-padded>
///   three u16-length-prefixed ASCII strings in order:
///     1) style descriptor (e.g. "Plain Text")
///     2) sample text       (always "abcABC123456")
///     3) font-2 name       (e.g. "Times", "Times-Italic")
/// terminator:       0xFFFFFFFF near end of body
/// ```
public enum TxStDecoder {

    // MARK: - Constants (mirrored from ProjectDataParser so the decoder is standalone)

    private static let anchorOffset = 0x16
    private static let oidOffset = 0x0A
    private static let lengthOffset = 0x1C
    private static let chunkHeaderSize = 36

    private static let idTxSt = "TxSt"
    private static let minBodyLength = 0x40

    // Body field offsets
    private static let font1SizeOffset = 0x08
    private static let font2SizeOffset = 0x0A
    private static let flagsOffset = 0x0E
    private static let font1NameOffset = 0x34
    private static let font1NameMaxLen = 40

    // MARK: - Public API

    /// Decode every `TxSt` chunk found in `data`.
    ///
    /// - Parameter data: Raw `ProjectData` bytes.
    /// - Returns: All successfully-decoded records, in chunk-scan order.
    ///   Chunks whose body fails validation (truncated, non-ASCII strings,
    ///   missing any of the three length-prefixed strings) are skipped.
    public static func decode(data: Data) -> [TxStRecord] {
        var records: [TxStRecord] = []
        for chunk in scanChunks(data: data) where chunk.id == idTxSt {
            guard chunk.bodyLength >= minBodyLength else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            guard let record = decodeBody(body, oid: chunk.oid) else { continue }
            records.append(record)
        }
        return records
    }

    /// Map an OID to its canonical style label. Returns
    /// `"unknown(<oid>)"` for OIDs outside the documented set.
    public static func styleLabel(forOid oid: UInt32) -> String {
        return knownLabels[oid] ?? "unknown(\(oid))"
    }

    // MARK: - Body Decoding

    private static func decodeBody(_ body: Data, oid: UInt32) -> TxStRecord? {
        let font1Size = Int(readLE16(body, at: font1SizeOffset))
        let font2Size = Int(readLE16(body, at: font2SizeOffset))
        let flags = readLE16(body, at: flagsOffset)

        let font1 = readNullTerminatedASCII(
            body,
            at: font1NameOffset,
            maxLen: font1NameMaxLen
        )
        guard !font1.isEmpty, isPrintableASCII(font1) else { return nil }

        // Advance past the font-1 null terminator and scan for the three
        // length-prefixed strings.
        let nullEnd = findNullTerminator(
            body,
            at: font1NameOffset,
            maxLen: font1NameMaxLen
        )
        guard nullEnd < body.count else { return nil }

        let strings = readLengthPrefixedStrings(
            body,
            startAt: nullEnd + 1,
            count: 3
        )
        guard strings.count == 3 else { return nil }

        let styleLabel = strings[0]
        let sampleText = strings[1]
        let font2 = strings[2]

        return TxStRecord(
            oid: oid,
            font1: font1,
            font2: font2,
            sampleText: sampleText,
            styleLabel: styleLabel,
            font1Size: font1Size,
            font2Size: font2Size,
            flags: flags
        )
    }

    /// Walk `body` from `startAt`, skipping zero padding bytes, and read
    /// up to `count` consecutive `u16 length + ASCII` strings. Every
    /// character in each string must be printable ASCII; otherwise that
    /// attempt is discarded and the scanner tries the next offset.
    private static func readLengthPrefixedStrings(
        _ body: Data,
        startAt: Int,
        count: Int
    ) -> [String] {
        var results: [String] = []
        var cursor = startAt

        while cursor + 2 <= body.count && results.count < count {
            // Skip zero-byte padding between strings.
            if body[body.startIndex + cursor] == 0 {
                cursor += 1
                continue
            }

            let len = Int(readLE16(body, at: cursor))
            let asciiStart = cursor + 2
            let asciiEnd = asciiStart + len

            // Length must be plausible: non-zero, fits in the body, and the
            // payload must be entirely printable ASCII.
            guard len > 0, len <= 512, asciiEnd <= body.count else {
                cursor += 1
                continue
            }

            let slice = body[(body.startIndex + asciiStart)..<(body.startIndex + asciiEnd)]
            guard let text = String(data: Data(slice), encoding: .ascii),
                  isPrintableASCII(text) else {
                cursor += 1
                continue
            }

            results.append(text)
            cursor = asciiEnd
        }

        return results
    }

    private static func findNullTerminator(
        _ body: Data,
        at offset: Int,
        maxLen: Int
    ) -> Int {
        let limit = min(body.count, offset + maxLen)
        var idx = offset
        while idx < limit && body[body.startIndex + idx] != 0 {
            idx += 1
        }
        return idx
    }

    private static func readNullTerminatedASCII(
        _ body: Data,
        at offset: Int,
        maxLen: Int
    ) -> String {
        guard offset < body.count else { return "" }
        let end = findNullTerminator(body, at: offset, maxLen: maxLen)
        guard end > offset else { return "" }
        let slice = body[(body.startIndex + offset)..<(body.startIndex + end)]
        return String(data: Data(slice), encoding: .ascii) ?? ""
    }

    private static func isPrintableASCII(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for scalar in s.unicodeScalars {
            // Allow space (0x20) through tilde (0x7E).
            if scalar.value < 0x20 || scalar.value > 0x7E {
                return false
            }
        }
        return true
    }

    // MARK: - Chunk Scanner (copied from ProjectDataParser for decoder isolation)

    private struct ChunkInfo {
        let id: String
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let total = data.count
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
            let anchor = data.startIndex + offset + anchorOffset
            guard data[anchor] == 0x02,
                  data[anchor + 1] == 0x00,
                  data[anchor + 2] == 0x00,
                  data[anchor + 3] == 0x00,
                  (data[anchor + 4] == 0x01 || data[anchor + 4] == 0x02),
                  data[anchor + 5] == 0x00
            else {
                offset += 1
                continue
            }

            let bodyLength = Int(readLE64(data, at: offset + lengthOffset))
            let bodyStart = offset + chunkHeaderSize

            guard bodyLength >= 0, bodyStart + bodyLength <= total else {
                offset += 1
                continue
            }

            let rawID = Array(data[(data.startIndex + offset)..<(data.startIndex + offset + 4)])
            let id = reverseID(rawID)
            let oid = readLE32(data, at: offset + oidOffset)

            result.append(ChunkInfo(
                id: id,
                oid: oid,
                bodyOffset: bodyStart,
                bodyLength: bodyLength
            ))

            offset = bodyStart + bodyLength
        }
        return result
    }

    private static func reverseID(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "????" }
        let reversed = bytes.reversed()
        let chars = reversed.compactMap { b -> Character? in
            let scalar = Unicode.Scalar(b)
            let ch = Character(scalar)
            return ch.isASCII && scalar.value >= 32 ? ch : nil
        }
        if chars.count < 4 {
            return "PluginData"
        }
        return String(chars)
    }

    // MARK: - Little-Endian Readers

    private static func readLE16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private static func readLE64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[base + i]) << (i * 8)
        }
        return value
    }

    // MARK: - OID → Label Table

    /// Canonical OID → score-style-label map, derived from reverse-engineering
    /// sessions across all three sample projects. Step-4 indexing means the
    /// first 16 entries are user-visible style names and entries 16..31 are
    /// currently reserved.
    private static let knownLabels: [UInt32: String] = [
        0: "Plain Text",
        4: "Page Numbers",
        8: "Bar Numbers",
        12: "Instrument Names",
        16: "Tuplets",
        20: "Repeat Endings",
        24: "Chord Root",
        28: "Chord Ext.",
        32: "Mult. Rests",
        36: "Tablature",
        40: "Tempo Symbols",
        44: "Octave Symbols",
        48: "Note Heads",
        52: "Guitar Grid Fingerings",
        56: "Guitar Markings",
        60: "Fingerings",
        64: "reserved16",
        68: "reserved17",
        72: "reserved18",
        76: "reserved19",
        80: "reserved20",
        84: "reserved21",
        88: "reserved22",
        92: "reserved23",
        96: "reserved24",
        100: "reserved25",
        104: "reserved26",
        108: "reserved27",
        112: "reserved28",
        116: "reserved29",
        120: "reserved30",
        124: "reserved31",
    ]
}
