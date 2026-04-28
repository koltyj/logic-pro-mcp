import Foundation

// MARK: - AuCOTypeDecoder

/// Isolated, read-only decoder for the AuCO channel-strip **type code** stored at
/// body offset 0x04 of every AuCO chunk in a Logic Pro ProjectData file.
///
/// This module is intentionally self-contained: it does **not** depend on
/// `ProjectDataParser` or `ProjectDataModels`. It re-implements the minimal
/// anchor-based chunk scan so the type decoding can be exercised and unit-tested
/// independently of the full parser pipeline.
///
/// Byte layout (confirmed by reverse-engineering three bundled sample projects):
///
/// - Every AuCO body begins with a 4-byte preamble followed by a 1-byte "kind"
///   code at `body[0x04]`. Observed codes and their meanings:
///
///     0x40 = Audio             (e.g. "Audio 7", "Audio 8")
///     0x41 = Mono Input        (e.g. "Input 1", "Input 4")
///     0x42 = Aux               (e.g. "Aux 1", "Aux 2")
///     0x43 = Software Instrument (e.g. "Inst 1", "Inst 2")
///     0x44 = Mono Output       (e.g. "Output 3", "Output 4", "¥Output 1")
///     0x45 = Bus               (e.g. "Bus 1", "Bus 2")
///     0x46 = Master
///     0x49 = Stereo Input      (e.g. "Input 1-2", "Input 3-4")
///     0x4C = Stereo Output     (e.g. "Output 3-4", "Output 9-10", "Output 1-2")
///
/// - The channel-strip name is a null-terminated ASCII string at `body[0x3C]`,
///   capped at 64 bytes.
///
/// Any AuCO chunk with an unrecognised kind byte is simply skipped — the
/// decoder never fails the whole decode for one unknown record.

/// Channel-strip kind as encoded at AuCO body offset 0x04.
enum AuCOType: UInt8, Sendable, Codable, CaseIterable {
    case audio = 0x40
    case monoInput = 0x41
    case aux = 0x42
    case softInst = 0x43
    case monoOutput = 0x44
    case bus = 0x45
    case master = 0x46
    case stereoInput = 0x49
    case stereoOutput = 0x4C

    /// Human-friendly label mirroring Logic Pro's mixer nomenclature.
    var displayName: String {
        switch self {
        case .audio: return "Audio"
        case .monoInput: return "Mono Input"
        case .aux: return "Aux"
        case .softInst: return "Software Instrument"
        case .monoOutput: return "Mono Output"
        case .bus: return "Bus"
        case .master: return "Master"
        case .stereoInput: return "Stereo Input"
        case .stereoOutput: return "Stereo Output"
        }
    }

    /// Convenience lookup: returns the matching case or `nil` for unknown bytes.
    static func from(rawByte: UInt8) -> AuCOType? {
        return AuCOType(rawValue: rawByte)
    }
}

/// A single decoded AuCO channel-strip record.
struct AuCOTypeRecord: Sendable, Codable {
    /// Object identifier from the AuCO chunk header.
    let oid: UInt32
    /// Body length in bytes (as reported by the chunk header).
    let bodyLength: Int
    /// Decoded kind from `body[0x04]`.
    let type: AuCOType
    /// Null-terminated ASCII name read from `body[0x3C]` (trimmed).
    let name: String
}

/// Namespace for the AuCO type-code decoder.
enum AuCOTypeDecoder {

    // MARK: - Constants

    /// Chunk header is always 36 bytes.
    private static let chunkHeaderSize = 36
    /// Anchor offset within the header: `02 00 00 00 [01|02] 00`.
    private static let anchorOffset = 0x16
    /// OID offset within the header.
    private static let oidOffset = 0x0A
    /// Body-length offset within the header.
    private static let lengthOffset = 0x1C
    /// Reversed chunk ID we're filtering on.
    private static let idAuCO = "AuCO"
    /// Type-code offset within the AuCO body.
    private static let typeCodeOffset = 0x04
    /// Name offset within the AuCO body (null-terminated ASCII).
    private static let nameOffset = 0x3C
    /// Maximum name length to read before we give up scanning for a terminator.
    private static let nameMaxLength = 64
    /// Minimum body length needed to safely read the name field at 0x3C.
    private static let minBodyLength = 0x5A

