import Foundation

// MARK: - ArrangementMarkerTitle

/// A single entry in Logic Pro's arrangement-marker title list.
///
/// Each slot in the list may or may not carry a user-defined name. Typeless
/// placeholders (`type == 0`, no name) are preserved so the slot indices
/// remain aligned with Logic's internal bookkeeping.
struct ArrangementMarkerTitle: Sendable, Codable, Equatable {
    /// Slot index, parsed from the stringified integer keys in the bplist dict.
    let slotIndex: Int
    /// Marker `type` integer (observed values: 0..5). Exact semantics unknown.
    let type: Int
    /// User-defined name (e.g. "Intro", "Verse", "Chorus", "Bridge"). Nil for
    /// typeless placeholder slots that carry no `name` key.
    let name: String?
}

// MARK: - GenMDecoder

/// Decoder for `GenM` chunks. A GenM chunk (when present — zero or one per
/// project) wraps a `bplist00` NSKeyedArchiver payload that stores the
/// arrangement-marker title list from Logic Pro's arrangement track.
///
/// Body layout (observed in real projects):
///   0x00  36B   GenM-specific header (flags + 0xFFFF... sentinel)
///   0x24  N     `bplist00` NSKeyedArchiver payload to end-of-body
///
/// The bplist root resolves (via `$top.root`) to a dictionary of the form:
///
///     { "Shared": { "arrangementMarkerTitleList": {
///         "0": { "type": 0 },
///         "1": { "type": 1 },
///         ...
///         "5": { "type": 1, "name": { "NS.string": "Intro"  } },
///         "6": { "type": 1, "name": { "NS.string": "Verse"  } },
///         ...
///     }}}
///
/// Rather than running full NSKeyedUnarchiver (which requires registering the
/// Objective-C classes stored in `$classname`), this decoder parses the
/// property list into raw Swift dictionaries/arrays and walks the
/// `$objects` graph manually, resolving `UID` references by value.
enum GenMDecoder {

    // MARK: - Constants

    private static let magicBytes: [UInt8] = [0x23, 0x47, 0xC0, 0xAB]
    private static let anchorOffset = 0x16
    private static let lengthOffset = 0x1C
    private static let oidOffset = 0x0A
    private static let chunkHeaderSize = 36
    private static let idGenM = "GenM"
    private static let bplistMagic: [UInt8] = Array("bplist00".utf8)

    // MARK: - Public API

    /// Decode arrangement marker titles from a raw ProjectData blob.
    ///
    /// Scans the file for `GenM` chunks, extracts the embedded `bplist00`
    /// payload from each, and merges the decoded title lists preserving
    /// slot-index order. Returns an empty array when no GenM chunks are
    /// present (projects without an arrangement-marker title list).
    static func decode(data: Data) -> [ArrangementMarkerTitle] {
        guard validateMagic(data) else { return [] }

        var result: [ArrangementMarkerTitle] = []
        for (bodyOffset, bodyLength) in scanGenMBodies(data: data) {
            let bodyEnd = bodyOffset + bodyLength
            guard bodyEnd <= data.count else { continue }
            let body = data[bodyOffset..<bodyEnd]
            guard let bplistStart = findBplistStart(in: body) else { continue }
            let bplist = Data(body[bplistStart..<body.endIndex])
            let titles = decodeBplist(bplist)
            result.append(contentsOf: titles)
        }
        // Sort by slot index so downstream consumers get a predictable order
        // even when multiple GenM chunks appear in a future project format.
        result.sort { $0.slotIndex < $1.slotIndex }
        return result
    }

    /// Convenience overload that reads the ProjectData from a `.logicx` bundle
    /// or a raw ProjectData file path.
    static func decode(path: String) -> [ArrangementMarkerTitle] {
        let url = URL(fileURLWithPath: path)
        let projectDataURL: URL
        if path.hasSuffix(".logicx") || url.pathExtension == "logicx" {
            guard let found = findProjectData(in: url) else { return [] }
            projectDataURL = found
        } else {
            projectDataURL = url
        }
        guard let data = try? Data(contentsOf: projectDataURL) else { return [] }
        return decode(data: data)
    }

