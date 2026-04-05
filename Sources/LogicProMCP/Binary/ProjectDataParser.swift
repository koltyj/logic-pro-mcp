import Foundation

// MARK: - ProjectDataParser

/// Parses Logic Pro binary ProjectData files to extract arrangement markers,
/// tempo maps, track names, regions, audio files, plugins, and mixer data —
/// without using the Accessibility API.
///
/// File layout:
/// - Magic:  23 47 C0 AB  (4 bytes at offset 0)
/// - Chunk stream starting at ~0x18
///
/// Each chunk has a 36-byte header:
///   0x00  4B  ID (reversed bytes, e.g. "qSxT" on disk = "TxSq")
///   0x04  6B  metadata/flags
///   0x0A  4B  OID (LE u32)
///   0x0E  8B  padding
///   0x16  6B  anchor: 02 00 00 00 [01|02] 00
///   0x1C  8B  body length (LE u64)
///
/// Chunks are discovered by scanning for the anchor pattern.
enum ProjectDataParser {

    // MARK: - Constants

    private static let magicBytes: [UInt8] = [0x23, 0x47, 0xC0, 0xAB]
    private static let anchorPrefix: [UInt8] = [0x02, 0x00, 0x00, 0x00]
    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16          // within header
    private static let oidOffset = 0x0A             // within header
    private static let lengthOffset = 0x1C          // within header
    private static let idOffset = 0x00              // within header
    private static let ticksPerBar = 3840           // 4/4 at Logic resolution

    // Chunk IDs (as they appear after reversing the 4 on-disk bytes)
    private static let idTxSq = "TxSq"
    private static let idEvSq = "EvSq"
    private static let idMSeq = "MSeq"
    private static let idAuRg = "AuRg"
    private static let idAuFl = "AuFl"
    private static let idAuCO = "AuCO"
    private static let idTrak = "Trak"
    private static let idEnvi = "Envi"

    // Unity gain raw value for volume dB formula: dB = 40 * log10(value / unityGain)
    private static let unityGainRaw: Double = 1_509_949_440.0

    // Arrangement marker OIDs vary per project — we scan ALL TxSq chunks
    // and identify markers by RTF content rather than hardcoded OIDs

    // Tempo event signature: 7F 00 00 01 ...
    private static let tempoSignature: [UInt8] = [0x7F, 0x00, 0x00, 0x01]

    // MARK: - Public API

    /// Parse the ProjectData for a given `.logicx` bundle or raw `ProjectData` file path.
    ///
    /// - Parameter path: Either a `.logicx` directory or a raw `ProjectData` file.
    /// - Returns: Parsed `ProjectDataInfo`, or `nil` if the file cannot be found / validated.
    static func parse(path: String) -> ProjectDataInfo? {
        let url = URL(fileURLWithPath: path)
        let projectDataURL: URL
        let logicxURL: URL?

        if path.hasSuffix(".logicx") || url.pathExtension == "logicx" {
            logicxURL = url
            guard let found = findProjectData(in: url) else { return nil }
            projectDataURL = found
        } else {
            // Treat as raw ProjectData file; walk up to find .logicx for plist parsing
            projectDataURL = url
            logicxURL = findLogicxParent(of: url)
        }

        guard let data = try? Data(contentsOf: projectDataURL) else { return nil }
        guard validateMagic(data) else { return nil }

        let projectName = logicxURL.map { $0.deletingPathExtension().lastPathComponent } ?? ""

        // Scan all chunks
        let chunks = scanChunks(data: data)

        // Extract per-type maps
        let txSqMap = extractTxSqNames(chunks: chunks, data: data)       // oid -> name
        let evSqMarkerEvents = extractMarkerEvents(chunks: chunks, data: data) // [(oid, startTick, durationTicks)]
        var tempoMap = extractTempoMap(chunks: chunks, data: data)
        let (publicTracks, allTracks) = extractTracks(chunks: chunks, data: data)
        var parsedTracks = publicTracks
        var allParsedTracks = allTracks

        // If no tempo found at tick=0, try to get initial BPM from plists
        if let lx = logicxURL, !tempoMap.contains(where: { $0.tick == 0 }) {
            if let plistBPM = readBPMFromPlist(logicx: lx) {
                let initial = TempoEntry(bpm: plistBPM, tick: 0, bar: 1)
                tempoMap.insert(initial, at: 0)
            }
        }

        // Join marker names with positions
        let markers = buildMarkers(txSqMap: txSqMap, events: evSqMarkerEvents)

        // Time signature from plists
        let timeSignature = logicxURL.flatMap { readTimeSignature(logicx: $0) } ?? "4/4"
        let sampleRate = logicxURL.flatMap { readSampleRate(logicx: $0) } ?? 0

        // Extract audio file references
        let audioFiles = extractAudioFiles(chunks: chunks, data: data)

        // Extract audio regions
        var regions = extractRegions(chunks: chunks, data: data)

        // Apply track-to-region mapping (uses public tracks for OID set)
        applyTrackRegionMapping(
            chunks: chunks,
            data: data,
            tracks: &parsedTracks,
            regions: &regions
        )
        // Also apply mapping to allTracks (so hierarchy containers get region info)
        applyTrackRegionMapping(
            chunks: chunks,
            data: data,
            tracks: &allParsedTracks,
            regions: &regions
        )

        // Enrich tracks with AuCO mixer data (volume, pan, output routing)
        enrichTracksWithAuCO(chunks: chunks, data: data, tracks: &parsedTracks)
        enrichTracksWithAuCO(chunks: chunks, data: data, tracks: &allParsedTracks)

        // Infer function groups for public tracks, then propagate to children
        inferFunctionGroups(tracks: &parsedTracks)
        inferFunctionGroups(tracks: &allParsedTracks)

        // Extract plugin list
        let plugins = extractPlugins(chunks: chunks, data: data)

        // Extract Trak chunks (arrangement track → MSeq linkage)
        let trakEntries = extractTrakChunks(chunks: chunks, data: data)

        // Extract Envi environment labels (stack grouping labels)
        let environmentLabels = extractEnviNames(chunks: chunks, data: data)

        // Extract Envi OID → name map for AuCO enrichment
        let enviNameMap = extractEnviNameMap(chunks: chunks, data: data)

        // Extract all AuCO channel strips as sub-track enumeration
        var channelStrips = extractAllChannelStrips(chunks: chunks, data: data)

        // Enrich generic AuCO names with Envi environment labels
        enrichChannelStripNamesFromEnvi(strips: &channelStrips, enviNameMap: enviNameMap)

        // Wire AuCO → Trak → MSeq chain and infer function groups on strips
        linkChannelStripsToTrak(strips: &channelStrips, trakEntries: trakEntries)
        inferFunctionGroupsOnStrips(strips: &channelStrips)

        // Build full sub-track hierarchy from channel strips + environment labels
        let subTrackHierarchy = buildSubTrackHierarchy(
            strips: channelStrips,
            environmentLabels: environmentLabels
        )

        var info = ProjectDataInfo()
        info.markers = markers
        info.tempoMap = tempoMap
        info.tracks = parsedTracks
        info.allTracks = allParsedTracks
        info.regions = regions
        info.audioFiles = audioFiles
        info.plugins = plugins
        info.timeSignature = timeSignature
        info.sampleRate = sampleRate
        info.projectName = projectName
        info.channelStrips = channelStrips
        info.trakEntries = trakEntries
        info.environmentLabels = environmentLabels
        info.subTrackHierarchy = subTrackHierarchy

        // Compute per-song lengths from reference track (or marker boundary fallback)
        info.songLengths = computeSongLengthsFromReference(info: info)

        return info
    }

    // MARK: - File Discovery

