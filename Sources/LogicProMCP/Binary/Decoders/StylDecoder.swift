import Foundation

// MARK: - StylRecord

/// A single Score Style definition decoded from a `Styl` chunk.
///
/// Logic Pro's Score editor defines a catalog of staff/instrument "styles"
/// (e.g. " Auto", "Piano 1/3", "Drums"). Every `Styl` chunk encodes one style
/// with a human-readable label. Decoding is required for downstream features
/// that need to map score regions to their assigned style by OID.
public struct StylRecord: Sendable, Codable, Equatable {
    /// OID taken from the chunk header (LE u32 @ 0x0A).
    public let oid: UInt32
    /// ASCII label decoded from the body (e.g. "Piano 1/3", " Auto").
    public let label: String
    /// Length in bytes of the chunk body (from the 64-bit length field @ 0x1C).
    public let bodyLength: Int

    public init(oid: UInt32, label: String, bodyLength: Int) {
        self.oid = oid
        self.label = label
        self.bodyLength = bodyLength
    }
}

// MARK: - StylDecoder

/// Decoder for Logic Pro `Styl` (Score Style) chunks in a `ProjectData` blob.
///
/// Layout of the relevant portion of a `Styl` body (offsets are from the start
/// of the body, NOT the chunk header):
/// ```
/// 0x00  4B   sub-record length header (LE u32, e.g. 0x025C = 604)
/// 0x0E  10B  ASCII marker "*New Style" (fixed in every Styl chunk)
/// ????  2B   length-prefix (LE u16)
/// ????  N    UTF-8 label bytes
/// ????  1B   optional '6' glyph byte (Logic's 8va-basso marker)
/// ```
///
/// Between the `*New Style` marker and the length prefix there may be zero
/// padding; the decoder skips it. Some built-in styles (e.g. "Trumpet in B♭")
/// embed a UTF-8 musical-flat glyph inside the length-prefixed run; Logic's
/// canonical name drops that glyph, so the decoder strips trailing non-ASCII
/// characters. Other styles (e.g. "Guitar6", "Alto Sax6") carry a `'6'` byte
/// *outside* the length-prefixed run; the decoder appends it when present.
///
/// Sample labels decoded from a stock project (all 32 OIDs):
/// 0:" Auto", 4:" Piano^", 8:"Piano 1/3", 12:"Piano 1+2/3", 16:"Piano 1/3+4",
/// 20:"Piano 1+2/3+4", 24:"Organ 1/1/5", 28:"Organ 1/3/5", 32:"Organ 1+2/3/5",
/// 36:"Organ 1/3+4/5", 40:"Organ 1+2/3+4/5", 44:" Bass", 48:" Treble+8",
/// 52:"Trumpet in B", 56:"Trumpet in A6", 60:"Horn in F", 64:"Horn in E",
/// 68:"Piccolo", 72:"Baritone Sax6", 76:"Tenor Sax", 80:"Alto Sax6",
/// 84:"Soprano Sax", 88:"Viola", 92:"Violoncello", 96:"Contrabass6",
/// 100:" Treble-8", 104:" Treble", 108:"Drums", 112:"Guitar6",
/// 116:"Guitar Mix^", 120:" Lead Sheet", 124:"Guitar Mix 2^".
public enum StylDecoder {

    // MARK: Public API

    /// Decode every `Styl` chunk found in the given ProjectData blob.
    /// Records are returned in the order their chunks appear in the file.
    public static func decode(data: Data) -> [StylRecord] {
        let chunks = scanChunks(data: data)
        var records: [StylRecord] = []

        for chunk in chunks where chunk.id == idStyl {
            guard chunk.bodyLength > 0 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            guard let label = extractLabel(from: body) else { continue }
            records.append(StylRecord(
                oid: chunk.oid,
                label: label,
                bodyLength: chunk.bodyLength
            ))
        }

        return records
    }

    // MARK: - Constants

