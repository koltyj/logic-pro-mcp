import Foundation

// MARK: - AuCn Routing Table Decoder
//
// Decodes Logic Pro's `AuCn` routing-table chunks from a ProjectData binary.
//
// Every Logic project contains exactly 13 `AuCn` chunks:
// - 12 of them are "small" (132-byte body) routing entries whose header encodes
//   a stable routing index (0..12) at body offset 0x14 as `(index << 16) | 3`.
// - One "big" `AuCn` (by convention at routing index 1, typically `oid == 36`)
//   whose body length varies by project. After the 0x80-byte header region, the
//   body is a flat table of `u32` enable flags (each observed value is 0 or 1),
//   one per channel strip.
//
// The decoder is intentionally self-contained: it re-implements the anchor
// scanner and low-level readers rather than importing `ProjectDataParser`.
// This keeps the decoder usable in isolation and matches the pattern used by
// other binary decoders in this codebase.

// MARK: - Public Models

/// A single small `AuCn` routing-table entry (132-byte body).
struct AuCnRoutingEntry: Sendable, Codable {
    /// Object identifier from the `AuCn` chunk header.
    let oid: UInt32
    /// Body length in bytes (always 132 for small routing entries).
    let bodyLength: Int
    /// Stable routing index in the range 0..12, derived from `rawHeaderU32AtOffset14 >> 16`.
    let routingIndex: Int
    /// Raw `u32` at body offset 0x14 — encodes `(routingIndex << 16) | 3`.
    let rawHeaderU32AtOffset14: UInt32
}

/// The single "big" `AuCn` per-strip enable-flag table.
///
/// After the 0x80-byte header region, the body is a dense array of `u32`
/// values. Each observed value is `0` or `1`, and there is (approximately) one
/// entry per `AuCO` channel strip in the project.
struct AuCnEnableTable: Sendable, Codable {
    /// Object identifier from the `AuCn` chunk header.
    let oid: UInt32
    /// Body length in bytes (project-dependent; e.g. 1384 / 1412 / 1420).
    let bodyLength: Int
    /// Number of `u32` entries parsed from the flag table.
    let flagCount: Int
    /// Flag values parsed from body offset 0x80 onward. Each value is 0 or 1.
    let flags: [UInt32]
}

// MARK: - Decoder

enum AuCnDecoder {

    // MARK: Constants (mirror ProjectDataParser)

    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16
    private static let oidOffset = 0x0A
    private static let lengthOffset = 0x1C
    private static let idAuCn = "AuCn"

    /// Bodies of 132 bytes are small routing entries.
    private static let smallBodyLength = 132
    /// Bodies larger than this threshold are treated as the big enable table.
    private static let bigBodyMinLength = 200
    /// Start offset of the enable-flag table within the big `AuCn` body.
    private static let enableTableOffset = 0x80
    /// Offset of the routing-index `u32` within a small `AuCn` body.
    private static let routingIndexOffset = 0x14

    // MARK: Public API

    /// Parse all `AuCn` chunks in a ProjectData blob.
    ///
    /// - Parameter data: Full contents of the `ProjectData` binary.
    /// - Returns: A tuple of `(entries, enableTable)`:
    ///   - `entries`: small routing entries (typically 12, one per routing index
    ///     other than the one consumed by the enable table).
    ///   - `enableTable`: the single big `AuCn` enable-flag table when found.
    static func decode(data: Data) -> (entries: [AuCnRoutingEntry], enableTable: AuCnEnableTable?) {
        var entries: [AuCnRoutingEntry] = []
        var enableTable: AuCnEnableTable? = nil

        for chunk in scanChunks(data: data) where chunk.id == idAuCn {
            let bodyEnd = chunk.bodyOffset + chunk.bodyLength
            guard bodyEnd <= data.count else { continue }
            let body = data.subdata(in: chunk.bodyOffset..<bodyEnd)

            if chunk.bodyLength == smallBodyLength {
                guard body.count >= routingIndexOffset + 4 else { continue }
                let raw = readLE32(body, at: routingIndexOffset)
                let routingIndex = Int(raw >> 16)
                entries.append(AuCnRoutingEntry(
                    oid: chunk.oid,
                    bodyLength: chunk.bodyLength,
                    routingIndex: routingIndex,
                    rawHeaderU32AtOffset14: raw
                ))
            } else if chunk.bodyLength > bigBodyMinLength {
                // Big AuCn — parse the u32 enable-flag table starting at 0x80.
                guard body.count >= enableTableOffset else { continue }
                var flags: [UInt32] = []
                var offset = enableTableOffset
                while offset + 4 <= body.count {
                    flags.append(readLE32(body, at: offset))
                    offset += 4
                }
                // If we already found one, prefer the first; projects have exactly one big AuCn.
                if enableTable == nil {
                    enableTable = AuCnEnableTable(
                        oid: chunk.oid,
                        bodyLength: chunk.bodyLength,
                        flagCount: flags.count,
                        flags: flags
                    )
                }
            }
        }

        return (entries, enableTable)
    }

    // MARK: - Chunk Scanning (copy of ProjectDataParser.scanChunks)

    /// Located chunk summary used internally by this decoder.
    private struct ChunkInfo {
        let id: String
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    /// Scan the entire blob for valid chunks using the anchor-signature method.
    ///
    /// Anchor at offset 0x16 within a 36-byte header:
    ///   `02 00 00 00 [01|02] 00`
    ///
    /// The chunk ID is 4 bytes at the very start of the header, i.e. 0x16 bytes
    /// before the anchor.
    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let total = data.count
        var offset = 4 // skip global magic

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

    // MARK: - Low-level Readers

    /// Read a little-endian `UInt32` at an offset within `data`.
    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Read a little-endian `UInt64` at an offset within `data`.
    private static func readLE64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[base + i]) << (i * 8)
        }
        return value
    }

    /// Reverse the 4 on-disk ID bytes to get the human-readable chunk ID
    /// (e.g. on-disk `[0x6E, 0x43, 0x75, 0x41]` -> `"AuCn"`).
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
