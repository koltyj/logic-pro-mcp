import Foundation

// MARK: - PluginComponentDecoder

/// Pure, standalone decoder for Audio Unit (AU) component identifiers embedded
/// in Logic Pro `ProjectData` binaries.
///
/// AU components are identified by three contiguous 4-character ASCII codes
/// (12 bytes total): `typeCode`, `subtypeCode`, `manufacturerCode`. These
/// triples are scattered throughout the binary — notably inside `PluginData`
/// chunks (null-ID), `AuCO` channel-strip bodies, and several other record
/// families. Rather than relying on specific chunk offsets (which vary with
/// strip layout), this decoder brute-force scans every byte offset of the
/// supplied buffer for 12 consecutive printable-ASCII bytes whose first 4
/// match a known AU type code.
///
/// The decoder is intentionally isolated from `ProjectDataParser` so it can be
/// unit-tested, reused by other tools, and evolved independently.
public enum PluginComponentDecoder {

    // MARK: - Public Types

    /// Broad category of an Audio Unit derived from its 4-character `typeCode`.
    public enum Category: String, Sendable, Codable, Hashable {
        case effect
        case instrument
        case musicEffect
        case generator
        case output
        case mixer
        case panner
        case other
    }

    /// A decoded AU component identifier. The three 4-character codes form a
    /// natural primary key and are guaranteed to be exactly 4 printable-ASCII
    /// characters each.
    public struct PluginComponent: Sendable, Codable, Hashable {
        /// AU type code (e.g. `"aufx"`, `"aumu"`, `"aumf"`, `"augn"`).
        public let typeCode: String
        /// AU subtype code (plugin-specific, e.g. `"XfOX"` for Xfer Serum).
        public let subtypeCode: String
        /// AU manufacturer code (e.g. `"appl"`, `"Xfer"`, `"FabF"`).
        public let manufacturerCode: String
        /// Category derived from `typeCode`.
        public let category: Category
        /// Friendly manufacturer name, resolved from `manufacturerCode` via the
        /// built-in registry. `nil` when the code is unknown.
        public let manufacturerName: String?

        public init(
            typeCode: String,
            subtypeCode: String,
            manufacturerCode: String,
            category: Category,
            manufacturerName: String?
        ) {
            self.typeCode = typeCode
            self.subtypeCode = subtypeCode
            self.manufacturerCode = manufacturerCode
            self.category = category
            self.manufacturerName = manufacturerName
        }
    }

    // MARK: - Public API

    /// Decode every `(typeCode, subtypeCode, manufacturerCode)` triple that
    /// appears in `data`. The returned list is deduplicated by the full triple
    /// and stably ordered by first appearance.
    public static func decode(data: Data) -> [PluginComponent] {
        // Fast paths for tiny/empty inputs.
        guard data.count >= 12 else { return [] }

        // Work on a contiguous byte buffer for predictable indexing regardless
        // of the `startIndex` of the supplied `Data`.
        let bytes = [UInt8](data)
        let count = bytes.count

        var seen = Set<Key>()
        var results: [PluginComponent] = []
        results.reserveCapacity(16)

        var i = 0
        while i + 12 <= count {
            // Reject quickly if any of the 12 candidate bytes is not printable.
            // This keeps the scanner at a single byte-compare per position for
            // the overwhelmingly common "not printable" case.
            if !Self.isPrintable(bytes[i]) {
                i += 1
                continue
            }

            // Validate the full 12-byte window.
            var allPrintable = true
            var k = 1
            while k < 12 {
                if !Self.isPrintable(bytes[i + k]) {
                    allPrintable = false
                    break
                }
                k += 1
            }
            guard allPrintable else {
                // Skip past the non-printable byte we just encountered.
                i += k + 1
                continue
            }

            let typeCode = Self.ascii(bytes, offset: i, length: 4)
            guard knownTypeCodes.contains(typeCode) else {
                i += 1
                continue
            }

            let subtypeCode = Self.ascii(bytes, offset: i + 4, length: 4)
            let manufacturerCode = Self.ascii(bytes, offset: i + 8, length: 4)

            // At least one letter in both subtype and manufacturer to filter
            // noisy all-digit / all-punctuation runs that happen to be
            // printable but are not real AU codes.
            guard Self.containsLetter(subtypeCode),
                  Self.containsLetter(manufacturerCode) else {
                i += 1
                continue
            }

            let key = Key(typeCode: typeCode, subtype: subtypeCode, manufacturer: manufacturerCode)
            if seen.insert(key).inserted {
                results.append(
                    PluginComponent(
                        typeCode: typeCode,
                        subtypeCode: subtypeCode,
                        manufacturerCode: manufacturerCode,
                        category: Self.category(forType: typeCode),
                        manufacturerName: manufacturerRegistry[manufacturerCode]
                    )
                )
            }

            // Advance by 12 to avoid re-emitting overlapping windows from the
            // same triple (overlap cannot yield a distinct valid triple here
            // because the next type code would have to start inside the
            // current subtype/manufacturer bytes, and the type-code whitelist
            // makes that astronomically unlikely — but if it does appear, the
            // dedup `seen` set handles it on the next pass).
            i += 12
        }

        return results
    }

    // MARK: - Known Codes

    /// AU type codes recognized by the scanner. Anything outside this set is
    /// rejected to keep the false-positive rate near zero.
    private static let knownTypeCodes: Set<String> = [
        "aufx",  // audio effect
        "aufc",  // audio effect (legacy variant)
        "aumu",  // music / instrument
        "aumf",  // music effect (MIDI-processing)
        "augn",  // generator
        "auou",  // output
        "aumx",  // mixer
        "aupn",  // panner
        "aupl",  // panner (legacy variant)
        "aufm",  // music format
    ]

    /// Known manufacturer codes → friendly names.
    private static let manufacturerRegistry: [String: String] = [
        "appl": "Apple",
        "Xfer": "Xfer Records",
        "NatI": "Native Instruments",
        "FabF": "FabFilter",
        "ValD": "Valhalla DSP",
        "iZot": "iZotope",
        "Slte": "Slate Digital",
        "WAVE": "Waves",
        "sfbm": "Soundtoys",
    ]

    // MARK: - Helpers

    private struct Key: Hashable {
        let typeCode: String
        let subtype: String
        let manufacturer: String
    }

    @inline(__always)
    private static func isPrintable(_ byte: UInt8) -> Bool {
        return byte >= 0x20 && byte <= 0x7E
    }

    @inline(__always)
    private static func ascii(_ bytes: [UInt8], offset: Int, length: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(length)
        var j = 0
        while j < length {
            scalars.append(Unicode.Scalar(bytes[offset + j]))
            j += 1
        }
        return String(scalars)
    }

    @inline(__always)
    private static func containsLetter(_ s: String) -> Bool {
        for ch in s where ch.isLetter {
            return true
        }
        return false
    }

    private static func category(forType typeCode: String) -> Category {
        switch typeCode {
        case "aufx", "aufc": return .effect
        case "aumu":         return .instrument
        case "aumf":         return .musicEffect
        case "augn":         return .generator
        case "auou":         return .output
        case "aumx":         return .mixer
        case "aupn", "aupl": return .panner
        default:             return .other
        }
    }
}
