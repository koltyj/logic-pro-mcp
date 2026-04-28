import Foundation

// MARK: - SongGraphDecoder
//
// Topological-only decoder for Logic Pro's Song Node Graph.
//
// Reference: `reference/RE_FINDINGS.md` — "Song Node Graph / Marker-Bar Join
// (Decoded)". The `Song` chunk body carries a graph of 24-byte nodes packed
// as six little-endian u32s:
//
//   rec[0] = node type        (14 = marker domain, 20 = bar domain)
//   rec[1] = shared join key  (unified ID space between type-14 and type-20)
//   rec[2] = payload (opaque / hashed — DO NOT decode)
//   rec[3] = payload (opaque / hashed — DO NOT decode)
//   rec[4] = typed link: target type (0, 14, or 20)
//   rec[5] = typed link: target ID (in the shared join-key space)
//
// Payload fields (rec[2], rec[3]) are opaque hashes — they do not decode to
// a numeric bar or tick. This decoder therefore exposes ONLY the topological
// join: whenever a type-14 node and a type-20 node share the same rec[1],
// they describe the same logical point on the timeline.
//
// The chunk body alignment that yields valid node records varies per project.
// We probe every 4-byte alignment in 0..<24 and pick the alignment that
// produces the most records satisfying the type/range constraints described
// in `RE_FINDINGS.md`.

/// A single 24-byte node decoded from a `Song` chunk body.
public struct SongNode: Sendable, Codable, Equatable, Hashable {
    /// Node type. Observed values: 14 (marker domain), 20 (bar domain).
    /// Stored as `rec[0]`.
    public let type: UInt32
    /// Shared ID space used as the join key between type-14 and type-20 nodes.
    /// Stored as `rec[1]`.
    public let joinKey: UInt32
    /// Opaque payload slot. Stored as `rec[2]`. Do NOT interpret numerically.
    public let payload2: UInt32
    /// Opaque payload slot. Stored as `rec[3]`. Do NOT interpret numerically.
    public let payload3: UInt32
    /// Typed-link target type. Stored as `rec[4]`. Observed: 0, 14, or 20.
    public let linkType: UInt32
    /// Typed-link target ID (in the shared join-key space). Stored as `rec[5]`.
    public let linkTargetId: UInt32

    public init(
        type: UInt32,
        joinKey: UInt32,
        payload2: UInt32,
        payload3: UInt32,
        linkType: UInt32,
        linkTargetId: UInt32
    ) {
        self.type = type
        self.joinKey = joinKey
        self.payload2 = payload2
        self.payload3 = payload3
        self.linkType = linkType
        self.linkTargetId = linkTargetId
    }
}

/// A topological marker↔bar anchor produced from the Song Node Graph.
///
/// Each anchor represents one `rec[1]` value that appears in BOTH a type-14
/// (marker domain) node and a type-20 (bar domain) node — the structural
/// intersection established in `RE_FINDINGS.md`.
///
/// `markerOid` is populated when the join key matches the observed
/// arrangement marker OID set `{4, 8, 12, 16, 20, 24, 28, 32, 36}`. When the
/// join key does not match a known marker OID, `markerOid` is `nil`.
///
/// `barSequence` is the position of the matching type-20 node inside the
/// ascending (sorted by join key) list of type-20 nodes. Callers can use this
/// as a relative ordering hint, not as an absolute bar number.
public struct MarkerBarAnchor: Sendable, Codable, Equatable, Hashable {
    /// Shared join key (`rec[1]`) that appears in both a type-14 and a
    /// type-20 node.
    public let joinKey: UInt32
    /// Optional arrangement-marker OID, set when `joinKey` is a member of
    /// the observed arrangement marker OID set.
    public let markerOid: UInt32?
    /// Zero-based index of the matching type-20 node in the sorted type-20
    /// chain.
    public let barSequence: Int

    public init(joinKey: UInt32, markerOid: UInt32?, barSequence: Int) {
        self.joinKey = joinKey
        self.markerOid = markerOid
        self.barSequence = barSequence
    }
}

/// Pure Swift decoder for Logic Pro's Song Node Graph.
///
/// This decoder is intentionally topological-only. It does not attempt to
/// translate opaque payload fields into bar numbers or ticks — see
/// `RE_FINDINGS.md` for the analysis that established the payload fields as
/// hashes referencing runtime objects not serialized in the file.
public enum SongGraphDecoder {

    /// Observed set of arrangement marker OIDs (`RE_FINDINGS.md`).
    /// When a node's join key matches a value in this set, we annotate the
    /// emitted anchor with that OID.
    public static let knownMarkerOids: Set<UInt32> = [4, 8, 12, 16, 20, 24, 28, 32, 36]

    // MARK: - Public API