    /// Find the ProjectData file inside a .logicx bundle.
    /// Scans Alternatives/000, Alternatives/001, etc.
    private static func findProjectData(in logicxURL: URL) -> URL? {
        let altRoot = logicxURL.appendingPathComponent("Alternatives")
        let fm = FileManager.default

        // Try numbered alternatives 000..009
        for index in 0...9 {
            let indexStr = String(format: "%03d", index)
            let candidate = altRoot
                .appendingPathComponent(indexStr)
                .appendingPathComponent("ProjectData")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Fallback: scan directory entries
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

    /// Walk up the directory tree from a raw ProjectData file to find the parent .logicx bundle.
    private static func findLogicxParent(of url: URL) -> URL? {
        var current = url.deletingLastPathComponent()
        for _ in 0..<5 {
            if current.pathExtension == "logicx" { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Magic Validation

    private static func validateMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x23 && data[1] == 0x47 && data[2] == 0xC0 && data[3] == 0xAB
    }

    // MARK: - Chunk Scanning

    /// Describes a located chunk.
    private struct ChunkInfo {
        let id: String      // reversed 4-char ID
        let oid: UInt32
        let bodyOffset: Int // offset within data where body begins
        let bodyLength: Int
    }

    /// Scan the entire data blob for valid chunks using the anchor-signature method.
    ///
    /// Anchor at offset 0x16 within a 36-byte header:
    ///   02 00 00 00 [01|02] 00
    ///
    /// The chunk ID is 4 bytes at the very start of the header, i.e. 0x16 bytes before
    /// the anchor.
    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let bytes = data
        let total = bytes.count
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
            // Look for anchor pattern: 02 00 00 00 [01 or 02] 00
            // We scan byte-by-byte; for performance we look for 0x02 first.
            guard bytes[offset + anchorOffset] == 0x02,
                  bytes[offset + anchorOffset + 1] == 0x00,
                  bytes[offset + anchorOffset + 2] == 0x00,
                  bytes[offset + anchorOffset + 3] == 0x00,
                  (bytes[offset + anchorOffset + 4] == 0x01 || bytes[offset + anchorOffset + 4] == 0x02),
                  bytes[offset + anchorOffset + 5] == 0x00
            else {
                offset += 1
                continue
            }

            // Looks like an anchor; read length field
            let bodyLength = Int(readLE64(data, at: offset + lengthOffset))
            let bodyStart = offset + chunkHeaderSize

            // Validate bounds
            guard bodyLength >= 0,
                  bodyStart + bodyLength <= total
            else {
                offset += 1
                continue
            }

            // Read 4-byte ID (reversed)
            let rawID = Array(bytes[offset..<(offset + 4)])
            let id = reverseID(rawID)

            // Read OID
            let oid = readLE32(data, at: offset + oidOffset)

            result.append(ChunkInfo(
                id: id,
                oid: oid,
                bodyOffset: bodyStart,
                bodyLength: bodyLength
            ))

            // Advance past this chunk
            offset = bodyStart + bodyLength
        }
        return result
    }

    // MARK: - TxSq Name Extraction

    /// Extract RTF text from ALL TxSq chunks.
    /// Returns a map of OID -> cleaned name.
    /// Marker OIDs vary per project, so we extract everything and let the
    /// EvSq type-18 join determine which are actual arrangement markers.
    private static func extractTxSqNames(chunks: [ChunkInfo], data: Data) -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        for chunk in chunks where chunk.id == idTxSq {
            guard chunk.bodyLength > 0 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            if let name = extractRTFText(body) {
                result[chunk.oid] = name
            }
        }
        return result
    }

    /// Extract plain text from an RTF body.
    /// Logic TxSq RTF typically has content after `\fs24` tag.
    /// Strategy: decode as ASCII (ignoring non-printable), find `\fs24 ` or similar,
    /// then extract the text between that and the closing `}`.
    private static func extractRTFText(_ body: Data) -> String? {
        // Decode as ASCII, replacing non-printable with dots
        let asciiStr = String(body.map { b -> Character in
            let s = Unicode.Scalar(b)
            return s.value >= 32 && s.value < 127 ? Character(s) : Character(".")
        })

        // Must contain RTF marker
        guard asciiStr.contains("{\\rtf") || asciiStr.contains("\\fs") else {
            return extractDirectString(body)
        }

        // Find content after \fs<N> (font size tag) — the actual text follows
        // Pattern: \fs24 <space or \cf2> TEXT}
        if let fsRange = asciiStr.range(of: "\\fs", options: .literal) {
            // Skip past the font size number
            var idx = fsRange.upperBound
            while idx < asciiStr.endIndex && (asciiStr[idx].isNumber) {
                idx = asciiStr.index(after: idx)
            }
            // Skip whitespace and \cf2 color tags
            var textStart = idx
            while textStart < asciiStr.endIndex {
                if asciiStr[textStart] == " " {
                    textStart = asciiStr.index(after: textStart)
                    continue
                }
                if asciiStr[textStart] == "\\" {
                    // Skip control word
                    var j = asciiStr.index(after: textStart)
                    while j < asciiStr.endIndex && (asciiStr[j].isLetter || asciiStr[j].isNumber) {
                        j = asciiStr.index(after: j)
                    }
                    if j < asciiStr.endIndex && asciiStr[j] == " " {
                        j = asciiStr.index(after: j)
                    }
                    textStart = j
                    continue
                }
                break
            }

            // Extract text until closing brace
            var textEnd = textStart
            while textEnd < asciiStr.endIndex && asciiStr[textEnd] != "}" {
                textEnd = asciiStr.index(after: textEnd)
            }

            if textStart < textEnd {
                var text = String(asciiStr[textStart..<textEnd])
                // Clean up: remove stray dots, trim
                text = text.replacingOccurrences(of: "..", with: " ")
                text = text.replacingOccurrences(of: ".", with: "")
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Remove leading/trailing non-alphanumeric
                while let c = text.first, !c.isLetter && !c.isNumber {
                    text.removeFirst()
                }
                while let c = text.last, !c.isLetter && !c.isNumber {
                    text.removeLast()
                }
                return text.isEmpty ? nil : text
            }
        }

        return nil
    }

    /// Fallback: try to read a length-prefixed ASCII string from raw body bytes.
    private static func extractDirectString(_ body: Data) -> String? {
        guard body.count >= 3 else { return nil }
        // Check for 2-byte LE length prefix
        let len = Int(body[0]) | (Int(body[1]) << 8)
        if len > 0 && len < body.count - 2 {
            if let s = String(data: body[2..<(2 + len)], encoding: .utf8) {
                let cleaned = s.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        return nil
    }

    // MARK: - EvSq Marker Event Extraction

    struct MarkerEvent {
        let oid: UInt32
        let startTick: UInt32
        let durationTicks: UInt32
    }

    /// Scan EvSq chunks for type-18 triplet sequences that encode arrangement marker positions.
    ///
    /// Per spec, small EvSq(oid=0) chunks contain 16-byte aligned triplets:
    ///   head:   [u32=18, u32=start_tick, u32=0, ...]
    ///   marker: [u32=marker_oid, u32=0x88000000, u32=marker_type, u32=duration_ticks]
    ///   tail:   [u32=0, u32=0x88000000, u32=0, u32=0]
    private static func extractMarkerEvents(chunks: [ChunkInfo], data: Data) -> [MarkerEvent] {
        var result: [MarkerEvent] = []

        for chunk in chunks where chunk.id == idEvSq {
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            let events = parseType18Triplets(body: body)
            result.append(contentsOf: events)
        }

        // Deduplicate by OID, keeping first occurrence
        var seen = Set<UInt32>()
        var deduped: [MarkerEvent] = []
        for e in result {
            if seen.insert(e.oid).inserted {
                deduped.append(e)
            }
        }
        return deduped
    }

    /// Parse type-18 triplets from an EvSq body.
    private static func parseType18Triplets(body: Data) -> [MarkerEvent] {
        var events: [MarkerEvent] = []
        // Rebase to 0-based
        let body = Data(body)
        let count = body.count / 16
        guard count >= 3 else { return events }

        var i = 0
        while i + 2 < count {
            let headOffset = i * 16
            let markerOffset = (i + 1) * 16
            let tailOffset = (i + 2) * 16

            guard headOffset + 16 <= body.count,
                  markerOffset + 16 <= body.count,
                  tailOffset + 16 <= body.count
            else { break }

            let h0 = readLE32(body, at: headOffset + 0)
            let h1 = readLE32(body, at: headOffset + 4)

            let m0 = readLE32(body, at: markerOffset + 0)
            let m1 = readLE32(body, at: markerOffset + 4)
            let m3 = readLE32(body, at: markerOffset + 12)

            let t0 = readLE32(body, at: tailOffset + 0)
            let t1 = readLE32(body, at: tailOffset + 4)

            // Check triplet pattern:
            // head[0] == 18, marker[1] == 0x88000000, tail[0] == 0, tail[1] == 0x88000000
            if h0 == 18
                && m1 == 0x88000000
                && t0 == 0
                && t1 == 0x88000000
            {
                events.append(MarkerEvent(oid: m0, startTick: h1, durationTicks: m3))
                i += 3
                continue
            }
            i += 1
        }
        return events
    }

    // MARK: - Tempo Map Extraction

    /// Extract tempo events from EvSq chunks using multiple strategies:
    ///   1. Standard 7F 00 00 01 signature (existing method)
    ///   2. Type-96 tempo bridge: row A [96, seq_tick, 0, 0x0100007F|0x8100007F],
    ///      row B [tempo_raw, 0x88400000, tempo_tick_abs, 0]
    private static func extractTempoMap(chunks: [ChunkInfo], data: Data) -> [TempoEntry] {
        var entries: [TempoEntry] = []

        for chunk in chunks where chunk.id == idEvSq {
            guard chunk.bodyLength >= 20 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // Strategy 1: standard 7F 00 00 01 signature
            let standardTempos = parseTempoEvents(body: body)
            entries.append(contentsOf: standardTempos)

            // Strategy 2: type-96 bridge (16-byte aligned pairs)
            let bridgeTempos = parseType96TempoEvents(body: body)
            entries.append(contentsOf: bridgeTempos)
        }

        // Sort by tick and deduplicate
        entries.sort { $0.tick < $1.tick }
        var seen = Set<Int>()
        return entries.filter { seen.insert($0.tick).inserted }
    }

    private static func parseTempoEvents(body: Data) -> [TempoEntry] {
        var entries: [TempoEntry] = []
        // Rebase slice to 0-based indices so direct subscript access works
        let bytes = Data(body)
        let total = bytes.count
        var offset = 0

        while offset + 20 <= total {
            // Look for tempo signature: 7F 00 00 01
            guard bytes[offset] == 0x7F,
                  bytes[offset + 1] == 0x00,
                  bytes[offset + 2] == 0x00,
                  bytes[offset + 3] == 0x01
            else {
                offset += 1
                continue
            }

            // Read millitempo (4 bytes LE at offset+4)
            let milliTempo = readLE32(body, at: offset + 4)
            guard milliTempo > 0 else { offset += 1; continue }

            // Read tick position (8 bytes LE at offset+12, but we use low 4 bytes for now)
            let tickLow = readLE32(body, at: offset + 12)
            let tickHigh = readLE32(body, at: offset + 16)
            let tick = Int(tickLow) | (Int(tickHigh) << 32)

            let bpm = Double(milliTempo) / 10000.0
            guard bpm > 10.0 && bpm < 1000.0 else { offset += 4; continue }

            let bar = tick / ticksPerBar + 1
            entries.append(TempoEntry(bpm: bpm, tick: tick, bar: bar))
            offset += 20
        }
        return entries
    }

    /// Parse type-96 tempo bridge format from EvSq body.
    ///
    /// Format (16-byte aligned rows):
    ///   row A: [u32=96, u32=sequence_tick, u32=0, u32=0x0100007F or 0x8100007F]
    ///   row B: [u32=tempo_raw, u32=0x88400000, u32=tempo_tick_abs, u32=0]
    ///   tempo_raw = BPM * 10000
    private static func parseType96TempoEvents(body: Data) -> [TempoEntry] {
        var entries: [TempoEntry] = []
        let bytes = Data(body)
        let count = bytes.count / 16
        guard count >= 2 else { return entries }

        var i = 0
        while i + 1 < count {
            let aOff = i * 16
            let bOff = (i + 1) * 16

            guard aOff + 16 <= bytes.count, bOff + 16 <= bytes.count else { break }

            let a0 = readLE32(bytes, at: aOff + 0)   // should be 96
            let a3 = readLE32(bytes, at: aOff + 12)  // should be 0x0100007F or 0x8100007F

            // Row A signature check
            guard a0 == 96,
                  (a3 == 0x0100007F || a3 == 0x8100007F)
            else {
                i += 1
                continue
            }

            let b0 = readLE32(bytes, at: bOff + 0)   // tempo_raw = BPM * 10000
            let b1 = readLE32(bytes, at: bOff + 4)   // should be 0x88400000
            let b2 = readLE32(bytes, at: bOff + 8)   // tempo_tick_abs
            // b3 should be 0

            guard b1 == 0x88400000, b0 > 0 else {
                i += 1
                continue
            }

            let bpm = Double(b0) / 10000.0
            guard bpm > 10.0 && bpm < 1000.0 else {
                i += 1
                continue
            }

            let tick = Int(b2)
            let bar = tick / ticksPerBar + 1
            entries.append(TempoEntry(bpm: bpm, tick: tick, bar: bar))
            i += 2  // consumed both rows
        }
        return entries
    }

    // MARK: - Track Name Extraction (MSeq)

    /// Raw record returned from MSeq parsing before filtering / hierarchy building.
    private struct RawMSeqTrack {
        let oid: UInt32
        let name: String        // may be empty / generic
        let parentOid: UInt32   // 0 = no parent
    }

    /// Extract ALL MSeq tracks including internal ones.
    ///
    /// MSeq body layout:
    ///   0x08  4B  parent OID (LE u32) — 0 means no parent
    ///   0x10  2B  name_length (LE u16)
    ///   0x12  *B  name (ASCII)
    private static func extractAllMSeqTracks(chunks: [ChunkInfo], data: Data) -> [RawMSeqTrack] {
        var result: [RawMSeqTrack] = []
        var seen = Set<UInt32>()

        for chunk in chunks where chunk.id == idMSeq {
            guard chunk.bodyLength > 0x12 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            guard body.count > 0x12 else { continue }

            // Parent OID at 0x08
            let parentOid = body.count >= 0x0C ? readLE32(body, at: 0x08) : 0

            // Name
            let nameLen = Int(readLE16(body, at: 0x10))
            var name = ""
            if nameLen > 0, 0x12 + nameLen <= body.count {
                name = (String(data: body[0x12..<(0x12 + nameLen)], encoding: .utf8)
                    ?? String(data: body[0x12..<(0x12 + nameLen)], encoding: .isoLatin1)
                    ?? "")
                    .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            }

            if seen.insert(chunk.oid).inserted {
                result.append(RawMSeqTrack(oid: chunk.oid, name: name, parentOid: parentOid))
            }
        }
        return result
    }

    /// Build ParsedTrack array from raw MSeq records.
    /// Returns (publicTracks, allTracks) where:
    ///   - allTracks: every MSeq entry
    ///   - publicTracks: non-automation named tracks PLUS any track with children (stack containers)
    private static func extractTracks(chunks: [ChunkInfo], data: Data) -> (public: [ParsedTrack], all: [ParsedTrack]) {
        let raw = extractAllMSeqTracks(chunks: chunks, data: data)
        guard !raw.isEmpty else { return ([], []) }

        // Build OID -> index map
        var oidToIndex: [UInt32: Int] = [:]
        for (i, r) in raw.enumerated() {
            oidToIndex[r.oid] = i
        }

        // Build hierarchy: parentOid -> [childOids]
        var childrenOf: [UInt32: [UInt32]] = [:]
        for r in raw {
            guard r.parentOid != 0, r.parentOid != r.oid else { continue }
            // Validate parent exists
            guard oidToIndex[r.parentOid] != nil else { continue }
            childrenOf[r.parentOid, default: []].append(r.oid)
        }

        // Compute stack depth via BFS from roots
        var depth: [UInt32: Int] = [:]
        var queue: [(oid: UInt32, d: Int)] = []
        for r in raw {
            let hasValidParent = r.parentOid != 0 && oidToIndex[r.parentOid] != nil
            if !hasValidParent {
                depth[r.oid] = 0
                queue.append((r.oid, 0))
            }
        }
        var qi = 0
        while qi < queue.count {
            let (oid, d) = queue[qi]; qi += 1
            for child in childrenOf[oid] ?? [] {
                depth[child] = d + 1
                queue.append((child, d + 1))
            }
        }

        // Classify stack type based on name keywords + output routing
        func classifyStack(name: String, outputRouting: String?) -> (type: String?, isSumming: Bool) {
            let lower = name.lowercased()
            if lower.contains("summing") && lower.contains("stack") {
                return ("summing", true)
            }
            if lower.contains("folder stack") || lower.contains("track automation root folder") {
                return ("folder", false)
            }
            if let out = outputRouting?.lowercased() {
                if out.hasPrefix("bus ") { return ("summing", true) }
                if out.hasPrefix("output ") || out.contains("stereo out") { return (nil, false) }
            }
            // Has children → treat as stack
            return (nil, false)
        }

        // Build ParsedTrack array (all)
        let allTracks: [ParsedTrack] = raw.map { r in
            let children = (childrenOf[r.oid] ?? []).map { Int($0) }.sorted()
            let d = depth[r.oid] ?? 0
            let hasParent = r.parentOid != 0 && oidToIndex[r.parentOid] != nil
            let (sType, isSumming) = classifyStack(name: r.name, outputRouting: nil)
            var track = ParsedTrack(name: r.name.isEmpty ? "Untitled" : r.name, oid: Int(r.oid))
            track.parentOid = hasParent ? Int(r.parentOid) : nil
            track.childOids = children
            track.stackDepth = d
            track.stackType = children.isEmpty ? sType : (sType ?? (children.isEmpty ? nil : "summing"))
            track.isSummingStack = isSumming || (!children.isEmpty && (sType == "summing"))
            return track
        }

        // Public filter: named non-automation tracks + any track with children (stack containers)
        let publicTracks = allTracks.filter { track in
            let hasChildren = !track.childOids.isEmpty
            let isAutomation = track.name.hasPrefix("*Automation") || track.name.hasPrefix("Track Automation")
            let isUntitled = track.name == "Untitled"
            if isAutomation { return false }
            if isUntitled { return hasChildren }
            return true
        }

        return (publicTracks, allTracks)
    }

    // MARK: - Audio File References (AuFl)

    /// Extract audio file paths from AuFl chunks.
    ///
    /// AuFl body layout:
    ///   0x08  2B  character count (LE u16) — number of UTF-16 code units
    ///   0x0A  *B  UTF-16LE encoded file path (char_count * 2 bytes)
    ///
    /// Note: the spec says "starts at offset 0x0A"; the char count at 0x08 gives
    /// the exact length, avoiding ambiguity with null-terminator detection.
    private static func extractAudioFiles(chunks: [ChunkInfo], data: Data) -> [ParsedAudioFile] {
        var result: [ParsedAudioFile] = []
        var seen = Set<UInt32>()

        for chunk in chunks where chunk.id == idAuFl {
            guard chunk.bodyLength > 0x0C else { continue }
            if !seen.insert(chunk.oid).inserted { continue }

            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // Read char count at 0x08 (LE u16 = number of UTF-16 code units)
            let charCount = Int(readLE16(body, at: 0x08))
            let byteCount = charCount * 2
            let pathOffset = 0x0A

            if charCount > 0, pathOffset + byteCount <= body.count {
                // Use length-prefixed decode (most reliable)
                let pathSlice = Data(body[pathOffset..<(pathOffset + byteCount)])
                if let path = String(data: pathSlice, encoding: .utf16LittleEndian), !path.isEmpty {
                    result.append(ParsedAudioFile(path: path, oid: Int(chunk.oid)))
                    continue
                }
            }

            // Fallback: null-terminator scan for UTF-16LE
            guard body.count > pathOffset + 2 else { continue }
            let pathData = Data(body[pathOffset...])
            var pathEnd = 0
            while pathEnd + 1 < pathData.count {
                if pathData[pathEnd] == 0 && pathData[pathEnd + 1] == 0 { break }
                pathEnd += 2
            }
            guard pathEnd > 0 else { continue }
            let utf16Slice = Data(pathData[0..<pathEnd])
            if let path = String(data: utf16Slice, encoding: .utf16LittleEndian), !path.isEmpty {
                result.append(ParsedAudioFile(path: path, oid: Int(chunk.oid)))
            }
        }
        return result
    }

    // MARK: - Audio Region Extraction (AuRg)

    /// Extract audio regions from AuRg chunks.
    ///
    /// AuRg body layout:
    ///   0x30  8B  legacy start tick (LE u64) — tried FIRST
    ///   0x10  4B  start_bar_int (LE u32)     — bar-field fallback
    ///   0x14  4B  start_bar_frac_hi (LE u32) — fractional bars: frac = (value >> 16) / 65536
    ///   0x18  4B  length_bar_int (LE u32)
    ///   0x1C  4B  length_bar_frac_hi (LE u32)
    ///   0x4A  2B  name_length (LE u16)
    ///   0x4C  *B  name (ASCII)
    ///
    /// The AuRg OID matches the AuFl OID that owns this audio asset.
    private static func extractRegions(chunks: [ChunkInfo], data: Data) -> [ParsedRegion] {
        var result: [ParsedRegion] = []

        for chunk in chunks where chunk.id == idAuRg {
            guard chunk.bodyLength > 0x4C else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // --- Timeline placement ---
            var startBar: Double = 0
            var lengthBars: Double = 0
            var startTick: Int = 0
            var lengthTicks: Int = 0

            // Bug 3 Fix: Try legacy tick mode FIRST.
            // 8-byte LE tick at body offset 0x30; bar = tick / 3840 + 1.
            // Accept if bar is in reasonable range (1-5000).
            // Only fall back to bar-field mode if legacy gives 0 or unreasonable values.
            var usedLegacy = false
            if body.count >= 0x38 {
                // Read full 8-byte LE tick at 0x30
                let rawStartTick = Int(readLE64(body, at: 0x30))
                let legacyBar = rawStartTick / ticksPerBar + 1
                if rawStartTick > 0 && legacyBar >= 1 && legacyBar <= 5000 {
                    startTick = rawStartTick
                    startBar = Double(rawStartTick) / Double(ticksPerBar) + 1.0
                    // Length at 0x38 (8-byte LE tick)
                    if body.count >= 0x40 {
                        let rawLenTick = Int(readLE64(body, at: 0x38))
                        lengthTicks = rawLenTick
                        lengthBars = Double(rawLenTick) / Double(ticksPerBar)
                    } else if body.count >= 0x3C {
                        let rawLenLow = readLE32(body, at: 0x38)
                        lengthTicks = Int(rawLenLow)
                        lengthBars = Double(lengthTicks) / Double(ticksPerBar)
                    }
                    usedLegacy = true
                } else if rawStartTick > 0 {
                    // Tick is non-zero but bar is out of range — check for large pre-roll offset.
                    // Some projects encode absolute timeline ticks; subtract any offset > 5000 bars.
                    // If after subtracting some pre-roll the bar lands in 1-5000, accept it.
                    let barsFromZero = rawStartTick / ticksPerBar
                    if barsFromZero > 5000 {
                        // Try bar-field below — don't use this tick value
                    } else if legacyBar > 5000 {
                        // legacyBar > 5000: bar-field will be tried below
                    }
                }
            }

            if !usedLegacy {
                // Bar-field mode fallback: offsets 0x10..0x1F
                let startBarInt = readLE32(body, at: 0x10)
                let startBarFracRaw = readLE32(body, at: 0x14)
                let lengthBarInt = readLE32(body, at: 0x18)
                let lengthBarFracRaw = readLE32(body, at: 0x1C)

                let startBarFrac = Double(startBarFracRaw >> 16) / 65536.0
                let lengthBarFrac = Double(lengthBarFracRaw >> 16) / 65536.0

                let candidateBar = Double(startBarInt) + startBarFrac
                // Validate bar-field values — reject if out of reasonable range
                if (startBarInt > 0 || startBarFrac > 0) && candidateBar <= 5000.0 {
                    startBar = candidateBar
                    lengthBars = Double(lengthBarInt) + lengthBarFrac
                    startTick = Int((startBar - 1.0) * Double(ticksPerBar))
                    lengthTicks = Int(lengthBars * Double(ticksPerBar))
                }
            }

            // --- Region name ---
            let nameLen = Int(readLE16(body, at: 0x4A))
            guard nameLen > 0, 0x4C + nameLen <= body.count else {
                // Still add a region with empty name if timing data is valid
                if startTick > 0 || startBar > 0 {
                    result.append(ParsedRegion(
                        name: "",
                        oid: Int(chunk.oid),
                        startTick: startTick,
                        startBar: startBar,
                        lengthTicks: lengthTicks,
                        lengthBars: lengthBars,
                        audioFileOid: Int(chunk.oid),
                        trackOid: nil
                    ))
                }
                continue
            }

            let nameSlice = Data(body[0x4C..<(0x4C + nameLen)])
            let name = String(data: nameSlice, encoding: .utf8)
                ?? String(data: nameSlice, encoding: .isoLatin1)
                ?? ""

            result.append(ParsedRegion(
                name: name,
                oid: Int(chunk.oid),
                startTick: startTick,
                startBar: startBar,
                lengthTicks: lengthTicks,
                lengthBars: lengthBars,
                audioFileOid: Int(chunk.oid),
                trackOid: nil
            ))
        }

        return result
    }

    // MARK: - Track-to-Region Mapping

    /// Populate trackOid on regions and regions list on tracks.
    ///
    /// Two-source approach (priority order):
    ///   1. **Trak body scan** (primary): Trak chunk bodies may contain AuRg OIDs after the
    ///      fixed header fields. Scan from offset 0x2C onwards for u32 values matching known
    ///      region OIDs and build trakOid → [regionOid] mapping.
    ///   2. **AuRg body offset heuristic** (fallback): Group AuRg bodies by length, find the
    ///      offset where track OIDs appear most frequently, use that to read trackOid per region.
    ///
    /// Regions are matched to AuRg chunk bodies by composite key (oid, startTick) rather than
    /// sequential index, avoiding drift when extractRegions skips chunks with no timing/name.
    private static func applyTrackRegionMapping(
        chunks: [ChunkInfo],
        data: Data,
        tracks: inout [ParsedTrack],
        regions: inout [ParsedRegion]
    ) {
        let trackOidSet = Set(tracks.map { UInt32($0.oid) })
        guard !trackOidSet.isEmpty, !regions.isEmpty else { return }

        // Build region lookup by composite key (oid, startTick) for robust chunk↔region matching.
        // When multiple regions share a key, store the first unmatched index.
        struct RegionKey: Hashable { let oid: Int; let startTick: Int }
        var regionLookup: [RegionKey: [Int]] = [:]
        for (i, r) in regions.enumerated() {
            regionLookup[RegionKey(oid: r.oid, startTick: r.startTick), default: []].append(i)
        }
        // Track which indices have been consumed (for duplicate keys)
        var consumedIndices = Set<Int>()

        func findRegionIndex(oid: Int, startTick: Int) -> Int? {
            let key = RegionKey(oid: oid, startTick: startTick)
            guard let indices = regionLookup[key] else { return nil }
            for idx in indices where !consumedIndices.contains(idx) {
                consumedIndices.insert(idx)
                return idx
            }
            return nil
        }

        // Collect all region OIDs for Trak body scanning
        let regionOidSet = Set(regions.map { UInt32($0.oid) })

        // --- Source 1: Trak body scan ---
        // Trak bodies have fixed fields at 0x00-0x2B. Any u32 values from 0x2C onwards
        // that match known AuRg OIDs are region references owned by that track.
        var trakRegionOids: [UInt32: Set<UInt32>] = [:]  // trakOid → {regionOid}
        for chunk in chunks where chunk.id == idTrak {
            guard chunk.bodyLength > 0x30 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            var foundRegionOids = Set<UInt32>()
            // Scan u32 values from offset 0x2C to end of body
            var off = 0x2C
            while off + 4 <= body.count {
                let val = readLE32(body, at: off)
                if val != 0 && regionOidSet.contains(val) {
                    foundRegionOids.insert(val)
                }
                off += 4
            }
            if !foundRegionOids.isEmpty {
                trakRegionOids[chunk.oid] = foundRegionOids
            }
        }

        // Apply Trak-based mapping: Trak.oid maps to MSeq via trakEntries,
        // and we need the MSeq OID (which is what ParsedTrack.oid uses).
        // Build Trak OID → MSeq OID map from Trak chunks.
        var trakToMSeq: [UInt32: UInt32] = [:]
        for chunk in chunks where chunk.id == idTrak {
            guard chunk.bodyLength >= 0x0C else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])
            let mseqOid = readLE32(body, at: 0x08)
            if mseqOid != 0 {
                trakToMSeq[chunk.oid] = mseqOid
            }
        }

        // Assign regions from Trak body scan
        for (trakOid, regOids) in trakRegionOids {
            let mseqOid = trakToMSeq[trakOid] ?? trakOid
            guard trackOidSet.contains(mseqOid) else { continue }
            for regOid in regOids {
                // Mark all regions with this OID as belonging to this track
                for i in regions.indices where regions[i].oid == Int(regOid) && regions[i].trackOid == nil {
                    regions[i].trackOid = Int(mseqOid)
                }
            }
        }

        // --- Source 2: AuRg body offset heuristic (fallback for unmapped regions) ---

        let candidateOffsets: [Int] = [0x00, 0x04, 0x08, 0x0C, 0x60, 0x64, 0x68,
                                       0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28,
                                       0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40, 0x44,
                                       0x48, 0x4C, 0x50, 0x54, 0x58, 0x5C,
                                       0x6C, 0x70, 0x74, 0x78, 0x7C]

        // Collect AuRg (body, regionIdx) pairs using composite key matching
        // instead of sequential index, avoiding drift from skipped chunks.
        var aurgBodies: [(body: Data, regionIdx: Int)] = []
        for chunk in chunks where chunk.id == idAuRg {
            guard chunk.bodyLength > 0x4C else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // Extract timing to compute composite key (same logic as extractRegions)
            var startTick = 0
            if body.count >= 0x38 {
                let rawStartTick = Int(readLE64(body, at: 0x30))
                let legacyBar = rawStartTick / ticksPerBar + 1
                if rawStartTick > 0 && legacyBar >= 1 && legacyBar <= 5000 {
                    startTick = rawStartTick
                }
            }
            if startTick == 0 {
                let startBarInt = readLE32(body, at: 0x10)
                let startBarFracRaw = readLE32(body, at: 0x14)
                let startBarFrac = Double(startBarFracRaw >> 16) / 65536.0
                let candidateBar = Double(startBarInt) + startBarFrac
                if (startBarInt > 0 || startBarFrac > 0) && candidateBar <= 5000.0 {
                    startTick = Int((candidateBar - 1.0) * Double(ticksPerBar))
                }
            }

            if let regIdx = findRegionIndex(oid: Int(chunk.oid), startTick: startTick) {
                aurgBodies.append((body: body, regionIdx: regIdx))
            }
        }

        // Only process regions not yet mapped by Trak scan
        let unmappedBodies = aurgBodies.filter { regions[$0.regionIdx].trackOid == nil }
        guard !unmappedBodies.isEmpty else {
            // All mapped by Trak scan — just build cross-reference and return
            buildTrackRegionCrossRef(tracks: &tracks, regions: regions)
            return
        }

        // Group unmapped by body length
        var byLength: [Int: [(body: Data, regionIdx: Int)]] = [:]
        for entry in unmappedBodies {
            byLength[entry.body.count, default: []].append(entry)
        }

        // Pass 1: for each length group, count track OID hits per candidate offset
        var bestOffsetByLength: [Int: Int] = [:]
        for (_, group) in byLength {
            let total = group.count
            guard total > 0 else { continue }

            var hitCounts: [Int: Int] = [:]
            for entry in group {
                let maxScan = min(entry.body.count, 0xC0)
                for off in candidateOffsets where off + 4 <= maxScan {
                    let val = readLE32(entry.body, at: off)
                    if trackOidSet.contains(val) && val != 0 {
                        hitCounts[off, default: 0] += 1
                    }
                }
            }

            let filtered = hitCounts.filter { $0.value * 20 >= total * 3 || $0.value >= 2 }
            if let best = filtered.max(by: { $0.value < $1.value }) {
                let len = group.first?.body.count ?? 0
                bestOffsetByLength[len] = best.key
            }
        }

        // Pass 2: wider scan for groups with no good offset
        for (len, group) in byLength {
            guard bestOffsetByLength[len] == nil else { continue }
            let total = group.count
            guard total >= 1 else { continue }

            var hitCounts: [Int: Int] = [:]
            for entry in group {
                let maxScan = min(entry.body.count, 0xC0)
                for off in stride(from: 0, to: maxScan - 3, by: 4) {
                    let val = readLE32(entry.body, at: off)
                    if trackOidSet.contains(val) && val != 0 {
                        hitCounts[off, default: 0] += 1
                    }
                }
            }

            if let best = hitCounts.max(by: { $0.value < $1.value }), best.value > 0 {
                bestOffsetByLength[len] = best.key
            }
        }

        // Assign track OIDs to unmapped regions
        for entry in unmappedBodies {
            let len = entry.body.count
            guard let bestOff = bestOffsetByLength[len], bestOff + 4 <= len else { continue }
            let val = readLE32(entry.body, at: bestOff)
            guard trackOidSet.contains(val), val != 0 else { continue }
            regions[entry.regionIdx].trackOid = Int(val)
        }

        // Build track -> regions cross-reference
        buildTrackRegionCrossRef(tracks: &tracks, regions: regions)
    }

    /// Build track.regions arrays from region.trackOid assignments.
    private static func buildTrackRegionCrossRef(
        tracks: inout [ParsedTrack],
        regions: [ParsedRegion]
    ) {
        var trackRegionMap: [Int: [ParsedRegion]] = [:]
        for region in regions {
            if let tOid = region.trackOid {
                trackRegionMap[tOid, default: []].append(region)
            }
        }
        for i in tracks.indices {
            if let regs = trackRegionMap[tracks[i].oid] {
                tracks[i].regions = regs
            }
        }
    }

    // MARK: - AuCO Mixer Data (Volume, Pan, Output Routing)

    /// Enrich tracks with volume, pan, and output routing from AuCO chunks.
    ///
    /// AuCO body layout:
    ///   0x3C  null-terminated ASCII  channel strip name
    ///   0x59  1B                     pan byte (0=hard left, 64=center, 127=hard right)
    ///   volume: 4-byte LE u32 at a known offset; unity = 1509949440
    ///
    /// Bug 2 Fix: Match AuCO to track by OID (exact match first, then nearest within +/- 8),
    /// because AuCO strip names are generic ("Audio 1") and don't match MSeq track names.
    private static func enrichTracksWithAuCO(
        chunks: [ChunkInfo],
        data: Data,
        tracks: inout [ParsedTrack]
    ) {
        // Build OID -> track index map for direct OID matching
        var trackByOid: [UInt32: Int] = [:]
        for (i, t) in tracks.enumerated() {
            trackByOid[UInt32(t.oid)] = i
        }
        let sortedTrackOids = tracks.map { UInt32($0.oid) }.sorted()

        for chunk in chunks where chunk.id == idAuCO {
            guard chunk.bodyLength > 0x5A else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // --- Pan byte at 0x59 ---
            let panByte = Int(body[0x59])
            let panNorm: Double = (Double(panByte) - 64.0) / 64.0  // -1.0 to +1.0

            // --- Volume ---
            let volumeDB = readVolumeDB(body: body)

            // --- Output routing ---
            let outputRouting = extractOutputRouting(body: body)

            // --- Bug 2 Fix: Match by OID (exact first, then nearest within +/- 8) ---
            let aucoOid = chunk.oid
            var trackIdx: Int? = nil

            // Exact OID match
            if let idx = trackByOid[aucoOid] {
                trackIdx = idx
            } else {
                // Nearest track OID within +/- 8
                var bestDist: UInt32 = 9
                for tOid in sortedTrackOids {
                    let dist = aucoOid > tOid ? aucoOid - tOid : tOid - aucoOid
                    if dist < bestDist {
                        bestDist = dist
                        trackIdx = trackByOid[tOid]
                    }
                }
            }

            if let idx = trackIdx {
                tracks[idx].volume = volumeDB
                tracks[idx].pan = panNorm.clamped(to: -1.0...1.0)
                if let routing = outputRouting {
                    tracks[idx].outputRouting = routing
                }
            }
        }
    }

    /// Read null-terminated ASCII string from body at given offset.
    private static func readNullTerminatedASCII(_ body: Data, at offset: Int, maxLen: Int) -> String {
        guard offset < body.count else { return "" }
        var end = offset
        let limit = min(body.count, offset + maxLen)
        while end < limit && body[end] != 0 {
            end += 1
        }
        guard end > offset else { return "" }
        let raw = String(data: Data(body[offset..<end]), encoding: .ascii) ?? ""
        // Trim leading/trailing whitespace (Logic sometimes stores " Audio 1" with a leading space)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scan AuCO body for volume raw value. Returns dB, or nil if no plausible value found.
    ///
    /// Unity gain = 1509949440 (0x5A000080 LE).
    /// Formula: dB = 40 * log10(value / 1509949440)
    ///
    /// Bug 2 Fix: Broader offset scan so volume is found across all AuCO body lengths.
    /// We check known offsets first, then fall back to scanning every 4 bytes.
    private static func readVolumeDB(body: Data) -> Double? {
        // Per spec unity = 1509949440; check known offsets for all observed body lengths
        let searchOffsets = [0x74, 0x48, 0x4C, 0x50, 0x54, 0x58, 0x64, 0x68, 0x6C, 0x70,
                             0x78, 0x7C, 0x80, 0x84, 0x88, 0x8C, 0x90, 0x94, 0x40, 0x44]
        for off in searchOffsets {
            guard off + 4 <= body.count else { continue }
            let raw = readLE32(body, at: off)
            guard raw > 0 else { continue }
            let ratio = Double(raw) / unityGainRaw
            guard ratio > 0 else { continue }
            let db = 40.0 * log10(ratio)
            if db >= -144.0 && db <= 24.0 {
                return db
            }
        }
        // Fallback: scan every 4 bytes for a value that decodes to a plausible volume
        // Accept values within ±18 dB of unity as most likely volume faders
        var i = 0x40
        while i + 4 <= body.count && i <= 0xC0 {
            let raw = readLE32(body, at: i)
            if raw > 0 {
                let ratio = Double(raw) / unityGainRaw
                if ratio > 0 {
                    let db = 40.0 * log10(ratio)
                    if db >= -18.0 && db <= 6.0 {
                        return db
                    }
                }
            }
            i += 4
        }
        return nil
    }

    /// Scan an AuCO body for output routing label strings.
    private static func extractOutputRouting(body: Data) -> String? {
        // Build a null-byte-preserving ASCII representation
        let bytes = body

        let keywords = ["Stereo Out", "Output", "Bus"]
        for keyword in keywords {
            guard let kwBytes = keyword.data(using: .ascii) else { continue }
            // Find keyword in body
            var searchFrom = 0
            while searchFrom + kwBytes.count <= bytes.count {
                var found = true
                for (i, b) in kwBytes.enumerated() {
                    if bytes[searchFrom + i] != b { found = false; break }
                }
                if found {
                    // Extract null-terminated string starting at keyword position
                    var end = searchFrom
                    let limit = min(bytes.count, searchFrom + 64)
                    while end < limit && bytes[end] != 0 {
                        end += 1
                    }
                    let label = String(data: Data(bytes[searchFrom..<end]), encoding: .ascii)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    if !label.isEmpty { return label }
                }
                searchFrom += 1
            }
        }
        return nil
    }

    // MARK: - Trak Chunk Extraction

    /// Extract arrangement tracks from Trak chunks.
    ///
    /// Trak body layout (spec: fixed ~58 bytes):
    ///   0x08  4B  MSeq reference OID (LE u32)
    ///   0x18  16B UUID
    ///   0x28  4B  flags (LE u32)
    private static func extractTrakChunks(chunks: [ChunkInfo], data: Data) -> [TrakEntry] {
        var result: [TrakEntry] = []
        var seen = Set<UInt32>()

        for chunk in chunks where chunk.id == idTrak {
            guard chunk.bodyLength >= 0x2C else { continue }
            if !seen.insert(chunk.oid).inserted { continue }

            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // MSeq reference OID at body offset 0x08
            let mseqOid = readLE32(body, at: 0x08)
            guard mseqOid != 0 else { continue }  // Skip entries with no MSeq link

            // UUID: 16 bytes at body offset 0x18
            var uuid: String? = nil
            if body.count >= 0x28 {
                let uuidBytes = Data(body[0x18..<0x28])
                uuid = formatUUID(uuidBytes)
            }

            // Flags at body offset 0x28
            let flagsRaw = body.count >= 0x2C ? readLE32(body, at: 0x28) : 0

            result.append(TrakEntry(
                oid: Int(chunk.oid),
                mseqOid: Int(mseqOid),
                uuid: uuid,
                flagsRaw: flagsRaw
            ))
        }

        return result
    }

    /// Format 16 bytes as a standard UUID string (8-4-4-4-12 hex groups).
    private static func formatUUID(_ bytes: Data) -> String? {
        guard bytes.count >= 16 else { return nil }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        guard hex.count == 32 else { return nil }
        // Build UUID string manually to avoid Swift type-checker complexity
        var result = ""
        for (i, ch) in hex.enumerated() {
            result.append(ch)
            if i == 7 || i == 11 || i == 15 || i == 19 {
                result.append("-")
            }
        }
        // Return nil for all-zero UUID
        return result == "00000000-0000-0000-0000-000000000000" ? nil : result
    }

    // MARK: - Envi Name Extraction

    /// Extract environment object names from Envi chunks.
    ///
    /// Per the spec, Envi chunks contain environment objects with a name.
    /// Each Envi body is scanned for the first meaningful printable ASCII run.
    /// The buildSubTrackHierarchy step filters GM instrument names and noise.
    private static func extractEnviNames(chunks: [ChunkInfo], data: Data) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        for chunk in chunks where chunk.id == idEnvi {
            guard chunk.bodyLength >= 4 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            if let name = extractEnviName(body: body), !name.isEmpty {
                if seen.insert(name).inserted {
                    names.append(name)
                }
            }
        }

        return names
    }

    /// Extract Envi OID → name map for correlating environment objects with AuCO channel strips.
    /// Unlike `extractEnviNames` which returns a flat list, this preserves the chunk OID.
    private static func extractEnviNameMap(chunks: [ChunkInfo], data: Data) -> [UInt32: String] {
        var map: [UInt32: String] = [:]

        for chunk in chunks where chunk.id == idEnvi {
            guard chunk.bodyLength >= 4 else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            if let name = extractEnviName(body: body), !name.isEmpty {
                // Keep first name per OID (Envi OIDs can repeat with different bodies)
                if map[chunk.oid] == nil {
                    map[chunk.oid] = name
                }
            }
        }

        return map
    }

    /// Enrich generic AuCO channel strip names ("Audio N") with Envi environment labels.
    ///
    /// Matching strategy: for each generic strip, find an Envi object whose OID is
    /// within ±4 of the strip's OID and hasn't been consumed by another strip yet.
    /// This exploits the fact that Logic assigns OIDs to Envi and AuCO objects in
    /// nearby ranges for the same logical channel.
    private static func enrichChannelStripNamesFromEnvi(
        strips: inout [ChannelStrip],
        enviNameMap: [UInt32: String]
    ) {
        guard !enviNameMap.isEmpty else { return }

        // Sort Envi OIDs for efficient proximity search
        let sortedEnviOids = enviNameMap.keys.sorted()
        var consumedEnviOids = Set<UInt32>()

        for i in strips.indices {
            guard strips[i].isGeneric else { continue }

            let stripOid = UInt32(strips[i].oid)

            // Find nearest unconsumed Envi OID within ±4
            var bestOid: UInt32? = nil
            var bestDist: UInt32 = 5

            for enviOid in sortedEnviOids {
                guard !consumedEnviOids.contains(enviOid) else { continue }
                let dist = stripOid > enviOid ? stripOid - enviOid : enviOid - stripOid
                if dist < bestDist {
                    bestDist = dist
                    bestOid = enviOid
                }
            }

            if let oid = bestOid, let enviName = enviNameMap[oid] {
                strips[i].name = enviName
                strips[i].isGeneric = false
                consumedEnviOids.insert(oid)
            }
        }
    }

    /// Scan an Envi body for the first plausible printable ASCII name.
    ///
    /// Envi bodies in this project store names as contiguous printable ASCII runs
    /// (not length-prefixed). We scan the full body for the first run of 3-80
    /// printable bytes that contains at least one letter and passes noise filters.
    ///
    /// Noise filters exclude: output labels ("Output N"), system names
    /// ("Input View", "GM Device", "Preview", "Master", "Stereo Out"),
    /// and strings starting with "@" or "/".
    private static let enviNoiseNames: Set<String> = [
        "not assigned", "input view", "input notes", "preview",
        "master", "stereo out", "physical input", "sequencer input",
        "gm device", "edit output",
        "output 4", "output 9-10", "output 11-12",
        "output 25-26", "output 27-28", "output 29-30", "output 31-32",
    ]

    private static func extractEnviName(body: Data) -> String? {
        var run = ""
        var bestRun: String? = nil

        for byte in body {
            if byte >= 0x20 && byte < 0x7F {
                run.append(Character(Unicode.Scalar(byte)))
            } else {
                if let candidate = validateEnviRun(run) {
                    if bestRun == nil { bestRun = candidate }
                }
                run = ""
            }
        }
        // Flush last run
        if let candidate = validateEnviRun(run), bestRun == nil {
            bestRun = candidate
        }

        return bestRun
    }

    private static func validateEnviRun(_ run: String) -> String? {
        let trimmed = run.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 && trimmed.count <= 80 else { return nil }
        guard trimmed.contains(where: { $0.isLetter }) else { return nil }
        let lower = trimmed.lowercased()
        guard !lower.hasPrefix("@"), !lower.hasPrefix("/"), !lower.hasPrefix("http") else { return nil }
        // Filter noise names
        if enviNoiseNames.contains(lower) { return nil }
        // Filter "Output N" patterns
        if lower.hasPrefix("output ") && lower.dropFirst(7).allSatisfy({ $0.isNumber || $0 == "-" }) { return nil }
        return trimmed
    }

    // MARK: - AuCO Channel Strip Extraction (Full Enumeration)

    /// Extract ALL AuCO channel strips as sub-track enumeration.
    ///
    /// Unlike enrichTracksWithAuCO (which only patches existing MSeq tracks),
    /// this function returns every channel strip found — including all individual
    /// guitars, vocals, keys, synth layers etc. that never appear as MSeq entries.
    ///
    /// Key insight: AuCO chunks in many projects share a small set of OIDs but
    /// each body encodes a different channel strip name. We deduplicate by name
    /// (after trimming) rather than by OID to capture all 449 strips.
    ///
    /// AuCO body layout:
    ///   0x3C  null-terminated ASCII  name (up to 64 bytes)
    ///   0x59  1B                     pan byte (0=hard left, 64=center, 127=hard right)
    ///   0x74  4B LE u32              volume raw (unity = 1509949440)
    private static func extractAllChannelStrips(chunks: [ChunkInfo], data: Data) -> [ChannelStrip] {
        var result: [ChannelStrip] = []
        var seenNames = Set<String>()
        var seenOids = Set<UInt32>()     // track first-OID-seen for OID assignment
        var syntheticIndex = 0          // for OID-less strips

        for chunk in chunks where chunk.id == idAuCO {
            guard chunk.bodyLength > 0x5A else { continue }

            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // Name: null-terminated ASCII at 0x3C (up to 64 bytes), trimmed
            let name = readNullTerminatedASCII(body, at: 0x3C, maxLen: 64)
            let trimmedName = name.isEmpty ? "" : name

            // Skip duplicate names (same channel strip appearing in multiple bodies)
            let dedupeKey = trimmedName.isEmpty ? "__empty_\(syntheticIndex)" : trimmedName
            guard seenNames.insert(dedupeKey).inserted else { continue }
            if trimmedName.isEmpty { syntheticIndex += 1 }

            // Pan byte at 0x59
            let panByte = Int(body[0x59])
            let panNorm: Double = (Double(panByte) - 64.0) / 64.0

            // Volume
            let volumeDB = readVolumeDB(body: body)

            // Output routing
            let outputRouting = extractOutputRouting(body: body)

            // Is generic? ("Audio N", "Input N", "Bus N", etc.)
            let isGeneric = isGenericChannelStripName(trimmedName)

            // OID: use chunk OID if not yet assigned, otherwise use synthetic
            let oid: Int
            if seenOids.insert(chunk.oid).inserted {
                oid = Int(chunk.oid)
            } else {
                // Synthesize a unique OID for strips that share the chunk OID
                // Use a high-bit offset to avoid collision with real OIDs
                oid = Int(chunk.oid) * 1000 + result.count
            }

            result.append(ChannelStrip(
                name: trimmedName.isEmpty ? "Strip \(oid)" : trimmedName,
                oid: oid,
                volume: volumeDB,
                pan: panNorm.clamped(to: -1.0...1.0),
                outputRouting: outputRouting,
                functionGroup: nil,
                isGeneric: isGeneric,
                trakOid: nil,
                mseqOid: nil
            ))
        }

        return result
    }

    /// Returns true when a channel strip name is a generic placeholder.
    /// Patterns: "Audio N", "Inst N", "Bus N", "Output N", "Input N", "Ext. Inst N", empty, etc.
    private static func isGenericChannelStripName(_ name: String) -> Bool {
        guard !name.isEmpty else { return true }
        let lower = name.lowercased()

        // Pure numeric suffix patterns
        let genericPrefixes = [
            "audio ", "inst ", "bus ", "output ", "input ", "ext. inst ",
            "software instrument ", "aux ", "stereo out",
            "physical input", "sequencer input", "not assigned",
        ]
        for prefix in genericPrefixes {
            if lower.hasPrefix(prefix) {
                // Allow if remainder is not pure digits (user may have named it "Audio Guitar")
                let rest = lower.dropFirst(prefix.count)
                if rest.isEmpty || rest.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " }) {
                    return true
                }
            }
        }
        // Exact matches that are always generic
        if lower == "stereo out" || lower == "master" || lower == "not assigned" { return true }

        // All-digit names
        if name.allSatisfy({ $0.isNumber }) { return true }

        return false
    }

