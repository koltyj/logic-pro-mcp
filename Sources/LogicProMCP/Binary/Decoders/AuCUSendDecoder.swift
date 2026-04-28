import Foundation

// MARK: - AuCUSendDecoder

/// Decodes 76-byte AuCU send records embedded inside `AuCU` chunk bodies.
///
/// See `reference/LOGIC_BINARY_SPEC.md` §5 for the authoritative byte layout.
/// Each 76-byte sub-record within an `AuCU` body encodes a single mixer send
/// slot:
///
/// - `u16@0x10` / `u16@0x12` are stable field counters.
/// - `u16@0x18`  encodes send-on/off state:
///     - `0x0000` → send enabled
///     - `0x0100` → send disabled
///     - other values → unknown (reported as `nil`)
/// - `u32@0x18` (the same region treated as u32; `u16@0x18` is its low half)
///   is the raw send level using the standard Logic volume encoding:
///     - Unity (0 dB) raw = `0x5A000000` = `1_509_949_440`
///     - `dB = 40 * log10(raw / 1_509_949_440.0)`
///     - `raw == 0` represents negative infinity (clamped to -144 dB)
/// - `u32@0x24` is the explicit `send_level_db` field per the spec.
///
/// The decoder is intentionally pure: it does not import the main parser,
/// and exposes chunk scanning via a copy of the anchor-based walker from
/// `ProjectDataParser.scanChunks`.
public struct AuCUSendRecord: Sendable, Codable, Equatable {
    /// OID of the containing `AuCU` chunk this record was extracted from.
    public let containingChunkOid: UInt32

    /// Zero-based index of this sub-record within the containing chunk.
    public let indexInChunk: Int

    /// Raw `u16` at sub-record offset `0x18` (send enable flag).
    public let u16Offset18: UInt16

    /// Raw `u32` at sub-record offset `0x24` (explicit send-level field).
    public let u32Offset24: UInt32

    /// Decoded send level in decibels, derived from `u32Offset24` via the
    /// standard volume formula and clamped to `-144.0 ... +24.0`.
    public let sendLevelDB: Double

    /// Tri-state send enable guess:
    ///   - `true`  when `u16Offset18 == 0x0000`
    ///   - `false` when `u16Offset18 == 0x0100`
    ///   - `nil`   otherwise (unknown / reserved)
    public let sendEnabled: Bool?

    public init(
        containingChunkOid: UInt32,
        indexInChunk: Int,
        u16Offset18: UInt16,
        u32Offset24: UInt32,
        sendLevelDB: Double,
        sendEnabled: Bool?
    ) {
        self.containingChunkOid = containingChunkOid
        self.indexInChunk = indexInChunk
        self.u16Offset18 = u16Offset18
        self.u32Offset24 = u32Offset24
        self.sendLevelDB = sendLevelDB
        self.sendEnabled = sendEnabled
    }
}

public enum AuCUSendDecoder {

    // MARK: - Constants

    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16
    private static let oidOffset = 0x0A
    private static let lengthOffset = 0x1C
    private static let idAuCU = "AuCU"

    /// Size of a single embedded send sub-record.
    private static let subRecordSize = 76

    /// Unity gain raw value for the volume dB formula:
    /// `dB = 40 * log10(raw / unityGainRaw)`.
    private static let unityGainRaw: Double = 1_509_949_440.0

    /// Clamp range for the reported send level in dB.
    private static let minDB: Double = -144.0
    private static let maxDB: Double = 24.0

    // MARK: - Public API

    /// Decode all 76-byte AuCU send sub-records from a raw ProjectData blob.
    ///
    /// Discovery order is preserved: records are emitted chunk-by-chunk in
    /// scan order, and sub-records within a chunk are emitted at offsets
    /// `0, 76, 152, ...` up to `bodyLength - 76`.
    public static func decode(data: Data) -> [AuCUSendRecord] {
        guard validateMagic(data) else { return [] }

        var result: [AuCUSendRecord] = []
        for chunk in scanChunks(data: data) where chunk.id == idAuCU {
            guard chunk.bodyLength >= subRecordSize else { continue }
            let recordCount = chunk.bodyLength / subRecordSize

            for index in 0..<recordCount {
                let recordBase = chunk.bodyOffset + index * subRecordSize
                let u16At18 = readLE16(data, at: recordBase + 0x18)
                let u32At24 = readLE32(data, at: recordBase + 0x24)

                let sendLevelDB = rawToDB(u32At24)
                let sendEnabled: Bool?
                switch u16At18 {
                case 0x0000: sendEnabled = true
                case 0x0100: sendEnabled = false
                default:     sendEnabled = nil
                }

                result.append(AuCUSendRecord(
                    containingChunkOid: chunk.oid,
                    indexInChunk: index,
                    u16Offset18: u16At18,
                    u32Offset24: u32At24,
                    sendLevelDB: sendLevelDB,
                    sendEnabled: sendEnabled
                ))
            }
        }
        return result
    }

    // MARK: - Volume Math

    /// Convert the proprietary 32-bit volume raw value to decibels and clamp
    /// to a sane range. A raw value of zero represents negative infinity and
    /// is pinned to `minDB`.
    private static func rawToDB(_ raw: UInt32) -> Double {
        guard raw != 0 else { return minDB }
        let db = 40.0 * log10(Double(raw) / unityGainRaw)
        return min(max(db, minDB), maxDB)
    }

    // MARK: - Chunk Scanning (mirror of ProjectDataParser.scanChunks)

    private struct ChunkInfo {
        let id: String
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    private static func validateMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x23 && data[1] == 0x47 && data[2] == 0xC0 && data[3] == 0xAB
    }

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
                  (bytes[offset + anchorOffset + 4] == 0x01
                   || bytes[offset + anchorOffset + 4] == 0x02),
                  bytes[offset + anchorOffset + 5] == 0x00
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