    // MARK: - Chunk Scanning

    /// Enumerate the body offset/length of every `GenM` chunk in the file.
    private static func scanGenMBodies(data: Data) -> [(bodyOffset: Int, bodyLength: Int)] {
        var result: [(Int, Int)] = []
        let total = data.count
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
            let anchorStart = offset + anchorOffset
            guard data[anchorStart] == 0x02,
                  data[anchorStart + 1] == 0x00,
                  data[anchorStart + 2] == 0x00,
                  data[anchorStart + 3] == 0x00,
                  (data[anchorStart + 4] == 0x01 || data[anchorStart + 4] == 0x02),
                  data[anchorStart + 5] == 0x00
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
            if id == idGenM {
                result.append((bodyStart, bodyLength))
            }
            offset = bodyStart + bodyLength
        }
        return result
    }

    /// Locate the `bplist00` magic within a chunk body. In practice this sits
    /// at body offset 0x24, but we scan defensively in case the GenM header
    /// grows in a future Logic Pro release.
    private static func findBplistStart(in body: Data.SubSequence) -> Data.Index? {
        return body.range(of: Data(bplistMagic))?.lowerBound
    }

    // MARK: - Bplist Decoding

    /// Parse the NSKeyedArchiver bplist bytes and resolve the arrangement
    /// marker title list. Returns an empty array when the graph has an
    /// unexpected shape (guards against malformed payloads).
    private static func decodeBplist(_ bplist: Data) -> [ArrangementMarkerTitle] {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: bplist, options: [], format: nil
        ) else {
            return []
        }
        guard let root = plist as? [String: Any],
              let objects = root["$objects"] as? [Any]
        else {
            return []
        }

        // Find the sentinel string "arrangementMarkerTitleList".
        guard let sentinelIdx = objects.firstIndex(where: {
            ($0 as? String) == "arrangementMarkerTitleList"
        }) else {
            return []
        }

        // Locate the NSDictionary whose NS.keys contains a UID pointing to
        // the sentinel. The adjacent NS.objects entry is a UID to the actual
        // title-list dictionary.
        guard let titleListIdx = findValueUID(
            forKeyIndex: sentinelIdx,
            in: objects
        ) else {
            return []
        }

        guard titleListIdx < objects.count,
              let titleDict = objects[titleListIdx] as? [String: Any],
              let keyUIDs = titleDict["NS.keys"] as? [Any],
              let valueUIDs = titleDict["NS.objects"] as? [Any],
              keyUIDs.count == valueUIDs.count
        else {
            return []
        }

        var titles: [ArrangementMarkerTitle] = []
        for (keyUID, valueUID) in zip(keyUIDs, valueUIDs) {
            guard let keyIdx = extractUIDValue(keyUID),
                  keyIdx < objects.count,
                  let slotStr = objects[keyIdx] as? String,
                  let slot = Int(slotStr)
            else {
                continue
            }
            guard let entryIdx = extractUIDValue(valueUID),
                  entryIdx < objects.count,
                  let entry = objects[entryIdx] as? [String: Any]
            else {
                continue
            }
            let (typeValue, nameValue) = decodeEntry(entry, objects: objects)
            titles.append(ArrangementMarkerTitle(
                slotIndex: slot,
                type: typeValue ?? 0,
                name: nameValue
            ))
        }
        titles.sort { $0.slotIndex < $1.slotIndex }
        return titles
    }

    /// Extract `type` (Int) and optional `name` (String) from an entry
    /// dictionary whose `NS.keys` contain UIDs to "type"/"name" strings and
    /// `NS.objects` contain the corresponding values (NSNumber for type, UID
    /// to an NSString wrapper for name).
    private static func decodeEntry(
        _ entry: [String: Any],
        objects: [Any]
    ) -> (type: Int?, name: String?) {
        guard let keyUIDs = entry["NS.keys"] as? [Any],
              let valueUIDs = entry["NS.objects"] as? [Any],
              keyUIDs.count == valueUIDs.count
        else {
            return (nil, nil)
        }
        var typeValue: Int?
        var nameValue: String?
        for (keyUID, valueUID) in zip(keyUIDs, valueUIDs) {
            guard let keyIdx = extractUIDValue(keyUID),
                  keyIdx < objects.count,
                  let keyName = objects[keyIdx] as? String
            else {
                continue
            }
            switch keyName {
            case "type":
                // NSNumber values may be stored inline or via a UID
                // reference into `$objects`, depending on whether the
                // archiver chose to dedupe them.
                if let uid = extractUIDValue(valueUID),
                   uid < objects.count,
                   let number = objects[uid] as? NSNumber {
                    typeValue = number.intValue
                } else if let number = valueUID as? NSNumber {
                    typeValue = number.intValue
                }
            case "name":
                if let uid = extractUIDValue(valueUID),
                   uid < objects.count,
                   let nameWrapper = objects[uid] as? [String: Any],
                   let str = nameWrapper["NS.string"] as? String {
                    nameValue = str
                }
            default:
                continue
            }
        }
        return (typeValue, nameValue)
    }

    // MARK: - UID Helpers

    /// Walk `$objects` looking for any NSDictionary whose `NS.keys` contains a
    /// UID pointing to `keyIndex`, and return the UID value sitting at the
    /// same position in `NS.objects`.
    private static func findValueUID(forKeyIndex keyIndex: Int, in objects: [Any]) -> Int? {
        for obj in objects {
            guard let dict = obj as? [String: Any],
                  let keys = dict["NS.keys"] as? [Any],
                  let values = dict["NS.objects"] as? [Any],
                  keys.count == values.count
            else { continue }
            for (i, k) in keys.enumerated() {
                if extractUIDValue(k) == keyIndex {
                    return extractUIDValue(values[i])
                }
            }
        }
        return nil
    }

    /// Extract the integer value from a `CFKeyedArchiverUID` by parsing its
    /// `String(describing:)` representation (the CF SPI is not bridged into
    /// Swift). The representation looks like:
    ///
    ///     <CFKeyedArchiverUID 0x... [0x...]>{value = 12}
    ///
    /// Returns nil when the object is not a CFKeyedArchiverUID.
    private static func extractUIDValue(_ value: Any) -> Int? {
        let desc = String(describing: value)
        guard desc.hasPrefix("<CFKeyedArchiverUID") else { return nil }
        guard let marker = desc.range(of: "value = ") else { return nil }
        var result = 0
        var any = false
        for ch in desc[marker.upperBound...] {
            guard let d = ch.wholeNumberValue, d >= 0, d <= 9 else { break }
            result = result * 10 + d
            any = true
        }
        return any ? result : nil
    }

    // MARK: - Magic / File Discovery

    private static func validateMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == magicBytes[0]
            && data[1] == magicBytes[1]
            && data[2] == magicBytes[2]
            && data[3] == magicBytes[3]
    }

    private static func findProjectData(in logicxURL: URL) -> URL? {
        let altRoot = logicxURL.appendingPathComponent("Alternatives")
        let fm = FileManager.default
        for index in 0...9 {
            let indexStr = String(format: "%03d", index)
            let candidate = altRoot
                .appendingPathComponent(indexStr)
                .appendingPathComponent("ProjectData")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let entries = try? fm.contentsOfDirectory(atPath: altRoot.path) {
            for entry in entries.sorted() {
                let candidate = altRoot
                    .appendingPathComponent(entry)
                    .appendingPathComponent("ProjectData")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Low-level Readers

    private static func readLE64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[base + i]) << (i * 8)
        }
        return value
    }

    /// Reverse the on-disk 4-byte ID to its human-readable form.
    /// e.g. bytes `[0x4D, 0x6E, 0x65, 0x47]` -> "GenM".
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