    // MARK: - AuCO → Trak → MSeq Chain

    /// Link channel strips to Trak entries (and via Trak, to MSeq).
    ///
    /// Strategy:
    ///   1. Exact OID match: AuCO.oid == Trak.oid
    ///   2. Proximity: nearest Trak OID within ±8 of AuCO.oid
    private static func linkChannelStripsToTrak(
        strips: inout [ChannelStrip],
        trakEntries: [TrakEntry]
    ) {
        guard !trakEntries.isEmpty else { return }

        // Build OID → Trak map
        var trakByOid: [Int: TrakEntry] = [:]
        for t in trakEntries {
            trakByOid[t.oid] = t
        }
        let sortedTrakOids = trakEntries.map { $0.oid }.sorted()

        for i in strips.indices {
            let stripOid = strips[i].oid

            // 1. Exact match
            if let trak = trakByOid[stripOid] {
                strips[i].trakOid = trak.oid
                strips[i].mseqOid = trak.mseqOid
                continue
            }

            // 2. Nearest within ±8
            var bestDist = 9
            var bestTrak: TrakEntry? = nil
            for tOid in sortedTrakOids {
                let dist = abs(stripOid - tOid)
                if dist < bestDist {
                    bestDist = dist
                    bestTrak = trakByOid[tOid]
                }
            }
            if let trak = bestTrak {
                strips[i].trakOid = trak.oid
                strips[i].mseqOid = trak.mseqOid
            }
        }
    }