    /// Decode a ProjectData blob into its Song Node Graph.
    ///
    /// - Parameter data: The raw ProjectData bytes. The caller is responsible
    ///   for reading the file; this function does not perform I/O.
    /// - Returns: `nodes` — all type-14 / type-20 records observed across
    ///   every Song chunk at the best alignment per chunk. `anchors` — one
    ///   entry per join key that appears in both domains.
    public static func decode(data: Data) -> (nodes: [SongNode], anchors: [MarkerBarAnchor]) {
        let chunks = scanChunks(data: data)

        var allNodes: [SongNode] = []
        for chunk in chunks where chunk.id == "Song" {
            guard chunk.bodyLength > 0,
                  chunk.bodyOffset + chunk.bodyLength <= data.count
            else { continue }

            let body = data.subdata(
                in: chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)
            )
            allNodes.append(contentsOf: bestNodes(in: body))
        }

        let anchors = buildAnchors(from: allNodes)
        return (allNodes, anchors)
    }

    // MARK: - Node Extraction

    /// Probe each 4-byte alignment in `0..<24` and pick the one with the most
    /// nodes passing the validity gate.
    private static func bestNodes(in body: Data) -> [SongNode] {
        var bestScore = 0
        var bestNodes: [SongNode] = []

        for alignment in 0..<24 {
            let nodes = extractNodes(body: body, alignment: alignment)
            // Score: valid type-14 + type-20 records. extractNodes() already
            // filters by validity so every returned node contributes.
            let score = nodes.count
            if score > bestScore {
                bestScore = score
                bestNodes = nodes
            }
        }

        return bestNodes
    }

    /// Extract all valid 24-byte (u32x6) node records from a Song chunk body
    /// starting at `alignment` and advancing by `recordSize` per record. A
    /// record is considered valid when:
    ///   - rec[0] (type) is 14 or 20
    ///   - rec[1] (joinKey) is in (0, 10_000)
    ///   - rec[4] (linkType) is in {0, 14, 20}
    ///
    /// These bounds are taken directly from `RE_FINDINGS.md`. The outer
    /// alignment probe (in `bestNodes`) tries every starting offset in
    /// `0..<24`; within a chosen alignment, records live on 24-byte
    /// boundaries.
    private static func extractNodes(body: Data, alignment: Int) -> [SongNode] {
        var nodes: [SongNode] = []
        let recordSize = 24
        var offset = alignment

        while offset + recordSize <= body.count {
            let r0 = readLE32(body, at: offset + 0)
            let r1 = readLE32(body, at: offset + 4)
            let r2 = readLE32(body, at: offset + 8)
            let r3 = readLE32(body, at: offset + 12)
            let r4 = readLE32(body, at: offset + 16)
            let r5 = readLE32(body, at: offset + 20)

            if (r0 == 14 || r0 == 20),
               r1 > 0, r1 < 10_000,
               (r4 == 0 || r4 == 14 || r4 == 20) {
                nodes.append(SongNode(
                    type: r0,
                    joinKey: r1,
                    payload2: r2,
                    payload3: r3,
                    linkType: r4,
                    linkTargetId: r5
                ))
            }
            offset += recordSize
        }

        return nodes
    }

    // MARK: - Anchor Building

    /// Build the topological marker↔bar anchors.
    ///
    /// A join key that appears in both the type-14 set and the type-20 set
    /// yields one anchor. `barSequence` is the index of the matching type-20
    /// node in the join-key-sorted list of type-20 nodes.
    private static func buildAnchors(from nodes: [SongNode]) -> [MarkerBarAnchor] {
        let type14Keys = Set(nodes.lazy.filter { $0.type == 14 }.map { $0.joinKey })
        let type20Nodes = nodes.filter { $0.type == 20 }

        // Sort type-20 nodes by join key to derive a stable bar sequence.
        // When the same join key appears multiple times in type-20, first
        // occurrence wins (matches the common Data Node / Link Node split
        // described in RE_FINDINGS.md).
        let sortedType20 = type20Nodes.sorted { $0.joinKey < $1.joinKey }
        var firstIndexByKey: [UInt32: Int] = [:]
        for (index, node) in sortedType20.enumerated() where firstIndexByKey[node.joinKey] == nil {
            firstIndexByKey[node.joinKey] = index
        }

        var anchors: [MarkerBarAnchor] = []
        // Emit anchors in ascending join-key order for deterministic output.
        for joinKey in firstIndexByKey.keys.sorted() where type14Keys.contains(joinKey) {
            guard let barSeq = firstIndexByKey[joinKey] else { continue }
            let oid: UInt32? = knownMarkerOids.contains(joinKey) ? joinKey : nil
            anchors.append(MarkerBarAnchor(
                joinKey: joinKey,
                markerOid: oid,
                barSequence: barSeq
            ))
        }
        return anchors
    }

    // MARK: - Chunk Scanning (copied from ProjectDataParser)

    private struct ChunkInfo {
        let id: String
        let oid: UInt32
        let bodyOffset: Int
        let bodyLength: Int
    }

    private static let chunkHeaderSize = 36
    private static let anchorOffset = 0x16
    private static let oidOffset = 0x0A
    private static let lengthOffset = 0x1C

    /// Scan the entire data blob for valid chunks using the anchor-signature
    /// method documented in `ProjectDataParser` and `LOGIC_BINARY_SPEC.md`.
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
            guard bodyLength >= 0, bodyStart + bodyLength <= total else {
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
