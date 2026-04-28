import Foundation

// MARK: - Score Set Records

/// A Score Set record decoded from a `ScSt` chunk.
///
/// Logic Pro's Score Editor groups instruments into "Score Sets" for printing
/// and on-screen layout. Each project typically carries exactly one `ScSt`
/// chunk (oid=12) whose body encodes the default score set along with its
/// instrument slot names (e.g. "Guitar", "Bass 4", "Kick", "Snare", ...).
struct ScoreSet: Sendable, Codable {
    /// Object identifier taken from the `ScSt` chunk header.
    let oid: UInt32
    /// Primary title of the score set (first plausible name in the body).
    /// Observed value across the three bundled fixtures is `"Guitar"`.
    let rootName: String
    /// All remaining plausible instrument slot names, deduped in first-seen order.
    /// Examples: `"Guitar D"`, `"Bass 4"`, `"Kick"`, `"Snare"`, `"HiHat"`.
    let instrumentNames: [String]
}

/// A Score Set root record decoded from an `InSt` chunk.
///
/// `InSt` chunks carry the "Score Set" label that anchors the score-set tree
/// (there is exactly one per project, oid=0). The label is stored twice —
/// once as a length-prefixed ASCII string at body offset `0x0E` and once
/// again at `0x36` for UI mirroring. We prefer the 0x0E copy.
struct InstRecord: Sendable, Codable {
    /// Object identifier from the `InSt` chunk header (always `0`).
    let oid: UInt32
    /// Decoded label, typically the literal string `"Score Set"`.
    let label: String
}

// MARK: - Decoder

/// Pure decoder for `ScSt` (Score Set) and `InSt` (Score Set root) chunks.
///
/// Usage:
/// ```swift
/// let data = try Data(contentsOf: projectDataURL)
/// let (sets, roots) = ScoreSetDecoder.decode(data: data)
/// ```
///
/// The decoder does not mutate or depend on `ProjectDataParser` state — it
/// ships its own chunk scanner (copied from the main parser) so that it can
/// be invoked stand-alone from tests and MCP tools.
enum ScoreSetDecoder {

    // MARK: Public API

    /// Decode all `ScSt` and `InSt` chunks found in a raw `ProjectData` blob.
    ///
    /// - Parameter data: Full contents of a Logic Pro `ProjectData` file.
    /// - Returns: Tuple of the decoded score sets and root records. Both lists
    ///   preserve on-disk order. Empty arrays are returned when the magic is
    ///   invalid or no matching chunks are present.
    static func decode(data: Data) -> (sets: [ScoreSet], roots: [InstRecord]) {
        guard validateMagic(data) else { return ([], []) }

        let chunks = scanChunks(data: data)

        var sets: [ScoreSet] = []
        var roots: [InstRecord] = []

        for chunk in chunks {
            switch chunk.id {
            case "ScSt":
                if let set = decodeScoreSet(chunk: chunk, data: data) {
                    sets.append(set)
                }
            case "InSt":
                if let root = decodeInstRoot(chunk: chunk, data: data) {
                    roots.append(root)
                }
            default:
                continue
            }
        }

        return (sets, roots)
    }

    // MARK: InSt Decoding

    /// Decode a single `InSt` chunk's root label.
    ///
    /// Body layout (64 bytes):
    /// ```
    /// 0x00 u16  body-length indicator (0x234 = 564)
    /// 0x08 u16  length of string 1 (0x10 = 16)
    /// 0x0E ASCII null-terminated "Score Set" (preferred)
    /// 0x30 u32  secondary count (0x64 = 100)
    /// 0x34 u16  length of string 2 (0x09 = 9)
    /// 0x36 ASCII null-terminated "Score Set" (mirror)
    /// ```
    private static func decodeInstRoot(chunk: ChunkInfo, data: Data) -> InstRecord? {
        guard chunk.bodyLength > 0 else { return nil }
        let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

        // Prefer the string at 0x0E; fall back to 0x36 when absent.
        if let primary = readNullTerminatedASCII(body: body, at: 0x0E, maxLen: 40),
           !primary.isEmpty {
            return InstRecord(oid: chunk.oid, label: primary)
        }
        if let secondary = readNullTerminatedASCII(body: body, at: 0x36, maxLen: 40),
           !secondary.isEmpty {
            return InstRecord(oid: chunk.oid, label: secondary)
        }
        return nil
    }

