import Foundation

// MARK: - Public Types

/// An arrangement-marker text record parsed from a short TxSq chunk.
///
/// Projects 2 and 3 of the bundled fixtures contain 8 TxSq chunks each
/// (project 1 has none). Short TxSq chunks (body length ~104-106) encode
/// an arrangement-marker section name ("Intro", "Chorus", "Bridge", etc.)
/// as a null-terminated ASCII string in the tail of the body. Longer
/// TxSq chunks (~480-484 bytes) carry RTF text and are handled separately
/// by `ProjectDataParser.extractTxSqNames`.
public struct TxSqMarker: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable {
        case shortAscii   // null-terminated ASCII in the body tail
        case rtf          // RTF payload with \fs text run
        case unknown
    }

    /// OID of the owning TxSq chunk.
    public let oid: UInt32
    /// Body length in bytes.
    public let bodyLength: Int
    /// Extracted marker name, trimmed.
    public let markerName: String
    /// How the name was located.
    public let source: Source
}

// MARK: - Decoder

public enum TxSqMarkerDecoder {

    /// Scan `ProjectData` for TxSq arrangement-marker name chunks and decode
    /// each one. Returns records in discovery order, deduplicated by
    /// `(oid, markerName)`.
    public static func decode(data: Data) -> [TxSqMarker] {
        let chunks = scanChunks(data: data)
        var seen: Set<String> = []
        var result: [TxSqMarker] = []

        for chunk in chunks where chunk.id == "TxSq" {
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // Prefer the short-ASCII path first (short chunks have the name
            // in the tail region; longer RTF chunks often have no usable
            // text in the short-ASCII slot).
            if let name = extractShortAsciiName(body: body) {
                let key = "\(chunk.oid)\u{0}\(name)"
                if seen.insert(key).inserted {
                    result.append(TxSqMarker(
                        oid: chunk.oid,
                        bodyLength: chunk.bodyLength,
                        markerName: name,
                        source: .shortAscii
                    ))
                }
                continue
            }

            if let rtf = extractRTFText(body) {
                let key = "\(chunk.oid)\u{0}\(rtf)"
                if seen.insert(key).inserted {
                    result.append(TxSqMarker(
                        oid: chunk.oid,
                        bodyLength: chunk.bodyLength,
                        markerName: rtf,
                        source: .rtf
                    ))
                }
            }
        }

        return result
    }
}

// MARK: - Short-ASCII Extraction

