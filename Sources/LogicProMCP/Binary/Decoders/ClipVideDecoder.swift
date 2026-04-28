import Foundation

// MARK: - ClipVideDecoder

/// Partial decoder for Logic Pro's `Clip` and `Vide` chunks.
///
/// These are small, mostly-placeholder metadata chunks that appear in every
/// ProjectData file with consistent layouts:
///
/// - `Clip` — exactly 3 per project (OIDs 0, 4, 8), body length 85 bytes.
///   Mostly zeros, but with a few stable header fields. The body starts with
///   a header-length indicator (`u32@0 = 0xA0 = 160`), a count/offset field
///   (`u32@0x10`), a sentinel (`u32@0x14 = 0xFFFFFFFF`), and an IEEE 754
///   float at offset `0x20` which is always `1.0f` in observed samples
///   (interpreted as a gain/amplitude scalar).
///
/// - `Vide` — exactly 1 per project (OID 24), body length 130 bytes.
///   Begins with `u32@0 = 0x76 = 118` and is entirely zero after the header.
///
/// The scanner implementation is an intentional copy of the one in
/// `ProjectDataParser` so this decoder can evolve independently without
/// touching the main parser.
public enum ClipVideDecoder {

    // MARK: - Record Types

    /// A decoded `Clip` chunk header.
    public struct ClipRecord: Sendable, Codable, Equatable {
        public let oid: UInt32
        public let bodyLength: Int
        /// `u32@0` — header length indicator (observed: `0xA0` = 160).
        public let headerLen: UInt32
        /// `u32@0x10` — count / offset field (observed: `0x28`, `0x2C`, `0x30`).
        public let countField: UInt32
        /// `float@0x20` — amplitude / gain scalar (observed: `1.0`).
        public let gainFloat: Float

        public init(
            oid: UInt32,
            bodyLength: Int,
            headerLen: UInt32,
            countField: UInt32,
            gainFloat: Float
        ) {
            self.oid = oid
            self.bodyLength = bodyLength
            self.headerLen = headerLen
            self.countField = countField
            self.gainFloat = gainFloat
        }
    }

    /// A decoded `Vide` chunk header.
    public struct VideRecord: Sendable, Codable, Equatable {
        public let oid: UInt32
        public let bodyLength: Int
        /// `u32@0` — header length indicator (observed: `0x76` = 118).
        public let headerLen: UInt32
        /// `true` when bytes `[4..bodyLength)` are all zero (placeholder body).
        public let isAllZeroAfterHeader: Bool

        public init(
            oid: UInt32,
            bodyLength: Int,
            headerLen: UInt32,
            isAllZeroAfterHeader: Bool
        ) {
            self.oid = oid
            self.bodyLength = bodyLength
            self.headerLen = headerLen
            self.isAllZeroAfterHeader = isAllZeroAfterHeader
        }
    }

    // MARK: - Public API

    /// Decode every `Clip` and `Vide` chunk in a raw ProjectData blob.
    ///
    /// - Parameter data: Raw ProjectData bytes (magic-prefixed).
    /// - Returns: Tuple `(clips, vides)` of decoded records, in scan order.
    public static func decode(data: Data) -> (clips: [ClipRecord], vides: [VideRecord]) {
        let chunks = scanChunks(data: data)
        var clips: [ClipRecord] = []
        var vides: [VideRecord] = []

        for chunk in chunks {
            switch chunk.id {
            case "Clip":
                if let record = decodeClip(chunk: chunk, data: data) {
                    clips.append(record)
                }
            case "Vide":
                if let record = decodeVide(chunk: chunk, data: data) {
                    vides.append(record)
                }
            default:
                continue
            }
        }

        return (clips, vides)
    }

    // MARK: - Clip / Vide Body Decoding

    private static func decodeClip(chunk: ChunkInfo, data: Data) -> ClipRecord? {
        // Need at least 0x24 bytes to read the float at 0x20.
        guard chunk.bodyLength >= 0x24 else { return nil }
        let body = data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)]

        let headerLen = readLE32(body, at: 0)
        let countField = readLE32(body, at: 0x10)
        let gainFloat = readFloat32(body, at: 0x20)

        return ClipRecord(
            oid: chunk.oid,
            bodyLength: chunk.bodyLength,
            headerLen: headerLen,
            countField: countField,
            gainFloat: gainFloat
        )
    }

    private static func decodeVide(chunk: ChunkInfo, data: Data) -> VideRecord? {
        guard chunk.bodyLength >= 4 else { return nil }
        let body = data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)]

        let headerLen = readLE32(body, at: 0)
        let allZero = body.suffix(from: body.startIndex + 4).allSatisfy { $0 == 0 }

        return VideRecord(
            oid: chunk.oid,
            bodyLength: chunk.bodyLength,
            headerLen: headerLen,
            isAllZeroAfterHeader: allZero
        )
    }

    // MARK: - Chunk Scanning (copied from ProjectDataParser)

    private static let anchorOffset = 0x16
    private static let chunkHeaderSize = 36
    private static let oidOffset = 0x0A
    private static let lengthOffset = 0x1C

    /// Describes a located chunk.
    private struct ChunkInfo {
        let id: String      // reversed 4-char ID
        let oid: UInt32
        let bodyOffset: Int // offset within data where body begins
        let bodyLength: Int
    }

    /// Scan the entire data blob for valid chunks using the anchor-signature method.
    ///
    /// Anchor at offset 0x16 within a 36-byte header:
    ///   `02 00 00 00 [01|02] 00`
    ///
    /// The chunk ID is 4 bytes at the very start of the header (`0x16`
    /// bytes before the anchor), stored in reversed byte order on disk.
    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let bytes = data
        let total = bytes.count
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
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

    // MARK: - Low-level Readers

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

    /// Read an IEEE 754 little-endian `Float` at `offset` within `data`.
    private static func readFloat32(_ data: Data, at offset: Int) -> Float {
        let raw = readLE32(data, at: offset)
        return Float(bitPattern: raw)
    }

    /// Reverse 4 on-disk ID bytes to their human-readable form.
    /// e.g., `[0x70, 0x69, 0x6C, 0x43]` → `"Clip"`.
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