    /// Infer function groups on channel strips using name keywords.
    private static func inferFunctionGroupsOnStrips(strips: inout [ChannelStrip]) {
        for i in strips.indices {
            strips[i].functionGroup = inferGroupFromText(strips[i].name)
        }
    }

    // MARK: - Sub-track Hierarchy Builder

    /// Build the full sub-track hierarchy from channel strips and environment labels.
    ///
    /// Algorithm:
    ///   1. If environment labels contain non-generic names (song/project-specific names),
    ///      use them as the sub-track catalog — they map directly to Logic's Environment
    ///      and represent each actual mixer channel.
    ///   2. Assign each environment-label sub-track to an environment stack using keyword
    ///      matching against canonical stack labels.
    ///   3. For any named AuCO channel strips, also include them in the hierarchy.
    ///   4. Filter noise from the environment labels (GM instrument names, system labels).
    private static func buildSubTrackHierarchy(
        strips: [ChannelStrip],
        environmentLabels: [String]
    ) -> [SubTrackStack] {
        // Canonical environment stack labels (in display order)
        let canonicalStackLabels: [(label: String, keywords: [String])] = [
            ("Click Track",    ["click", "metronome", "midi click"]),
            ("Midi Triggers",  ["midi", "trigger", "cortex", "quad", "nano", "wled"]),
            ("Backing Track",  ["backing"]),
            ("Release Track",  ["release"]),
            ("Drums",          ["drum", "kick", "snare", "perc"]),
            ("Guitars",        ["guitar", "gtr", "clean", "distort", "guitare"]),
            ("Vocals",         ["vocal", "vox", "harmony", "choir", "voice"]),
            ("Keys/Synths",    ["key", "piano", "organ", "synth", "rhodes"]),
            ("Bass",           ["bass"]),
            ("Strings",        ["string", "violin", "viola", "cello"]),
            ("Samples/FX",     ["sample", "sfx", "texture", "soundscape", "ambient", "loop"]),
            ("Songs",          ["intro", "verse", "chorus", "bridge", "breakdown", "transition",
                                "the last light", "in her eyes", "reborn", "fortitude",
                                "new beginnings", "dead", "buried", "twdtd", "ihe"]),
        ]

        // Known noise patterns for environment labels (not real sub-tracks)
        let gmInstruments: Set<String> = [
            "accordion fr", "acoustic bs.", "agogo", "alto sax", "applause", "atmosphere",
            "bag pipe", "banjo", "baritone sax", "bass&lead", "bassoon", "bird", "blown bottle",
            "bowed glass", "brass 1", "breath noise", "bright piano", "brightness", "celesta",
            "cello", "charang", "chiffer lead", "choir aahs", "church organ1", "clarinet",
            "clavinet", "clean gt.", "contrabass", "crystal", "distortion gt", "draworgan",
            "dulcimer", "e. piano1", "e. piano2", "echo drops", "electricgrand", "english horn",
            "fantasia", "fiddle", "fingered bs.", "flute", "french horn", "fretless bs.",
            "glockenspiel", "goblin", "grand piano", "gt fretnoise", "gt.harmonics",
            "gun shot", "halo pad", "harmonica", "harp", "harpsichord", "helicopter",
            "honkytonkpno.", "ice rain", "jazz gt.", "kalimba", "koto", "marimba", "melo tom",
            "metal pad", "music box", "muted gt.", "mutedtrumpet", "nylonstr. gt.", "oboe",
            "ocarina", "orchestrahit", "overdrive gt.", "pan flute", "percorgan", "piccolo",
            "picked bs.", "pizzicato str", "polysynth", "recorder", "reed organ", "reverse cym.",
            "rockorgan", "saw wave", "seashore", "shakuhachi", "shamisen", "shanai", "sitar",
            "slap bass 1", "slap bass 2", "slow strings", "solo vox", "soprano sax", "soundtrack",
            "space voice", "square wave", "star theme", "steel drums", "steelstr. gt.", "strings",
            "sweep pad", "syn. calliope", "syn. strings1", "syn. strings2", "synvox",
            "synth bass 1", "synth bass 2", "synth brass1", "synth brass2", "synth drum",
            "tangoacd", "telephone 1", "tenor sax", "timpani", "tinkle bell", "tremolo str.",
            "trombone", "trumpet", "tuba", "tubular-bell", "vibraphone", "viola", "violin",
            "voice oohs", "warm pad", "whistle", "woodblock", "xylophone",
            "5th saw wave", "e<j", "m#v", "o4i", "s9ie", "ax%", "dto", "h%ns", "n91q",
            "no2", "}=l", "e<j", "*$v", "*6uw", "<bo", "dro",
            // System/router objects
            "gm device", "(folder)",
        ]

        // Filter environment labels to meaningful project-specific names
        let projectLabels = environmentLabels.filter { label in
            let lower = label.lowercased()
            if gmInstruments.contains(lower) { return false }
            // Skip short noise (2-3 char random strings)
            if label.count <= 2 { return false }
            // Skip strings that look like binary noise (no vowels)
            let vowels = Set<Character>("aeiouAEIOU")
            if label.count <= 4 && !label.contains(where: { vowels.contains($0) }) { return false }
            return true
        }

        // Build map: stack label → sub-track names
        var stackMap: [String: [String]] = [:]
        var unassigned: [String] = []

        for label in projectLabels {
            let lower = label.lowercased()
            var assigned = false

            // Check canonical stacks
            for stackDef in canonicalStackLabels {
                let matchesKeyword = stackDef.keywords.contains { kw in
                    lower.contains(kw)
                }
                if matchesKeyword {
                    stackMap[stackDef.label, default: []].append(label)
                    assigned = true
                    break
                }
            }

            if !assigned {
                unassigned.append(label)
            }
        }

        // Build sub-track stacks
        var stacks: [SubTrackStack] = []

        // Named AuCO strips (if any are non-generic)
        let namedStrips = strips.filter { !$0.isGeneric }

        // Canonical stack order
        for stackDef in canonicalStackLabels {
            guard let labelGroup = stackMap[stackDef.label], !labelGroup.isEmpty else { continue }

            // Convert label group to ChannelStrip objects (synthetic, from Envi labels)
            let stackStrips: [ChannelStrip] = labelGroup.map { label in
                // Try to find a real AuCO strip with matching name
                let matchedStrip = namedStrips.first { s in
                    s.name.lowercased() == label.lowercased()
                }
                if let s = matchedStrip { return s }
                // Create synthetic strip from Envi label
                return ChannelStrip(
                    name: label,
                    oid: 0,
                    volume: nil,
                    pan: nil,
                    outputRouting: nil,
                    functionGroup: stackDef.label,
                    isGeneric: false,
                    trakOid: nil,
                    mseqOid: nil
                )
            }

            stacks.append(SubTrackStack(
                name: stackDef.label,
                source: "environment_label",
                strips: stackStrips.sorted { $0.name < $1.name }
            ))
        }

        // Unassigned project labels
        if !unassigned.isEmpty {
            let unassignedStrips = unassigned.map { label -> ChannelStrip in
                ChannelStrip(
                    name: label,
                    oid: 0,
                    volume: nil,
                    pan: nil,
                    outputRouting: nil,
                    functionGroup: nil,
                    isGeneric: false,
                    trakOid: nil,
                    mseqOid: nil
                )
            }
            stacks.append(SubTrackStack(
                name: "Other",
                source: "environment_label",
                strips: unassignedStrips.sorted { $0.name < $1.name }
            ))
        }

        // Any non-generic AuCO strips not already in a stack
        let inStackNames = Set(stacks.flatMap { $0.strips.map { $0.name.lowercased() } })
        let remainingStrips = namedStrips.filter { !inStackNames.contains($0.name.lowercased()) }
        if !remainingStrips.isEmpty {
            // Group remaining by function group
            var fgMap: [String: [ChannelStrip]] = [:]
            for s in remainingStrips {
                let fg = s.functionGroup ?? "Other"
                fgMap[fg, default: []].append(s)
            }
            for fg in fgMap.keys.sorted() {
                stacks.append(SubTrackStack(
                    name: fg,
                    source: "function_group",
                    strips: (fgMap[fg] ?? []).sorted { $0.name < $1.name }
                ))
            }
        }

        return stacks
    }

