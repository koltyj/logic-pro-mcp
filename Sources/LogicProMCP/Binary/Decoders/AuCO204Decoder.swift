import Foundation

// MARK: - AuCO204Decoder

/// Isolated decoder for the 204-byte extended variant of `AuCO` channel-strip
/// chunks in Logic Pro `ProjectData` files.
///
/// Background
/// ----------
/// Regular (152-byte) `AuCO` bodies describe placeholder channel strips that
/// Logic emits by default for every visible Environment slot. A subset of
/// channel strips — the project's "real" tracks (Audio N, Aux N, Inst N,
/// Output N, ...) — use a 204-byte extended body that adds a flag block at
/// `0x98..0xBC` (11 × u32, each observed to be 0 or 1). The semantics of
/// those 11 flags are only partially understood (they look like per-strip
/// automation / recording / solo-safe state), so this decoder surfaces them
/// as a raw `[UInt32]` for downstream consumers.
///
/// This decoder is deliberately standalone: it includes its own chunk
/// scanner (copied from `ProjectDataParser.swift` anchor-signature logic)
/// so it can be tested and evolved independently of the main parser. It
/// does not import or depend on `ProjectDataParser` / `ProjectDataModels`.
public enum AuCO204Decoder {

    // MARK: - Public model

    /// Decoded 204-byte AuCO channel-strip record.
    public struct AuCO204Record: Sendable, Codable, Equatable {
        /// Chunk object identifier (LE u32 at header offset 0x0A).
        public let oid: UInt32
        /// Type byte at body offset 0x04 (e.g. 0x40 Audio, 0x42 Aux,
        /// 0x43 Inst, 0x44 MonoOut, 0x4C StereoOut).
        public let typeByte: UInt8
        /// Null-terminated ASCII name from body offset 0x3C, trimmed.
        public let name: String
        /// 11 × u32 LE values starting at body offset 0x98, stepping by 4.
        /// Each observed value is 0 or 1 and likely represents per-strip
        /// automation / recording state flags (arm, monitor, freeze,
        /// automation-read/write/touch/latch/trim, group-enable,
        /// solo-safe, mute-safe — exact mapping not yet confirmed).
        public let extendedFlags: [UInt32]

        public init(oid: UInt32, typeByte: UInt8, name: String, extendedFlags: [UInt32]) {
            self.oid = oid
            self.typeByte = typeByte
            self.name = name
            self.extendedFlags = extendedFlags
        }
    }

    // MARK: - Constants

    /// Number of flag slots in the extended block at 0x98..0xBC.
    public static let extendedFlagCount = 11

    /// Body length for the extended AuCO variant.
    public static let extendedBodyLength = 204

    private static let magicBytes: [UInt8] = [0x23, 0x47, 0xC0, 0xAB]
    private static let chunkHeaderSize = 36
    private static let idOffset = 0x00
    private static let oidOffset = 0x0A
    private static let anchorOffset = 0x16
    private static let lengthOffset = 0x1C

    private static let idAuCO = "AuCO"
    private static let typeByteOffset = 0x04
    private static let nameOffset = 0x3C
    private static let nameMaxLength = 64
    private static let extendedBlockOffset = 0x98

    // MARK: - Public API

    /// Decode all 204-byte `AuCO` records from a raw `ProjectData` blob.
    ///
    /// Chunks that fail the magic check, anchor signature, or length
    /// validation are skipped silently. Chunks whose ID is not `AuCO`
    /// or whose body length is not exactly 204 bytes are skipped.
    ///
    /// - Parameter data: Full contents of a `ProjectData` file.
    /// - Returns: One record per valid 204-byte `AuCO` chunk, in file order.
    public static func decode(data: Data) -> [AuCO204Record] {
        guard validateMagic(data) else { return [] }

        var records: [AuCO204Record] = []
        for chunk in scanChunks(data: data) {
            guard chunk.id == idAuCO,
                  chunk.bodyLength == extendedBodyLength else { continue }

            let body = data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)]
            guard let record = decodeBody(oid: chunk.oid, body: body) else { continue }
            records.append(record)
        }
        return records
    }

    // MARK: - Body decoder

    private static func decodeBody(oid: UInt32, body: Data) -> AuCO204Record? {
        let base = body.startIndex
        guard body.count >= extendedBodyLength else { return nil }

        let typeByte = body[base + typeByteOffset]
        let name = readCString(body: body, offset: nameOffset, maxLength: nameMaxLength)

        var flags: [UInt32] = []
        flags.reserveCapacity(extendedFlagCount)
        for slot in 0..<extendedFlagCount {
            let off = extendedBlockOffset + slot * 4
            guard off + 4 <= body.count else { return nil }
            flags.append(readLE32(body, at: off))
        }

        return AuCO204Record(
            oid: oid,
            typeByte: typeByte,
            name: name,
            extendedFlags: flags
        )
    }

    // MARK: - Magic validation

    private static func validateMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let base = data.startIndex
        return data[base] == magicBytes[0]
            && data[base + 1] == magicBytes[1]
            && data[base + 2] == magicBytes[2]
            && data[base + 3] == magicBytes[3]
    }

    // MARK: - Chunk scanning (copied pattern from ProjectDataParser.swift:264)

    private struct ChunkInfo {
        let id: String
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let total = data.count
        let base = data.startIndex
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
            // Anchor pattern at 0x16 within header: 02 00 00 00 [01|02] 00
            guard data[base + offset + anchorOffset] == 0x02,
                  data[base + offset + anchorOffset + 1] == 0x00,
                  data[base + offset + anchorOffset + 2] == 0x00,
                  data[base + offset + anchorOffset + 3] == 0x00,
                  (data[base + offset + anchorOffset + 4] == 0x01
                    || data[base + offset + anchorOffset + 4] == 0x02),
                  data[base + offset + anchorOffset + 5] == 0x00
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

            let rawID: [UInt8] = [
                data[base + offset + idOffset + 0],
                data[base + offset + idOffset + 1],
                data[base + offset + idOffset + 2],
                data[base + offset + idOffset + 3],
            ]
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

    // MARK: - Low-level readers

    /// Read a null-terminated ASCII string from `body` at `offset`, bounded
    /// by `maxLength`. Non-printable bytes terminate the string.
    private static func readCString(body: Data, offset: Int, maxLength: Int) -> String {
        let base = body.startIndex + offset
        guard offset >= 0, base <= body.endIndex else { return "" }

        let limit = min(body.endIndex, base + maxLength)
        var scalars: [Character] = []
        scalars.reserveCapacity(maxLength)

        var idx = base
        while idx < limit {
            let byte = body[idx]
            if byte == 0 { break }
            let scalar = Unicode.Scalar(byte)
            if scalar.value < 0x20 || scalar.value >= 0x7F { break }
            scalars.append(Character(scalar))
            idx += 1
        }

        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// Read a 4-byte little-endian UInt32 from `data` at `offset`.
    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Read an 8-byte little-endian UInt64 from `data` at `offset`.
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
    /// e.g., on-disk bytes [0x4F, 0x43, 0x75, 0x41] -> "AuCO"
    private static func reverseID(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "????" }
        let reversed = bytes.reversed()
        let chars = reversed.compactMap { byte -> Character? in
            let scalar = Unicode.Scalar(byte)
            let ch = Character(scalar)
            return ch.isASCII && scalar.value >= 32 ? ch : nil
        }
        if chars.count < 4 {
            return "PluginData"
        }
        return String(chars)
    }
}