    // MARK: - Public API

    /// Decode all AuCO channel-strip type records from a raw ProjectData blob.
    ///
    /// The decoder scans the entire blob for valid chunk anchors, filters to
    /// "AuCO" chunks with a body length large enough to contain the type and
    /// name fields, then maps each type byte through `AuCOType`. Chunks whose
    /// type byte is not a known case are silently skipped.
    ///
    /// - Parameter data: Full contents of a Logic Pro `ProjectData` file.
    /// - Returns: Records in the order they are discovered in the file.
    static func decode(data: Data) -> [AuCOTypeRecord] {
        // Validate the global magic so we don't waste time scanning garbage.
        guard validateMagic(data) else { return [] }

        var result: [AuCOTypeRecord] = []
        let total = data.count
        var offset = 4 // skip global magic

        // Anchor-based chunk scanner — mirrors ProjectDataParser.scanChunks(),
        // but filters to AuCO chunks inline so we avoid building an
        // intermediate collection of every chunk in the file.
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

            // Read and reverse the 4-byte chunk ID.
            let rawID = [
                data[offset + 0], data[offset + 1],
                data[offset + 2], data[offset + 3]
            ]
            let id = reverseID(rawID)

            if id == idAuCO, bodyLength >= minBodyLength {
                let oid = readLE32(data, at: offset + oidOffset)
                let body = data.subdata(in: bodyStart..<(bodyStart + bodyLength))

                if let type = AuCOType.from(rawByte: body[typeCodeOffset]) {
                    let name = readName(body: body)
                    result.append(AuCOTypeRecord(
                        oid: oid,
                        bodyLength: bodyLength,
                        type: type,
                        name: name
                    ))
                }
            }

            offset = bodyStart + bodyLength
        }

        return result
    }

    // MARK: - Private helpers

    /// Validate the 4-byte ProjectData magic at offset 0 (`23 47 C0 AB`).
    private static func validateMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let base = data.startIndex
        return data[base] == 0x23
            && data[base + 1] == 0x47
            && data[base + 2] == 0xC0
            && data[base + 3] == 0xAB
    }

    /// Read the null-terminated ASCII channel-strip name at body offset 0x3C.
    /// Reads up to `nameMaxLength` bytes and trims whitespace/null padding.
    private static func readName(body: Data) -> String {
        let available = body.count - nameOffset
        guard available > 0 else { return "" }

        let readLen = min(nameMaxLength, available)
        let base = body.startIndex + nameOffset
        var bytes: [UInt8] = []
        bytes.reserveCapacity(readLen)
        for i in 0..<readLen {
            let b = body[base + i]
            if b == 0 { break }
            bytes.append(b)
        }

        let decoded = String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? ""
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read a 4-byte little-endian UInt32 from `data` at an absolute offset.
    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Read an 8-byte little-endian UInt64 from `data` at an absolute offset.
    private static func readLE64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[base + i]) << (i * 8)
        }
        return value
    }

    /// Reverse the 4 raw ID bytes to the on-disk human-readable identifier.
    /// Non-printable or all-zero IDs return a distinct placeholder so they
    /// can't accidentally match `"AuCO"`.
    private static func reverseID(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "????" }
        let reversed = bytes.reversed()
        let chars = reversed.compactMap { b -> Character? in
            let scalar = Unicode.Scalar(b)
            let ch = Character(scalar)
            return ch.isASCII && scalar.value >= 32 ? ch : nil
        }
        if chars.count < 4 { return "PluginData" }
        return String(chars)
    }
}