    // MARK: - Plugin List

    /// Extract plugin names by scanning ALL chunk bodies for known plugin name strings,
    /// and scanning PluginData (null-ID) chunks for printable ASCII strings > 4 chars.
    ///
    /// Bug 4 Fix:
    ///   - reverseID() now maps non-printable IDs to "PluginData" so they are no longer skipped.
    ///   - PluginData chunks are scanned for all printable ASCII strings > 4 chars.
    ///   - We also scan ALL chunks (not just "PluginData") for known plugin name strings.
    ///   - Extended known plugin list per spec.
    private static func extractPlugins(chunks: [ChunkInfo], data: Data) -> [String] {
        var plugins = Set<String>()

        // Known plugin name keywords to search for (per spec + user requirement)
        let knownPlugins: [String] = [
            // Logic built-ins
            "Compressor", "Channel EQ", "Space Designer", "Alchemy", "Klopfgeist",
            "Delay Designer", "Retro Synth", "Gain", "Limiter", "Multipressor",
            // Third-party
            "Serum", "Kontakt", "Neural DSP", "FabFilter", "Valhalla", "Waves", "iZotope",
            "Slate", "Massive", "Diva", "Sylenth", "Omnisphere", "Nexus", "Spire",
            "Vital", "Pigments", "Saturn", "Vintage", "Native Instruments",
        ]

        for chunk in chunks {
            guard chunk.bodyLength > 4, chunk.bodyLength < 10_000_000 else { continue }

            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            // Scan for known plugin name keywords in ALL chunks
            let ascii = body.map { b -> Character in
                let s = Unicode.Scalar(b)
                return s.value >= 32 && s.value < 127 ? Character(s) : Character("\0")
            }
            let bodyStr = String(ascii)

            for plugin in knownPlugins where bodyStr.contains(plugin) {
                plugins.insert(plugin)
            }

            // For PluginData (null-ID) chunks: also extract all printable ASCII runs > 4 chars
            // These may contain plugin names not in our known list.
            if chunk.id == "PluginData" {
                var run = ""
                for byte in body {
                    let scalar = Unicode.Scalar(byte)
                    if scalar.value >= 32 && scalar.value < 127 {
                        run.append(Character(scalar))
                    } else {
                        // End of printable run — keep if > 4 chars and looks like a plugin name
                        // (starts with uppercase, not a path/URL/generic string)
                        if run.count > 4
                            && run.count < 64
                            && run.first?.isUppercase == true
                            && !run.hasPrefix("/")
                            && !run.hasPrefix("http")
                            && !run.contains("=")
                            && !run.contains("\\")
                        {
                            plugins.insert(run)
                        }
                        run = ""
                    }
                }
                // Flush final run
                if run.count > 4
                    && run.count < 64
                    && run.first?.isUppercase == true
                    && !run.hasPrefix("/")
                    && !run.hasPrefix("http")
                    && !run.contains("=")
                    && !run.contains("\\")
                {
                    plugins.insert(run)
                }
            }
        }

        return Array(plugins).sorted()
    }

