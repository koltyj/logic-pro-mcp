import Foundation

// MARK: - Public Types

/// Kind of SngO (Song Object) record.
public enum SngOKind: String, Sendable, Codable {
    /// oid=224 — NSKeyedArchiver bplist carrying
    /// `genInstDrummerBaseModel.state` (drummer model state snapshot).
    case drummerState
    /// oid=244 — mostly zeros with a `0x00016006` marker at `body[0x10]`.
    /// Purpose unknown; possibly a per-song flags/state block.
    case unknownFlags
    /// oid=264 — either a tiny 32-byte header (project 1) or an
    /// NSKeyedArchiver bplist starting at body offset 76 carrying the
    /// same `Shared.arrangementMarkerTitleList` as `GenM` (when the
    /// project has explicit arrangement markers).
    case tinyOrMarkerList
}

/// A decoded SngO record.
public struct SngORecord: Sendable, Codable {
    /// OID from the chunk header.
    public let oid: UInt32
    /// Body length in bytes.
    public let bodyLength: Int
    /// Classification of this record.
    public let kind: SngOKind
    /// `stateVersion` field for drummer state plists.
    public let drummerStateVersion: Int?
    /// `autoSelectRegions` field for drummer state plists.
    public let autoSelectRegions: Bool?
    /// Nonzero marker at `body[0x10]` for `unknownFlags` records.
    public let unknownHeaderMarker: UInt32?
    /// Stable identity hash at `body[0x14]` for `tinyOrMarkerList`
    /// records (observed `0xED990001` across all samples).
    public let stableUID: UInt32?
    /// Arrangement-marker section names extracted from the embedded
    /// plist when present (SngO oid=264 in projects with markers).
    public let arrangementMarkerNames: [String]
}

// MARK: - Decoder

public enum SngODecoder {

    public static func decode(data: Data) -> [SngORecord] {
        let chunks = scanChunks(data: data)
        var out: [SngORecord] = []
        for chunk in chunks where chunk.id == "SngO" {
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            let kind = classify(oid: chunk.oid, bodyLength: chunk.bodyLength)

            var drummerStateVersion: Int? = nil
            var autoSelectRegions: Bool? = nil
            var unknownHeaderMarker: UInt32? = nil
            var stableUID: UInt32? = nil
            var markerNames: [String] = []

            switch kind {
            case .drummerState:
                (drummerStateVersion, autoSelectRegions) = parseDrummerState(body: body)
            case .unknownFlags:
                if chunk.bodyLength >= 0x14 {
                    unknownHeaderMarker = readLE32(body, at: 0x10)
                }
            case .tinyOrMarkerList:
                if chunk.bodyLength >= 0x18 {
                    stableUID = readLE32(body, at: 0x14)
                }
                markerNames = parseEmbeddedMarkerTitles(body: body)
            }

            out.append(SngORecord(
                oid: chunk.oid,
                bodyLength: chunk.bodyLength,
                kind: kind,
                drummerStateVersion: drummerStateVersion,
                autoSelectRegions: autoSelectRegions,
                unknownHeaderMarker: unknownHeaderMarker,
                stableUID: stableUID,
                arrangementMarkerNames: markerNames
            ))
        }
        return out
    }
}

// MARK: - Classification

private func classify(oid: UInt32, bodyLength: Int) -> SngOKind {
    switch oid {
    case 224: return .drummerState
    case 244: return .unknownFlags
    case 264: return .tinyOrMarkerList
    default:
        // Fallback heuristic: classify by body length.
        if bodyLength < 64 { return .tinyOrMarkerList }
        if bodyLength > 1500 { return .unknownFlags }
        return .drummerState
    }
}

// MARK: - Plist Extraction

private func findBplist(_ body: Data) -> Data? {
    guard let range = body.range(of: Data("bplist00".utf8)) else { return nil }
    return Data(body[range.lowerBound...])
}