    /// Chunk IDs are stored byte-reversed on disk. "Styl" is the human-readable ID.
    private static let idStyl = "Styl"
    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16
    private static let oidOffset = 0x0A
    private static let lengthOffset = 0x1C

    /// ASCII marker embedded in every Styl body immediately before the label.
    private static let newStyleMarker: Data = Data("*New Style".utf8)

    // MARK: - Chunk Scanner (copied from ProjectDataParser to keep this decoder self-contained)

    /// Describes a located chunk in the ProjectData blob.
    private struct ChunkInfo {
        let id: String
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    /// Scan the entire data blob for valid chunks using the anchor-signature method.
    ///
    /// Anchor at offset 0x16 within a 36-byte header:
    ///   02 00 00 00 [01|02] 00
    /// The chunk ID is 4 bytes at the very start of the header (0x16 bytes before
    /// the anchor). See `ProjectDataParser.scanChunks` for the canonical
    /// implementation — this copy exists to keep `StylDecoder` free of
    /// cross-file dependencies as required by the unit plan.
    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let total = data.count
        var offset = 4 // skip global magic 23 47 C0 AB

        while offset + chunkHeaderSize <= total {
            guard data[offset + anchorOffset] == 0x02,
                  data[offset + anchorOffset + 1] == 0x00,
                  data[offset + anchorOffset + 2] == 0x00,
                  data[offset + anchorOffset + 3] == 0x00,
                  (data[offset + anchorOffset + 4] == 0x01 || data[offset + anchorOffset + 4] == 0x02),
                  data[offset + anchorOffset + 5] == 0x00
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

            let rawID = Array(data[offset..<(offset + 4)])
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

    // MARK: - Styl Label Extraction

    /// Extract the Score Style label from a `Styl` chunk body.
    ///
    /// Algorithm:
    ///   1. Find the literal "*New Style" marker (always present).
    ///   2. Walk past the marker and skip trailing zero padding.
    ///   3. At the next position read a u16 LE length prefix followed by
    ///      `length` UTF-8 label bytes (`length` in `[1, 32]`).
    ///   4. UTF-8 decode and strip trailing non-ASCII glyph bytes (Logic
    ///      stores the musical flat `♭` as `e2 99 ad` inside the label
    ///      payload, but the canonical label does not include it).
    ///   5. If the byte immediately past the length-prefixed run is `0x36`
    ///      (`'6'`, Logic's "treble-clef 8va basso" badge), append a literal
    ///      `'6'` to the label. This preserves labels like "Guitar6" and
    ///      "Alto Sax6" that carry their glyph outside the length prefix.
    ///   6. Fall back to a forward byte-scan within the first 256 bytes past
    ///      the marker if step 3 fails at the immediate post-padding offset.
    private static func extractLabel(from body: Data) -> String? {
        guard let markerEnd = findMarkerEnd(in: body) else { return nil }

        // Skip zero padding immediately after the marker.
        var cursor = markerEnd
        while cursor < body.count && body[body.startIndex + cursor] == 0x00 {
            cursor += 1
        }

        // First attempt: read length-prefixed label at the first non-zero byte.
        if let label = decodeLabel(in: body, at: cursor) {
            return label
        }

        // Fallback: scan forward for any valid u16-length run within the first
        // 256 bytes past the marker. Logic's label is always close by.
        let scanLimit = min(body.count, markerEnd + 256)
        var probe = markerEnd
        while probe + 2 <= scanLimit {
            if let label = decodeLabel(in: body, at: probe) {
                return label
            }
            probe += 1
        }
        return nil
    }

    /// Decode a length-prefixed label at `offset`, then optionally extend it
    /// with a `'6'` glyph byte stored immediately past the length-prefixed
    /// run. Returns `nil` if no plausible label is present.
    private static func decodeLabel(in body: Data, at offset: Int) -> String? {
        guard var label = readLengthPrefixedASCII(in: body, at: offset) else {
            return nil
        }
        let length = Int(readLE16(body, at: offset))
        let afterOffset = offset + 2 + length
        // Some styles (e.g. "Guitar6", "Alto Sax6") carry a '6' glyph byte
        // outside the length-prefixed run. When present, append it so the
        // decoded label matches Logic's displayed name.
        if afterOffset < body.count,
           body[body.startIndex + afterOffset] == 0x36 {
            label.append("6")
        }
        return label
    }

    /// Locate the end (one past the last byte) of the "*New Style" marker.
    /// Returns an offset relative to the body's start, or `nil` if the marker
    /// is absent.
    private static func findMarkerEnd(in body: Data) -> Int? {
        guard let range = body.range(of: newStyleMarker) else { return nil }
        return range.upperBound - body.startIndex
    }

    /// Read a u16 LE length prefix at `offset`, then `length` bytes of
    /// UTF-8-encoded label. Accepts lengths in `[1, 32]`. Returns a trimmed
    /// non-empty string on success, otherwise `nil`.
    ///
    /// Logic encodes most labels as pure ASCII, but a handful contain UTF-8
    /// sequences for musical glyphs — e.g. the flat sign `♭` in
    /// "Trumpet in B♭" is encoded as the 3 bytes `e2 99 ad`. The validator
    /// accepts printable ASCII (`0x20..0x7E`) and any high-bit byte
    /// (continuation/lead byte of a multi-byte UTF-8 sequence), and rejects
    /// control characters (`< 0x20` or `0x7F`). A UTF-8 round-trip guards
    /// against malformed sequences.
    ///
    /// After UTF-8 decoding the function strips any trailing non-ASCII
    /// characters (so `"Trumpet in B♭"` becomes `"Trumpet in B"`). Logic's
    /// canonical labels are pure ASCII — the glyph bytes are rendering
    /// metadata, not part of the name.
    private static func readLengthPrefixedASCII(in body: Data, at offset: Int) -> String? {
        guard offset + 2 <= body.count else { return nil }
        let length = Int(readLE16(body, at: offset))
        guard length >= 1 && length <= 32 else { return nil }
        let start = body.startIndex + offset + 2
        let end = start + length
        guard end <= body.endIndex else { return nil }
        let slice = body[start..<end]
        // Reject runs containing ASCII control characters or 0x7F.
        guard slice.allSatisfy({ ($0 >= 0x20 && $0 < 0x7F) || $0 >= 0x80 }) else {
            return nil
        }
        guard let raw = String(data: Data(slice), encoding: .utf8) else { return nil }
        let asciiOnly = stripTrailingNonASCII(raw)
        let trimmed = trimLabel(asciiOnly)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drop trailing non-ASCII characters from a string so glyph bytes
    /// encoded inside the length-prefixed label payload (e.g. `♭`) don't
    /// leak into the decoded name.
    private static func stripTrailingNonASCII(_ s: String) -> String {
        var chars = Array(s)
        while let last = chars.last,
              let scalar = last.unicodeScalars.first,
              scalar.value > 0x7E {
            chars.removeLast()
        }
        return String(chars)
    }

    /// Trim ASCII control characters from both ends of a decoded label, but
    /// preserve leading/trailing spaces (Logic uses a leading space on some
    /// built-in styles, e.g. " Auto", " Treble").
    private static func trimLabel(_ s: String) -> String {
        var chars = Array(s)
        while let first = chars.first, isControlOrNul(first) {
            chars.removeFirst()
        }
        while let last = chars.last, isControlOrNul(last) {
            chars.removeLast()
        }
        return String(chars)
    }

    private static func isControlOrNul(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return true }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    // MARK: - Low-level Readers (copied from ProjectDataParser)

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

    private static func reverseID(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "????" }
        let chars = bytes.reversed().compactMap { b -> Character? in
            let scalar = Unicode.Scalar(b)
            let ch = Character(scalar)
            return ch.isASCII && scalar.value >= 32 ? ch : nil
        }
        if chars.count < 4 { return "PluginData" }
        return String(chars)
    }
}
