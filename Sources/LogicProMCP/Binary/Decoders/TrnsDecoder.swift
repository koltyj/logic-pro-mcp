import Foundation

// MARK: - TrnsGlobals

/// Partial decode of a `Trns` (transport/transition globals) chunk.
///
/// Every Logic Pro ProjectData binary observed so far has exactly one `Trns`
/// chunk with `oid == 0` and a body length of 492 bytes. The chunk appears to
/// store global timeline / transport configuration separately from the
/// arrangement section events (which live in `EvSq` / `TxSq`). The full schema
/// is only partially understood; this struct captures the fields that have
/// been confirmed across all three reference projects.
///
/// Confirmed observations (all three reference projects, alternative `000`):
/// - `bodyLength == 492`
/// - `u32 LE @ 0x00` is a small multiple of 16 (e.g. 0x410 / 0x420 = 1040 / 1056)
///   and is repeated at `u32 LE @ 0x78`, suggesting a length/size field that
///   bounds a sub-block.
/// - `u32 LE @ 0x50 == 3840`, matching Logic's canonical ticks-per-bar
///   constant for 4/4 at the project's resolution. This is a strong indicator
///   that the `Trns` chunk caches the global timeline grid.
/// - At least one 32-bit word elsewhere in the body whose low 16 bits have the
///   high bit set (i.e. would be negative if interpreted as signed Int16),
///   which is consistent with the "pre-roll-like" signed values noted in the
///   reverse-engineering log.
struct TrnsGlobals: Sendable, Codable {
    /// OID from the `Trns` chunk header (observed to always be 0).
    let oid: UInt32
    /// Body length in bytes (observed to always be 492).
    let bodyLength: Int
    /// `u32 LE @ 0x00`. Small length-ish constant (e.g. 0x410 or 0x420).
    let header1: UInt32
    /// `u32 LE @ 0x50`. Observed to equal 3840 (Logic ticks-per-bar in 4/4).
    let gridValue: UInt32
    /// True when the literal 3840 (ticks per bar) appears anywhere in the body
    /// as an aligned little-endian `u32`.
    let containsTicksPerBar: Bool
    /// True when the literal 4096 appears anywhere in the body as an aligned
    /// little-endian `u32`.
    let containsDivisionGrid: Bool
    /// Full `u32` values (deduplicated, in first-occurrence order) whose low
    /// 16 bits would be negative if treated as `Int16` (i.e. `low16 >= 0x8000`
    /// and `low16 != 0xFFFF` to skip the trivially-generic `-1`).
    let preRollU32s: [UInt32]
}

// MARK: - TrnsDecoder

/// Decode the `Trns` transport/transition globals chunk from a raw
/// Logic Pro ProjectData binary.
///
/// The decoder is self-contained — it runs its own chunk scan so the rest of
/// the pipeline (`ProjectDataParser`) does not have to know about this type.
enum TrnsDecoder {

    // MARK: - Constants

    private static let magicBytes: [UInt8] = [0x23, 0x47, 0xC0, 0xAB]
    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16    // within chunk header
    private static let oidOffset = 0x0A       // within chunk header
    private static let lengthOffset = 0x1C    // within chunk header
    private static let idTrns = "Trns"
    private static let ticksPerBar: UInt32 = 3840
    private static let divisionGrid: UInt32 = 4096

    // MARK: - Public API

    /// Decode all `Trns` chunks found in the given ProjectData byte blob.
    ///
    /// - Parameter data: Raw `ProjectData` file contents (magic-checked).
    /// - Returns: One `TrnsGlobals` per decoded chunk. Empty when the magic
    ///   does not match or no `Trns` chunks are present.
    static func decode(data: Data) -> [TrnsGlobals] {
        guard validateMagic(data) else { return [] }

        var result: [TrnsGlobals] = []
        for chunk in scanChunks(data: data) where chunk.id == idTrns {
            let bodyEnd = chunk.bodyOffset + chunk.bodyLength
            guard bodyEnd <= data.count, chunk.bodyLength >= 0 else { continue }
            let body = Data(data[chunk.bodyOffset..<bodyEnd])
            result.append(decodeBody(oid: chunk.oid, body: body))
        }
        return result
    }

    // MARK: - Body decoding

    private static func decodeBody(oid: UInt32, body: Data) -> TrnsGlobals {
        let bodyLength = body.count
        let header1 = bodyLength >= 4 ? readLE32(body, at: 0) : 0
        let gridValue = bodyLength >= 0x54 ? readLE32(body, at: 0x50) : 0

        var containsTicksPerBar = false
        var containsDivisionGrid = false
        var preRolls: [UInt32] = []
        var seen: Set<UInt32> = []

        var offset = 0
        while offset + 4 <= bodyLength {
            let value = readLE32(body, at: offset)
            if value == ticksPerBar { containsTicksPerBar = true }
            if value == divisionGrid { containsDivisionGrid = true }
            let low16 = UInt16(value & 0xFFFF)
            if low16 >= 0x8000 && low16 != 0xFFFF {
                if seen.insert(value).inserted {
                    preRolls.append(value)
                }
            }
            offset += 4
        }

        return TrnsGlobals(
            oid: oid,
            bodyLength: bodyLength,
            header1: header1,
            gridValue: gridValue,
            containsTicksPerBar: containsTicksPerBar,
            containsDivisionGrid: containsDivisionGrid,
            preRollU32s: preRolls
        )
    }

    // MARK: - Chunk scanning (self-contained copy)

    private struct ChunkInfo {
        let id: String
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    private static func validateMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[data.startIndex] == magicBytes[0]
            && data[data.startIndex + 1] == magicBytes[1]
            && data[data.startIndex + 2] == magicBytes[2]
            && data[data.startIndex + 3] == magicBytes[3]
    }

    /// Scan the entire data blob for chunk headers using the same anchor
    /// signature as `ProjectDataParser.scanChunks`.
    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let total = data.count
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
            let aBase = offset + anchorOffset
            guard data[data.startIndex + aBase] == 0x02,
                  data[data.startIndex + aBase + 1] == 0x00,
                  data[data.startIndex + aBase + 2] == 0x00,
                  data[data.startIndex + aBase + 3] == 0x00,
                  (data[data.startIndex + aBase + 4] == 0x01 || data[data.startIndex + aBase + 4] == 0x02),
                  data[data.startIndex + aBase + 5] == 0x00
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

    // MARK: - Low-level readers (self-contained copies)

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