    /// Returns true if the chunk ID consists only of non-printable / null bytes.
    private static func isNullID(_ id: String) -> Bool {
        return id.unicodeScalars.allSatisfy { $0.value < 32 || $0.value == 0 }
    }

    // MARK: - Function Group Inference

    /// Infer a function group label for each track based on keywords in the track name and region names.
    /// Children inherit their parent's function group when they have none of their own.
    static func inferFunctionGroups(tracks: inout [ParsedTrack]) {
        // Build OID -> index map for fast lookup
        var oidToIdx: [Int: Int] = [:]
        for (i, t) in tracks.enumerated() {
            oidToIdx[t.oid] = i
        }

        // First pass: assign from track name + region names
        for i in tracks.indices {
            let group = inferGroupFromText(tracks[i].name)
                ?? inferGroupFromRegions(tracks[i].regions)
            tracks[i].functionGroup = group
        }

        // Second pass: children inherit parent group when unclassified
        // Process from shallowest to deepest
        let sorted = tracks.indices.sorted { tracks[$0].stackDepth < tracks[$1].stackDepth }
        for i in sorted {
            guard tracks[i].functionGroup == nil else { continue }
            if let parentOid = tracks[i].parentOid,
               let parentIdx = oidToIdx[parentOid],
               let parentGroup = tracks[parentIdx].functionGroup {
                tracks[i].functionGroup = parentGroup
            }
        }
    }