    /// Read up to `maxLen` printable-ASCII characters starting at `offset`,
    /// terminating at the first NUL or non-printable byte.
    private static func readNullTerminatedASCII(
        body: Data,
        at offset: Int,
        maxLen: Int
    ) -> String? {
        guard offset >= 0, offset < body.count else { return nil }
        let start = body.startIndex + offset
        let end = min(body.endIndex, start + maxLen)
        var chars: [Character] = []
        var i = start
        while i < end {
            let b = body[i]
            if b == 0 { break }
            guard b >= 0x20 && b < 0x7F else { break }
            chars.append(Character(Unicode.Scalar(b)))
            i = body.index(after: i)
        }
        let s = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: ScSt Decoding

    /// Decode a single `ScSt` chunk into a `ScoreSet`.
    ///
    /// Strategy: scan the body for contiguous printable-ASCII runs of length
    /// 4..32 containing at least one letter. The first plausible title-case
    /// run becomes `rootName` (used for UI display). `instrumentNames` holds
    /// every unique run — including the one chosen as `rootName`, since the
    /// first row of a Logic Score Set doubles as both the group title and
    /// its first instrument slot.
    ///
    /// Runs starting with the Logic placeholder marker `"*"` (e.g.
    /// `"* New Group"`) are excluded.
    private static func decodeScoreSet(chunk: ChunkInfo, data: Data) -> ScoreSet? {
        guard chunk.bodyLength > 0 else { return nil }
        let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

        let runs = extractPrintableRuns(body: body, minLen: 4, maxLen: 32)
        guard !runs.isEmpty else { return nil }

        // Deduplicate while preserving on-disk order.
        var seen = Set<String>()
        var ordered: [String] = []
        for run in runs where seen.insert(run).inserted {
            ordered.append(run)
        }

        // rootName = first candidate that looks like a score-set title.
        let rootIndex = ordered.firstIndex(where: isLikelyScoreSetTitle) ?? 0
        let rootName = ordered[rootIndex]

        return ScoreSet(oid: chunk.oid, rootName: rootName, instrumentNames: ordered)
    }

    /// Classify a run as a plausible score-set title.
    ///
    /// Accepts anything starting with a known Logic score-set keyword ("Score",
    /// "Guitar", "Bass", "Piano", "Drums") or a capitalized ASCII letter — the
    /// idea being that the first row of a Logic Score Set is always a
    /// human-readable group label in title case.
    private static func isLikelyScoreSetTitle(_ s: String) -> Bool {
        let prefixes = ["Score", "Guitar", "Bass", "Piano", "Drums"]
        for p in prefixes where s.hasPrefix(p) { return true }
        if let first = s.first, first.isUppercase, first.isLetter { return true }
        return false
    }

    /// Scan `body` for contiguous printable-ASCII runs whose length falls
    /// within `[minLen, maxLen]` and which contain at least one letter.
    ///
    /// Obvious placeholder markers ("* New Group") are filtered here so the
    /// caller sees only real named entries.
    private static func extractPrintableRuns(
        body: Data,
        minLen: Int,
        maxLen: Int
    ) -> [String] {
        var runs: [String] = []
        var current: [Character] = []

        func flush() {
            let str = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
            current.removeAll(keepingCapacity: true)
            guard str.count >= minLen, str.count <= maxLen else { return }
            guard str.contains(where: { $0.isLetter }) else { return }
            // Skip Logic's empty-slot placeholders.
            if str.hasPrefix("*") { return }
            runs.append(str)
        }

        for byte in body {
            if byte >= 0x20 && byte < 0x7F {
                current.append(Character(Unicode.Scalar(byte)))
            } else {
                flush()
            }
        }
        flush()
        return runs
    }

    // MARK: Chunk Scanner (copied from ProjectDataParser for isolation)

    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16
    private static let oidOffset = 0x0A
    private static let lengthOffset = 0x1C

    /// Describes a located chunk in the `ProjectData` stream.
    fileprivate struct ChunkInfo {
        let id: String
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    /// Validate the 4-byte magic at offset 0.
    private static func validateMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[data.startIndex] == 0x23
            && data[data.startIndex + 1] == 0x47
            && data[data.startIndex + 2] == 0xC0
            && data[data.startIndex + 3] == 0xAB
    }

    /// Scan the entire blob for valid chunks using the anchor-signature method.
    ///
    /// Each 36-byte header carries an anchor at `0x16`:
    /// ```
    /// 02 00 00 00 [01|02] 00
    /// ```
    /// The chunk ID is 4 bytes at the start of the header (stored reversed on
    /// disk); OID is a LE u32 at `0x0A`; body length is a LE u64 at `0x1C`.
    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let total = data.count
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
            guard data[data.startIndex + offset + anchorOffset] == 0x02,
                  data[data.startIndex + offset + anchorOffset + 1] == 0x00,
                  data[data.startIndex + offset + anchorOffset + 2] == 0x00,
                  data[data.startIndex + offset + anchorOffset + 3] == 0x00,
                  (data[data.startIndex + offset + anchorOffset + 4] == 0x01
                   || data[data.startIndex + offset + anchorOffset + 4] == 0x02),
                  data[data.startIndex + offset + anchorOffset + 5] == 0x00
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

            let base = data.startIndex + offset
            let rawID = [UInt8](data[base..<(base + 4)])
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

    // MARK: Low-level Readers

    /// Read a 4-byte little-endian `UInt32` at `offset` within `data`.
    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Read an 8-byte little-endian `UInt64` at `offset` within `data`.
    private static func readLE64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[base + i]) << (i * 8)
        }
        return value
    }

    /// Reverse the 4 on-disk ID bytes into a human-readable chunk identifier.
    /// Example: `[0x74, 0x53, 0x63, 0x53]` → `"ScSt"`.
    private static func reverseID(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "????" }
        let chars = bytes.reversed().compactMap { b -> Character? in
            let scalar = Unicode.Scalar(b)
            let ch = Character(scalar)
            return ch.isASCII ? ch : nil
        }
        guard chars.count == 4 else { return "????" }
        return String(chars)
    }
}
