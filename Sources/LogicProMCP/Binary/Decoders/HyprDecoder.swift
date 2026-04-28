import Foundation

// MARK: - HyprDecoder
//
// Decodes `Hypr` chunks from Logic Pro's ProjectData binary.
//
// Logic embeds a small fixed set of `Hypr` chunks in every project; they act as
// lookup tables / catalogs that UI components and the automation engine consult
// at runtime. Three are consistently present in every observed project:
//
//   oid = 0  — Automation mode toggle (contains "Volume", "Automatic")
//   oid = 4  — MIDI controller catalog (Volume, Pan, Modulation, Pitch Bend, …)
//   oid = 8  — GM Drum Kit note-name map (KICK 1, SD 1, Closed HH, …)
//
// Body structure: length-prefixed ASCII entries interspersed with binary
// metadata. Rather than chase the exact binary framing, we extract contiguous
// printable-ASCII runs (length 3..40, at least one letter). That approach
// reliably recovers all user-meaningful entries across the three catalogs.

/// Classification of a Hypr catalog based on its object identifier.
enum HyprCategory: String, Sendable, Codable {
    case automationMode
    case midiControls
    case gmDrumKit
    case unknown
}

/// One decoded Hypr catalog (chunk), with its extracted string entries.
struct HyprRecord: Sendable, Codable {
    /// Object identifier from the Hypr chunk header.
    let oid: UInt32
    /// Length of the chunk body in bytes.
    let bodyLength: Int
    /// Inferred catalog role (automation mode, MIDI controls, GM drum kit).
    let category: HyprCategory
    /// Unique ASCII entries in the order they appear in the body.
    let entries: [String]
}

/// Decoder for Logic Pro `Hypr` automation/controller/note-name catalogs.
///
/// The decoder is intentionally self-contained: it walks the chunk stream with
/// its own lightweight scanner (copied from `ProjectDataParser`) rather than
/// depending on that parser's private internals.
enum HyprDecoder {

    // MARK: - Constants

    private static let anchorPrefix: [UInt8] = [0x02, 0x00, 0x00, 0x00]
    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16          // within header
    private static let oidOffset = 0x0A             // within header
    private static let lengthOffset = 0x1C          // within header
    private static let idHypr = "Hypr"

    // Printable-ASCII run filter thresholds.
    private static let minEntryLength = 3
    private static let maxEntryLength = 40

    // MARK: - Public API

    /// Decode all `Hypr` chunks from a ProjectData blob.
    ///
    /// - Parameter data: The raw ProjectData bytes (as read from the .logicx bundle).
    /// - Returns: One `HyprRecord` per Hypr chunk, in chunk-scan order.
    static func decode(data: Data) -> [HyprRecord] {
        let chunks = scanChunks(data: data)
        var records: [HyprRecord] = []
        for chunk in chunks where chunk.id == idHypr {
            guard chunk.bodyLength > 0,
                  chunk.bodyOffset + chunk.bodyLength <= data.count
            else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            let entries = extractEntries(body: body)
            let category = classify(oid: chunk.oid)
            records.append(HyprRecord(
                oid: chunk.oid,
                bodyLength: chunk.bodyLength,
                category: category,
                entries: entries
            ))
        }
        return records
    }

    // MARK: - Classification

    private static func classify(oid: UInt32) -> HyprCategory {
        switch oid {
        case 0: return .automationMode
        case 4: return .midiControls
        case 8: return .gmDrumKit
        default: return .unknown
        }
    }

    // MARK: - Entry Extraction

    /// Scan a chunk body for contiguous printable-ASCII runs that look like
    /// user-facing strings: length 3..40, containing at least one letter.
    /// Deduplicates while preserving first-seen order.
    private static func extractEntries(body: Data) -> [String] {
        var entries: [String] = []
        var seen: Set<String> = []
        var current: [UInt8] = []
        current.reserveCapacity(maxEntryLength)

        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= minEntryLength,
                  current.count <= maxEntryLength
            else { return }
            guard current.contains(where: isAsciiLetter) else { return }
            let string = String(decoding: current, as: UTF8.self)
            if seen.insert(string).inserted {
                entries.append(string)
            }
        }

        for byte in body {
            if isPrintableAscii(byte) {
                if current.count < maxEntryLength {
                    current.append(byte)
                } else {
                    // Run exceeds cap — discard overflow; flush at next boundary.
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                flush()
            }
        }
        flush()
        return entries
    }

    @inline(__always)
    private static func isPrintableAscii(_ byte: UInt8) -> Bool {
        // Printable ASCII excluding control chars; 0x20 (space) through 0x7E (~).
        return byte >= 0x20 && byte <= 0x7E
    }

    @inline(__always)
    private static func isAsciiLetter(_ byte: UInt8) -> Bool {
        return (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    // MARK: - Chunk Scanning (copied from ProjectDataParser)

    private struct ChunkInfo {
        let id: String      // reversed 4-char ID
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    /// Scan the data blob for chunks using the same anchor-signature method as
    /// `ProjectDataParser.scanChunks`. Duplicated here to keep this decoder
    /// independent of the main parser's private surface.
    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let bytes = data
        let total = bytes.count
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
            // Look for anchor pattern: 02 00 00 00 [01 or 02] 00
            guard bytes[offset + anchorOffset] == 0x02,
                  bytes[offset + anchorOffset + 1] == 0x00,
                  bytes[offset + anchorOffset + 2] == 0x00,
                  bytes[offset + anchorOffset + 3] == 0x00,
                  (bytes[offset + anchorOffset + 4] == 0x01 || bytes[offset + anchorOffset + 4] == 0x02),
                  bytes[offset + anchorOffset + 5] == 0x00
            else {
                offset += 1
                continue
            }

            let bodyLength = Int(readLE64(data, at: offset + lengthOffset))
            let bodyStart = offset + chunkHeaderSize

            guard bodyLength >= 0,
                  bodyStart + bodyLength <= total
            else {
                offset += 1
                continue
            }

            let rawID = Array(bytes[offset..<(offset + 4)])
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

    // MARK: - Low-level Readers (copied from ProjectDataParser)

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

    /// Reverse the 4 ID bytes to get the human-readable chunk ID.
    /// On-disk bytes `[0x72, 0x70, 0x79, 0x48]` -> `"Hypr"`.
    /// If all 4 bytes are non-printable/null, returns `"PluginData"`.
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
}