    /// Infer function group from a single text string (track name, region name, etc.)
    private static func inferGroupFromText(_ text: String) -> String? {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return nil }

        // Ordered from most specific to least specific
        if lower.contains("click") || lower.contains("cue") || lower.contains("metronome")
            || lower.contains("klopfgeist") {
            return "Click Track"
        }
        if lower.contains("drum") || lower.contains("kick") || lower.contains("snare")
            || lower.contains("hi-hat") || lower.contains("hihat") || lower.contains("cymbal")
            || lower.contains("tom") {
            return "Drums"
        }
        if lower.contains("guitar") || lower.contains("gtr") || lower.contains("guit") {
            return "Guitars"
        }
        if lower.contains("vocal") || lower.contains("vox") || lower.contains("bv")
            || lower.contains("backing vocal") || lower.contains("harmony") {
            return "Vocals"
        }
        if lower.contains("key") || lower.contains("piano") || lower.contains("organ")
            || lower.contains("synth") || lower.contains("pad") {
            return "Keys/Synths"
        }
        if lower.contains("bass") {
            return "Bass"
        }
        if lower.contains("sample") || lower.contains("sfx") || lower.contains("ambient")
            || lower.contains("soundscape") {
            return "Samples/FX"
        }
        if lower.contains("midi") || lower.contains("trigger") || lower.contains("cortex")
            || lower.contains("controller") {
            return "MIDI Triggers"
        }
        if lower.contains("reference") || lower.contains("mix") || lower.contains("master") {
            return "Reference"
        }
        if lower.contains("backing") {
            return "Backing Track"
        }
        return nil
    }

    /// Infer function group from region names on a track.
    private static func inferGroupFromRegions(_ regions: [ParsedRegion]) -> String? {
        for region in regions.prefix(10) {
            if let g = inferGroupFromText(region.name) {
                return g
            }
        }
        return nil
    }

    // MARK: - Marker Assembly

    private static func buildMarkers(
        txSqMap: [UInt32: String],
        events: [MarkerEvent]
    ) -> [ParsedMarker] {
        // Build a map from events for quick lookup
        let eventMap: [UInt32: MarkerEvent] = Dictionary(
            events.map { ($0.oid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // First pass: build markers with tick/bar, sort by tick
        struct PartialMarker {
            let name: String
            let bar: Int
            let tick: Int
            let oid: Int
        }

        var partials: [PartialMarker] = []
        for (oid, name) in txSqMap {
            guard let event = eventMap[oid] else { continue }
            let tick = Int(event.startTick)
            let bar = tick / ticksPerBar + 1
            partials.append(PartialMarker(name: name, bar: bar, tick: tick, oid: Int(oid)))
        }

        // Sort by tick position (ascending)
        partials.sort { $0.tick < $1.tick }

        // Second pass: calculate duration from sequential markers (Fix 1)
        // For each marker except the last: duration = next_marker.tick - this_marker.tick
        // For the last marker: default 8 bars = 3840 * 8 = 30720 ticks
        let defaultLastDuration = ticksPerBar * 8

        var markers: [ParsedMarker] = []
        for (i, partial) in partials.enumerated() {
            let durationTicks: Int
            if i + 1 < partials.count {
                durationTicks = partials[i + 1].tick - partial.tick
            } else {
                durationTicks = defaultLastDuration
            }
            let durationBars = durationTicks > 0 ? max(1, durationTicks / ticksPerBar) : 0

            markers.append(ParsedMarker(
                name: partial.name,
                bar: partial.bar,
                tick: partial.tick,
                durationTicks: durationTicks,
                durationBars: durationBars,
                oid: partial.oid
            ))
        }

        return markers
    }

    // MARK: - Plist Parsing (Time Signature, Sample Rate, BPM)

    /// Build a list of candidate plist URLs to check within a .logicx bundle.
    /// The MetaData.plist is typically inside Alternatives/000/ (not at the root).
    private static func plistCandidateURLs(logicx: URL, name: String) -> [URL] {
        var candidates: [URL] = []
        // Root-level (some older versions place files here)
        candidates.append(logicx.appendingPathComponent(name))
        // Alternatives subdirectories (000, 001, etc.)
        let altRoot = logicx.appendingPathComponent("Alternatives")
        let fm = FileManager.default
        for index in 0...9 {
            let indexStr = String(format: "%03d", index)
            let url = altRoot.appendingPathComponent(indexStr).appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                candidates.insert(url, at: 0) // prefer found file
            } else {
                candidates.append(url)
            }
        }
        return candidates
    }

    /// Read time signature from MetaData.plist or ProjectInformation.plist.
    private static func readTimeSignature(logicx: URL) -> String? {
        let names = ["MetaData.plist", "ProjectInformation.plist"]
        for name in names {
            for url in plistCandidateURLs(logicx: logicx, name: name) {
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
                if let sig = searchPlistForTimeSignature(plist) { return sig }
            }
        }
        return nil
    }

    /// Read initial BPM from project plists.
    /// Checks MetaData.plist and ProjectInformation.plist for common BPM/Tempo keys.
    private static func readBPMFromPlist(logicx: URL) -> Double? {
        let names = ["MetaData.plist", "ProjectInformation.plist"]
        for name in names {
            for url in plistCandidateURLs(logicx: logicx, name: name) {
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
                if let bpm = searchPlistForBPM(plist) { return bpm }
            }
        }
        return nil
    }

    private static func searchPlistForBPM(_ plist: Any) -> Double? {
        let bpmKeys = ["BPM", "bpm", "Tempo", "tempo", "BeatsPerMinute", "beatsPerMinute",
                       "ProjectTempo", "projectTempo", "DefaultTempo", "defaultTempo"]
        if let dict = plist as? [String: Any] {
            for key in bpmKeys {
                if let v = dict[key] {
                    if let d = v as? Double, d > 10.0 && d < 1000.0 { return d }
                    if let i = v as? Int, i > 10 && i < 1000 { return Double(i) }
                    if let s = v as? String, let d = Double(s), d > 10.0 && d < 1000.0 { return d }
                }
            }
            for (_, value) in dict {
                if let found = searchPlistForBPM(value) { return found }
            }
        } else if let arr = plist as? [Any] {
            for item in arr {
                if let found = searchPlistForBPM(item) { return found }
            }
        }
        return nil
    }

    private static func searchPlistForTimeSignature(_ plist: Any) -> String? {
        if let dict = plist as? [String: Any] {
            // Look for TimeSignature key directly
            if let ts = dict["TimeSignature"] as? String { return ts }
            if let n = dict["numerator"] as? Int, let d = dict["denominator"] as? Int {
                return "\(n)/\(d)"
            }
            // Recurse into values
            for (_, value) in dict {
                if let found = searchPlistForTimeSignature(value) { return found }
            }
        } else if let arr = plist as? [Any] {
            for item in arr {
                if let found = searchPlistForTimeSignature(item) { return found }
            }
        }
        return nil
    }

    /// Read sample rate from project plists.
    private static func readSampleRate(logicx: URL) -> Int? {
        // Check standard project plists (MetaData.plist is inside Alternatives/000/)
        let names = ["MetaData.plist", "ProjectInformation.plist", "Info.plist"]
        for name in names {
            for url in plistCandidateURLs(logicx: logicx, name: name) {
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
                if let sr = searchPlistForSampleRate(plist) { return sr }
            }
        }
        return nil
    }

    private static func searchPlistForSampleRate(_ plist: Any) -> Int? {
        let srKeys = [
            "SampleRate", "sampleRate", "sample_rate",
            "Recording Sample Rate", "RecordingSampleRate",
            "Audio Sample Rate", "AudioSampleRate",
            "AudioFileSampleRate", "audioFileSampleRate",
        ]
        if let dict = plist as? [String: Any] {
            for key in srKeys {
                if let v = dict[key] {
                    if let i = v as? Int, i > 0 { return i }
                    if let d = v as? Double, d > 0 { return Int(d) }
                    if let s = v as? String, let i = Int(s), i > 0 { return i }
                    // Handle string-encoded floats (e.g. "44100.0")
                    if let s = v as? String, let d = Double(s), d > 0 { return Int(d) }
                }
            }
            for (_, value) in dict {
                if let found = searchPlistForSampleRate(value) { return found }
            }
        } else if let arr = plist as? [Any] {
            for item in arr {
                if let found = searchPlistForSampleRate(item) { return found }
            }
        }
        return nil
    }

    // MARK: - Track Index Map (Envi name → AX track index)

    /// Build a mapping of Envi name → AX track index by fuzzy-matching Envi names
    /// against the live track list read from the AX arrange window.
    ///
    /// Matching strategy (priority order):
    ///   1. Exact name match (case-insensitive).
    ///   2. Contains match — Envi name contains live name or vice versa.
    ///   3. Token overlap — both names share ≥2 word tokens.
    ///
    /// Returns a dictionary: Envi name → AX 0-based track index.
    static func buildTrackIndexMap(
        enviNames: [String],
        liveTracks: [LiveTrackInfo]
    ) -> [String: Int] {
        var result: [String: Int] = [:]

        // Pre-compute lowercased live track names and their token sets for speed.
        let liveNamesLower = liveTracks.map { $0.name.lowercased() }
        let liveTokens: [[String]] = liveNamesLower.map { tokenise($0) }

        for enviName in enviNames {
            let enviLower = enviName.lowercased()
            let enviToks = tokenise(enviLower)

            // --- Pass 1: exact (case-insensitive) ---
            if let idx = liveNamesLower.firstIndex(of: enviLower) {
                result[enviName] = liveTracks[idx].index
                continue
            }

            // --- Pass 2: contains ---
            var containsIdx: Int? = nil
            for (i, liveLow) in liveNamesLower.enumerated() {
                if enviLower.contains(liveLow) || liveLow.contains(enviLower) {
                    containsIdx = i
                    break
                }
            }
            if let idx = containsIdx {
                result[enviName] = liveTracks[idx].index
                continue
            }

            // --- Pass 3: token overlap (≥2 shared tokens) ---
            if !enviToks.isEmpty {
                var bestScore = 1          // need at least 2 to qualify
                var bestIdx: Int? = nil
                let enviSet = Set(enviToks)
                for (i, toks) in liveTokens.enumerated() where !toks.isEmpty {
                    let overlap = toks.filter { enviSet.contains($0) }.count
                    if overlap > bestScore {
                        bestScore = overlap
                        bestIdx = i
                    }
                }
                if let idx = bestIdx {
                    result[enviName] = liveTracks[idx].index
                }
            }
        }

        return result
    }

    /// Split a name into lowercase word tokens (letters/digits only).
    private static func tokenise(_ text: String) -> [String] {
        return text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    // MARK: - Song Lengths from Reference Track

    /// Compute per-song lengths using reference track regions for accuracy.
    ///
    /// Strategy:
    ///   1. Find the "Release Track" or "Reference" in the sub-track hierarchy
    ///      (classified as functionGroup == "Reference").
    ///   2. Collect all regions assigned to that track (via trackOid mapping).
    ///   3. For each song marker, find a reference region that starts at (or near)
    ///      the marker bar, and use that region's length.
    ///   4. If no region overlaps a marker, try matching region name to marker name
    ///      (e.g. region "New Beginnings" matches marker "New Beginnings").
    ///   5. Fallback: marker-to-next-marker boundary.
    ///
    /// Returns one SongLength per arrangement marker, sorted by startBar.
    static func computeSongLengthsFromReference(
        info: ProjectDataInfo
    ) -> [SongLength] {
        let markers = info.markers.sorted { $0.bar < $1.bar }
        guard !markers.isEmpty else { return [] }

        // --- Find reference track OID ---
        // Look in subTrackHierarchy for a stack named "Release Track" or "Reference".
        let referenceStackNames: Set<String> = ["Release Track", "Reference", "Ref", "release track"]
        var referenceTrackOids: Set<Int> = []

        for stack in info.subTrackHierarchy {
            if referenceStackNames.contains(stack.name)
                || stack.name.lowercased().contains("release")
                || stack.name.lowercased().contains("reference")
            {
                for strip in stack.strips {
                    if let mseqOid = strip.mseqOid { referenceTrackOids.insert(mseqOid) }
                    if strip.trakOid != nil || strip.mseqOid != nil {
                        referenceTrackOids.insert(strip.oid)
                    }
                }
            }
        }
        // Also check MSeq tracks by function group
        for track in info.tracks where track.functionGroup == "Reference" {
            referenceTrackOids.insert(track.oid)
        }

        // --- Collect reference regions ---
        let referenceRegions: [ParsedRegion]
        if !referenceTrackOids.isEmpty {
            referenceRegions = info.regions.filter { region in
                guard let tOid = region.trackOid else { return false }
                return referenceTrackOids.contains(tOid)
            }
        } else {
            referenceRegions = []
        }

        // --- Build a name-based region lookup (region.name lowercased → region) ---
        var regionByName: [String: ParsedRegion] = [:]
        for region in referenceRegions where !region.name.isEmpty {
            let key = region.name.lowercased()
            // Keep the longest region when names clash
            if let existing = regionByName[key], existing.lengthBars >= region.lengthBars { continue }
            regionByName[key] = region
        }
        // Also index by stripped names (without ".N" suffix like "Dead and Buried.2")
        var regionByBaseName: [String: ParsedRegion] = [:]
        for region in referenceRegions where !region.name.isEmpty {
            let stripped = stripRegionSuffix(region.name).lowercased()
            if let existing = regionByBaseName[stripped], existing.lengthBars >= region.lengthBars { continue }
            regionByBaseName[stripped] = region
        }

        // --- Compute song lengths ---
        var songLengths: [SongLength] = []

        for (i, marker) in markers.enumerated() {
            let markerStartBar = marker.bar
            let markerEndBar: Int
            if i + 1 < markers.count {
                markerEndBar = markers[i + 1].bar
            } else {
                markerEndBar = marker.bar + marker.durationBars
            }
            let markerBoundaryLength = markerEndBar - markerStartBar

            // --- Try to find a reference region ---
            var matchedRegion: ParsedRegion? = nil

            // 1. Overlapping by bar position: region starts within ±2 bars of marker
            if !referenceRegions.isEmpty {
                matchedRegion = referenceRegions.first { region in
                    let regionStartInt = Int(region.startBar.rounded())
                    return abs(regionStartInt - markerStartBar) <= 2
                }
            }

            // 2. Name match: marker name matches region name (or base name)
            if matchedRegion == nil {
                let markerKey = marker.name.lowercased()
                matchedRegion = regionByName[markerKey] ?? regionByBaseName[markerKey]
            }

            // 3. Partial name match (marker name contained in region base name or vice versa)
            if matchedRegion == nil && !referenceRegions.isEmpty {
                let markerKey = marker.name.lowercased()
                matchedRegion = referenceRegions.first { region in
                    let rKey = stripRegionSuffix(region.name).lowercased()
                    return rKey.contains(markerKey) || markerKey.contains(rKey)
                }
            }

            if let region = matchedRegion, region.lengthBars > 0 {
                let lengthBars = max(1, Int(region.lengthBars.rounded()))
                songLengths.append(SongLength(
                    songName: marker.name,
                    startBar: markerStartBar,
                    endBar: markerStartBar + lengthBars,
                    lengthBars: lengthBars,
                    source: "reference_region"
                ))
            } else {
                // Fallback: marker-to-marker boundary
                songLengths.append(SongLength(
                    songName: marker.name,
                    startBar: markerStartBar,
                    endBar: markerEndBar,
                    lengthBars: markerBoundaryLength,
                    source: "marker_boundary"
                ))
            }
        }

        return songLengths
    }

    /// Strip a trailing ".N" numeric suffix from a region name.
    /// e.g. "Dead and Buried.2" → "Dead and Buried"
    private static func stripRegionSuffix(_ name: String) -> String {
        // Pattern: name ends with ".<digits>"
        if let dotIdx = name.lastIndex(of: ".") {
            let suffix = String(name[name.index(after: dotIdx)...])
            if !suffix.isEmpty && suffix.allSatisfy({ $0.isNumber }) {
                return String(name[name.startIndex..<dotIdx])
            }
        }
        return name
    }

    // MARK: - Low-level Readers

    /// Read a 4-byte little-endian UInt32 from a Data slice at a given offset within that slice.
    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Read a 2-byte little-endian UInt16 from a Data slice.
    private static func readLE16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    /// Read an 8-byte little-endian UInt64 from a Data slice.
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
    /// e.g., on-disk bytes [0x71, 0x53, 0x78, 0x54] -> "TxSq"
    /// Bug 4 Fix: when all 4 bytes are zero or non-printable, return "PluginData"
    private static func reverseID(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "????" }
        let reversed = bytes.reversed()
        let chars = reversed.compactMap { b -> Character? in
            let scalar = Unicode.Scalar(b)
            let ch = Character(scalar)
            return ch.isASCII && scalar.value >= 32 ? ch : nil
        }
        // If all 4 bytes are non-printable/null, this is a PluginData-style chunk
        if chars.count < 4 {
            return "PluginData"
        }
        return String(chars)
    }
}

// MARK: - Comparable Clamping Helper

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - AppleScript Helper

/// Run AppleScript with a timeout using DispatchSemaphore.
/// Returns the string result, or nil on error or timeout.
func runAppleScript(_ source: String) -> String? {
    // Wrap result in a class so it can be mutated from the async closure
    // without triggering Swift 6 Sendable warnings.
    final class Box: @unchecked Sendable { var value: String? }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: source)
        let desc = script?.executeAndReturnError(&errorDict)
        if errorDict == nil {
            box.value = desc?.stringValue
        }
        semaphore.signal()
    }

    // Wait up to 3 seconds
    let timedOut = semaphore.wait(timeout: .now() + 3.0) == .timedOut
    return timedOut ? nil : box.value
}

