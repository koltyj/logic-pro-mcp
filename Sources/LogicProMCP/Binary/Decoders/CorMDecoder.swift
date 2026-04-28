import Foundation

// MARK: - CorMDecoder

/// Decoder for Logic Pro `CorM` (CoreMIDI port table) chunks.
///
/// Each `CorM` chunk stores a small table of CoreMIDI port entries (each with
/// a 32-bit handle/hash and a fixed-size, null-padded ASCII name). Two chunks
/// per project were observed across the bundled sample projects: one for input
/// ports (OID 232) and one for output ports (OID 236).
///
/// Body layout (after the 36-byte chunk header):
///
///     0x00  u16 LE  body length (matches `bodyLength` from chunk header)
///     0x02  u16 LE  port count (1 or 2 observed)
///     0x04  u16 LE  reserved (always 0)
///     0x06  ...     port slot 0 (100 bytes)
///     0x6A  ...     port slot 1 (100 bytes, if port count >= 2)
///
/// Each 100-byte port slot is:
///
///     +0x00  u32 LE   hash / handle (opaque random-looking identifier)
///     +0x04  96 B     null-padded ASCII port name
///
/// This decoder is intentionally independent of
/// `ProjectDataParser` / `ProjectDataInfo` — it reuses the same chunk scanner
/// (anchor-based) but does not feed into the main parse result. Integration
/// into `ProjectDataInfo` is a follow-up task.
public enum CorMDecoder {

    // MARK: - Public Models

    /// A single CoreMIDI port entry inside a `CorM` chunk.
    public struct CorMPort: Sendable, Codable, Equatable {
        /// 32-bit handle / hash. Appears to be a stable random identifier
        /// per port; we surface it verbatim without interpretation.
        public let hash: UInt32

        /// Null-trimmed ASCII port name (e.g. `"USB MIDI Device"`,
        /// `"Logic Pro Virtual In"`).
        public let name: String

        public init(hash: UInt32, name: String) {
            self.hash = hash
            self.name = name
        }
    }

    /// A decoded `CorM` chunk: the chunk's OID, the raw body length read from
    /// the chunk header, and the list of ports that could be parsed.
    public struct CorMRecord: Sendable, Codable, Equatable {
        public let oid: UInt32
        public let bodyLength: Int
        public let ports: [CorMPort]

        public init(oid: UInt32, bodyLength: Int, ports: [CorMPort]) {
            self.oid = oid
            self.bodyLength = bodyLength
            self.ports = ports
        }
    }

    // MARK: - Public API

    /// Decode every `CorM` chunk found in the given raw `ProjectData` bytes.
    ///
    /// Chunks with fewer than 6 body bytes (no room for the length/port-count
    /// header) are skipped. Ports whose names decode to an empty or
    /// non-ASCII string are dropped from the record's `ports` list — the
    /// record itself is still returned so callers can see how many CorM
    /// chunks existed.
    public static func decode(data: Data) -> [CorMRecord] {
        var result: [CorMRecord] = []

        for chunk in scanChunks(data: data) where chunk.id == chunkID {
            guard chunk.bodyLength >= minBodyHeaderSize else { continue }

            let bodyStart = chunk.bodyOffset
            let bodyEnd = bodyStart + chunk.bodyLength

            // Bounds already validated by scanChunks, but be explicit.
            guard bodyEnd <= data.count else { continue }
            let body = data[bodyStart..<bodyEnd]

            let portCount = Int(readLE16(body, at: 0x02))

            var ports: [CorMPort] = []
            ports.reserveCapacity(portCount)

            for p in 0..<portCount {
                let slotOffset = portTableOffset + p * portSlotSize
                // Need room for hash (4B) + name (96B) = 100 bytes per slot.
                guard slotOffset + portSlotSize <= chunk.bodyLength else { break }

                let hash = readLE32(body, at: slotOffset)
                let nameStart = slotOffset + 4
                let nameEnd = nameStart + portNameLength
                let nameBytes = body[(body.startIndex + nameStart)..<(body.startIndex + nameEnd)]

                guard let name = decodePortName(Data(nameBytes)) else {
                    // Non-ASCII or empty — skip this port but keep going.
                    continue
                }

                ports.append(CorMPort(hash: hash, name: name))
            }

            result.append(CorMRecord(
                oid: chunk.oid,
                bodyLength: chunk.bodyLength,
                ports: ports
            ))
        }

        return result
    }

    // MARK: - Constants

    private static let chunkID = "CorM"
    private static let minBodyHeaderSize = 6
    private static let portTableOffset = 6
    private static let portSlotSize = 100
    private static let portNameLength = 96

    // Chunk scanner constants — mirrors ProjectDataParser.
    private static let anchorPrefix: [UInt8] = [0x02, 0x00, 0x00, 0x00]
    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16
    private static let oidOffset = 0x0A
    private static let lengthOffset = 0x1C

    // MARK: - Port Name Decoding

    /// Decode a fixed-size null-padded ASCII port name. Returns nil if the
    /// decoded string is empty or contains non-ASCII / non-printable bytes
    /// (other than the padding null bytes).
    private static func decodePortName(_ raw: Data) -> String? {
        // Trim at first null byte.
        var end = raw.startIndex
        while end < raw.endIndex, raw[end] != 0 {
            end = raw.index(after: end)
        }
        let trimmed = raw[raw.startIndex..<end]
        guard !trimmed.isEmpty else { return nil }

        // Validate printable ASCII. Logic Pro uses plain ASCII for port names.
        for byte in trimmed {
            if byte < 0x20 || byte > 0x7E {
                return nil
            }
        }

        guard let name = String(data: Data(trimmed), encoding: .ascii) else {
            return nil
        }
        let stripped = name.trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: - Chunk Scanner (copied from ProjectDataParser)

    /// Describes a located chunk — matches ProjectDataParser.ChunkInfo.
    private struct ChunkInfo {
        let id: String
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    /// Scan the entire data blob for valid chunks using the anchor-signature
    /// method. This is a deliberate copy of `ProjectDataParser.scanChunks`
    /// so decoders stay standalone (see plan: decoders are isolated).
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

    /// Reverse 4 on-disk ID bytes to a human-readable chunk ID.
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