private func parseDrummerState(body: Data) -> (Int?, Bool?) {
    guard let plistBytes = findBplist(body),
          let plist = try? PropertyListSerialization.propertyList(from: plistBytes, options: [], format: nil) as? [String: Any]
    else { return (nil, nil) }

    // Walk NSKeyedArchiver graph looking for "stateVersion" and "autoSelectRegions".
    guard let objects = plist["$objects"] as? [Any] else { return (nil, nil) }

    var stateVersion: Int?
    var autoSelect: Bool?

    for obj in objects {
        guard let dict = obj as? [String: Any],
              let keyRefs = dict["NS.keys"] as? [Any],
              let valRefs = dict["NS.objects"] as? [Any]
        else { continue }

        for (kRef, vRef) in zip(keyRefs, valRefs) {
            guard let keyIndex = uidValue(kRef),
                  let keyObj = resolveObject(objects: objects, uidIndex: keyIndex),
                  let keyStr = keyObj as? String
            else { continue }

            if keyStr == "stateVersion", let valIndex = uidValue(vRef),
               let valObj = resolveObject(objects: objects, uidIndex: valIndex),
               let n = valObj as? NSNumber {
                // Prefer the outermost stateVersion (5) over the nested drummer one (1)
                if stateVersion == nil || n.intValue > (stateVersion ?? 0) {
                    stateVersion = n.intValue
                }
            }
            if keyStr == "autoSelectRegions", let valIndex = uidValue(vRef),
               let valObj = resolveObject(objects: objects, uidIndex: valIndex) {
                if let n = valObj as? NSNumber {
                    autoSelect = n.boolValue
                }
            }
        }
    }
    return (stateVersion, autoSelect)
}

private func parseEmbeddedMarkerTitles(body: Data) -> [String] {
    guard let plistBytes = findBplist(body),
          let plist = try? PropertyListSerialization.propertyList(from: plistBytes, options: [], format: nil) as? [String: Any],
          let objects = plist["$objects"] as? [Any]
    else { return [] }

    // Collect every "NS.string" payload referenced by any NSDictionary entry
    // whose parent dict is keyed under an NSDictionary indexed by "type" →
    // short int. Simpler: just collect all NS.string values that have
    // plausible arrangement-marker names.
    var names: [String] = []
    for obj in objects {
        guard let dict = obj as? [String: Any],
              let s = dict["NS.string"] as? String
        else { continue }
        // Filter out class names like "NSDictionary", "NSMutableDictionary".
        if s.hasPrefix("NS"), !s.contains(" ") { continue }
        // Filter out key/marker sentinels like "arrangementMarkerTitleList", "Shared".
        if s == "Shared" || s == "arrangementMarkerTitleList" { continue }
        // Filter integer-like short strings ("0".."99") — they're slot keys, not names.
        if s.count <= 2, s.allSatisfy({ $0.isNumber }) { continue }
        names.append(s)
    }
    return names
}

// MARK: - NSKeyedArchiver UID Resolution

/// Extract the numeric value from a `CFKeyedArchiverUID` reference.
/// `PropertyListSerialization` returns UID refs as a private
/// CoreFoundation type; on modern macOS they bridge to Swift as a type
/// whose `String(describing:)` yields `{value = N}`.
private func uidValue(_ ref: Any) -> Int? {
    let desc = String(describing: ref)
    if let eqRange = desc.range(of: "value = "),
       let endRange = desc.range(of: "}", range: eqRange.upperBound..<desc.endIndex) {
        let num = desc[eqRange.upperBound..<endRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return Int(num)
    }
    return nil
}

private func resolveObject(objects: [Any], uidIndex: Int) -> Any? {
    guard uidIndex >= 0, uidIndex < objects.count else { return nil }
    return objects[uidIndex]
}

// MARK: - Chunk Scanner (copy of ProjectDataParser's scanner)

private struct ChunkInfo {
    let id: String
    let oid: UInt32
    let bodyOffset: Int
    let bodyLength: Int
}

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