/// Get the POSIX path of the front Logic Pro document via AppleScript.
/// If AppleScript fails or times out, falls back to finding the most recently
/// modified .logicx file in ~/Desktop, ~/Documents, and ~/Music (max depth 3).
func currentLogicProProjectPath() -> String? {
    let source = """
    tell application "Logic Pro" to get POSIX path of (file of front document)
    """
    if let path = runAppleScript(source), !path.isEmpty {
        return path
    }
    return findMostRecentLogicxFile()
}

/// Scan ~/Desktop, ~/Documents, ~/Music for the most recently modified .logicx bundle
/// (max directory depth 3). Returns the path with the latest modification date, or nil.
func findMostRecentLogicxFile() -> String? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let searchRoots = [
        home.appendingPathComponent("Desktop"),
        home.appendingPathComponent("Documents"),
        home.appendingPathComponent("Music"),
    ]

    var best: (path: String, date: Date)? = nil

    func scan(_ url: URL, depth: Int) {
        guard depth >= 0 else { return }

        if url.pathExtension == "logicx" {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let modDate = attrs[.modificationDate] as? Date {
                if best.map({ modDate > $0.date }) ?? true {
                    best = (url.path, modDate)
                }
            }
            return  // Don't recurse into .logicx bundles
        }

        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in contents {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if child.pathExtension == "logicx" {
                if let attrs = try? fm.attributesOfItem(atPath: child.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    if best.map({ modDate > $0.date }) ?? true {
                        best = (child.path, modDate)
                    }
                }
            } else if isDir && depth > 0 {
                scan(child, depth: depth - 1)
            }
        }
    }

    for root in searchRoots {
        scan(root, depth: 3)
    }

    return best?.path
}