/// Look for a null-terminated ASCII run in the body tail. In observed
/// samples the marker name lives at body offset ~0x62 onward, but the
/// exact position is not guaranteed, so we scan the last 48 bytes of the
/// body for the first run that validates.
private func extractShortAsciiName(body: Data) -> String? {
    // Require the "//QR" tag somewhere in the body — that's the discriminator
    // for short arrangement-marker TxSq chunks vs RTF-carrying ones.
    guard let qrRange = body.range(of: Data([0x2F, 0x2F, 0x51, 0x52])) else {
        return nil
    }

    // Scan from just past the "//QR" tag to the end of the body for the
    // first plausible printable-ASCII run (length 3..32, contains a letter).
    let scanStart = qrRange.upperBound
    guard scanStart < body.endIndex else { return nil }

    var i = scanStart
    while i < body.endIndex {
        let b = body[i]
        if b >= 0x20 && b < 0x7F {
            var end = i
            while end < body.endIndex, body[end] >= 0x20, body[end] < 0x7F {
                end = body.index(after: end)
            }
            let slice = body[i..<end]
            if slice.count >= 3, slice.count <= 32,
               slice.contains(where: { isASCIILetter($0) }) {
                let str = String(decoding: slice, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !str.isEmpty {
                    return str
                }
            }
            i = body.index(after: end)
        } else {
            i = body.index(after: i)
        }
    }
    return nil
}

private func isASCIILetter(_ b: UInt8) -> Bool {
    (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
}

// MARK: - RTF Extraction (self-contained, mirrors ProjectDataParser)

private func extractRTFText(_ body: Data) -> String? {
    let asciiStr = String(body.map { b -> Character in
        let s = Unicode.Scalar(b)
        return s.value >= 32 && s.value < 127 ? Character(s) : Character(".")
    })

    guard asciiStr.contains("{\\rtf") || asciiStr.contains("\\fs") else {
        return nil
    }

    guard let fsRange = asciiStr.range(of: "\\fs") else { return nil }

    var idx = fsRange.upperBound
    while idx < asciiStr.endIndex, asciiStr[idx].isNumber {
        idx = asciiStr.index(after: idx)
    }

    var textStart = idx
    while textStart < asciiStr.endIndex {
        let ch = asciiStr[textStart]
        if ch == " " {
            textStart = asciiStr.index(after: textStart)
            continue
        }
        if ch == "\\" {
            var j = asciiStr.index(after: textStart)
            while j < asciiStr.endIndex, asciiStr[j].isLetter || asciiStr[j].isNumber {
                j = asciiStr.index(after: j)
            }
            if j < asciiStr.endIndex, asciiStr[j] == " " {
                j = asciiStr.index(after: j)
            }
            textStart = j
            continue
        }
        break
    }

    var textEnd = textStart
    while textEnd < asciiStr.endIndex, asciiStr[textEnd] != "}" {
        textEnd = asciiStr.index(after: textEnd)
    }

    guard textStart < textEnd else { return nil }

    var text = String(asciiStr[textStart..<textEnd])
    text = text.replacingOccurrences(of: "..", with: " ")
    text = text.replacingOccurrences(of: ".", with: "")
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while let c = text.first, !c.isLetter, !c.isNumber { text.removeFirst() }
    while let c = text.last, !c.isLetter, !c.isNumber { text.removeLast() }

    guard !text.isEmpty, text.contains(where: { $0.isLetter }), text.count <= 32 else {
        return nil
    }
    return text
}

// MARK: - Chunk Scanner (copy of ProjectDataParser's scanner)

private struct ChunkInfo {
    let id: String
    let oid: UInt32
    let bodyOffset: Int
    let bodyLength: Int
}

private let magicBytes: [UInt8] = [0x23, 0x47, 0xC0, 0xAB]
private let chunkHeaderSize = 36
private let anchorOffset = 0x16
private let oidOffset = 0x0A
private let lengthOffset = 0x1C

private func scanChunks(data: Data) -> [ChunkInfo] {
    guard data.count >= 4,
          data[0] == 0x23, data[1] == 0x47, data[2] == 0xC0, data[3] == 0xAB
    else { return [] }

    var result: [ChunkInfo] = []
    let total = data.count
    var offset = 4

    while offset + chunkHeaderSize <= total {
        guard data[offset + anchorOffset + 0] == 0x02,
              data[offset + anchorOffset + 1] == 0x00,
              data[offset + anchorOffset + 2] == 0x00,
              data[offset + anchorOffset + 3] == 0x00,
              data[offset + anchorOffset + 4] == 0x01 || data[offset + anchorOffset + 4] == 0x02,
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
        let id = String(bytes: rawID.reversed(), encoding: .ascii) ?? "????"
        let oid = readLE32(data, at: offset + oidOffset)

        result.append(ChunkInfo(id: id, oid: oid, bodyOffset: bodyStart, bodyLength: bodyLength))
        offset = bodyStart + bodyLength
    }
    return result
}

private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    let base = data.startIndex + offset
    return UInt32(data[base]) |
        (UInt32(data[base + 1]) << 8) |
        (UInt32(data[base + 2]) << 16) |
        (UInt32(data[base + 3]) << 24)
}

private func readLE64(_ data: Data, at offset: Int) -> UInt64 {
    guard offset + 8 <= data.count else { return 0 }
    let base = data.startIndex + offset
    var result: UInt64 = 0
    for i in 0..<8 {
        result |= UInt64(data[base + i]) << (8 * i)
    }
    return result
}
