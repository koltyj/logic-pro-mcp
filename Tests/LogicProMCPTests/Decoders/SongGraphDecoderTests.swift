import XCTest
@testable import LogicProMCP

/// Integration and unit tests for `SongGraphDecoder`.
///
/// The decoder is topology-only: it exposes every valid type-14 / type-20
/// record inside every `Song` chunk and emits one `MarkerBarAnchor` per
/// join key that appears in both domains.
///
/// The three committed `.logicx` fixtures each contain a small `Song`
/// chunk (~3716 bytes) but none of them happen to carry the full
/// `u32x6` node-graph structure described in `reference/RE_FINDINGS.md`
/// (that section was written against a larger snapshot, len=55796). The
/// integration tests therefore assert only the invariants that must hold
/// regardless of whether the graph is populated:
///
/// - The decoder runs without error on every fixture.
/// - Every emitted node passes the validity gate the decoder promises.
/// - Every emitted anchor satisfies the topological contract.
/// - The union of marker OIDs surfaced across fixtures is permitted to be
///   empty when the input does not contain the graph.
///
/// A synthetic unit test exercises the full decode pipeline against a
/// hand-built ProjectData blob that does contain the graph, proving the
/// topological join implementation is correct independently of the bundled
/// fixtures.
final class SongGraphDecoderTests: XCTestCase {

    // MARK: - Fixtures

    private static let projectPaths: [String] = [
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-2.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-3.logicx",
    ]

    private static let knownMarkerOids: Set<UInt32> = [4, 8, 12, 16, 20, 24, 28, 32, 36]

    // MARK: - Helpers

    private func findProjectData(in logicxPath: String) -> URL? {
        let base = URL(fileURLWithPath: logicxPath)
            .appendingPathComponent("Alternatives")
        let fm = FileManager.default

        for index in 0...9 {
            let candidate = base
                .appendingPathComponent(String(format: "%03d", index))
                .appendingPathComponent("ProjectData")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        if let entries = try? fm.contentsOfDirectory(atPath: base.path) {
            for entry in entries.sorted() {
                let candidate = base
                    .appendingPathComponent(entry)
                    .appendingPathComponent("ProjectData")
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    private func decode(path: String) -> (nodes: [SongNode], anchors: [MarkerBarAnchor])? {
        guard FileManager.default.fileExists(atPath: path) else {
            print("[SongGraphDecoderTests] Skipping missing project: \(path)")
            return nil
        }
        guard let pdURL = findProjectData(in: path) else {
            print("[SongGraphDecoderTests] No ProjectData found inside: \(path)")
            return nil
        }
        guard let data = try? Data(contentsOf: pdURL) else {
            print("[SongGraphDecoderTests] Failed to read: \(pdURL.path)")
            return nil
        }
        return SongGraphDecoder.decode(data: data)
    }

    // MARK: - Integration Tests (real fixtures)

    /// Every parseable fixture decodes without crashing. Whatever nodes
    /// are emitted must satisfy the decoder's validity gate; whatever
    /// anchors are emitted must satisfy the topological contract.
    func testDecoderInvariantsAcrossFixtures() throws {
        var anyParsed = false

        for path in Self.projectPaths {
            guard let (nodes, anchors) = decode(path: path) else { continue }
            anyParsed = true

            let type14Count = nodes.filter { $0.type == 14 }.count
            let type20Count = nodes.filter { $0.type == 20 }.count
            print("""
            [SongGraphDecoderTests] \(path):
              nodes=\(nodes.count) (type14=\(type14Count), type20=\(type20Count))
              anchors=\(anchors.count)
            """)

            // Every node must obey the validity gate the decoder promises.
            for node in nodes {
                XCTAssertTrue(
                    node.type == 14 || node.type == 20,
                    "Node type must be 14 or 20, got \(node.type) in \(path)"
                )
                XCTAssertTrue(
                    node.joinKey > 0 && node.joinKey < 10_000,
                    "Node joinKey \(node.joinKey) out of range in \(path)"
                )
                XCTAssertTrue(
                    node.linkType == 0 || node.linkType == 14 || node.linkType == 20,
                    "Node linkType \(node.linkType) not in {0,14,20} in \(path)"
                )
            }

            // Every anchor must obey the topological contract.
            let type14Keys = Set(nodes.filter { $0.type == 14 }.map { $0.joinKey })
            let type20Keys = Set(nodes.filter { $0.type == 20 }.map { $0.joinKey })
            for anchor in anchors {
                XCTAssertTrue(type14Keys.contains(anchor.joinKey))
                XCTAssertTrue(type20Keys.contains(anchor.joinKey))
                if let oid = anchor.markerOid {
                    XCTAssertTrue(Self.knownMarkerOids.contains(oid))
                    XCTAssertEqual(oid, anchor.joinKey)
                }
                XCTAssertGreaterThanOrEqual(anchor.barSequence, 0)
                XCTAssertLessThan(anchor.barSequence, type20Count)
            }
        }

        XCTAssertTrue(
            anyParsed,
            "No fixture projects could be parsed — ensure logic-project-{1,2,3}.logicx exist"
        )
    }

    /// The union of marker OIDs surfaced via anchors across all three
    /// fixtures is allowed to be empty (per the "no markers in this set
    /// for this project" carve-out in the unit plan), but when an anchor
    /// has `markerOid` set it must be a member of `knownMarkerOids`.
    func testSongGraphMarkerOidUnionIsSoftBounded() throws {
        var unionMarkerOids = Set<UInt32>()
        var anyParsed = false

        for path in Self.projectPaths {
            guard let (_, anchors) = decode(path: path) else { continue }
            anyParsed = true
            for anchor in anchors {
                if let oid = anchor.markerOid {
                    XCTAssertTrue(
                        Self.knownMarkerOids.contains(oid),
                        "markerOid \(oid) not in known set for \(path)"
                    )
                    unionMarkerOids.insert(oid)
                }
            }
        }

        guard anyParsed else {
            throw XCTSkip("No parseable fixture projects available")
        }

        // Soft bound: empty is allowed. Anything non-empty must be a subset.
        XCTAssertTrue(
            unionMarkerOids.isSubset(of: Self.knownMarkerOids),
            "Marker OID union \(unionMarkerOids) must be a subset of \(Self.knownMarkerOids)"
        )
    }

    /// Empty input must produce an empty graph.
    func testDecodeEmptyDataReturnsEmptyGraph() {
        let (nodes, anchors) = SongGraphDecoder.decode(data: Data())
        XCTAssertTrue(nodes.isEmpty)
        XCTAssertTrue(anchors.isEmpty)
    }

    // MARK: - Synthetic Unit Test

    /// Build a minimal ProjectData blob whose sole chunk is a `Song`
    /// chunk carrying a hand-crafted node graph. This exercises the
    /// decoder end-to-end — chunk scanner, alignment probing, node
    /// validity gating, and topological-join emission — on a payload we
    /// control, independent of the bundled fixtures.
    func testDecodeSyntheticSongGraph() throws {
        // Build six 24-byte records (u32x6):
        //   type=14, key=4 , payload=(0,0), link=(14, 8)    (marker chain head)
        //   type=14, key=8 , payload=(0,0), link=(14, 12)
        //   type=14, key=12, payload=(0,0), link=(0, 0)
        //   type=20, key=4 , payload=(0xDEAD, 0xBEEF), link=(20, 8)  (bar chain)
        //   type=20, key=8 , payload=(0,0), link=(20, 12)
        //   type=20, key=12, payload=(0,0), link=(0, 0)
        let records: [[UInt32]] = [
            [14,  4, 0,          0,          14, 8 ],
            [14,  8, 0,          0,          14, 12],
            [14, 12, 0,          0,           0, 0 ],
            [20,  4, 0xDEADBEEF, 0xF016884F, 20, 8 ],
            [20,  8, 0,          0,          20, 12],
            [20, 12, 0,          0,           0, 0 ],
        ]

        var body = Data()
        for rec in records {
            for word in rec {
                var le = word.littleEndian
                withUnsafeBytes(of: &le) { body.append(contentsOf: $0) }
            }
        }
        XCTAssertEqual(body.count, 24 * records.count)

        // Wrap body in a minimal ProjectData blob: magic + one Song chunk.
        let blob = Self.makeProjectDataBlob(chunkID: "Song", body: body)
        let (nodes, anchors) = SongGraphDecoder.decode(data: blob)

        XCTAssertEqual(nodes.count, 6, "Expected 6 decoded nodes")
        XCTAssertEqual(nodes.filter { $0.type == 14 }.count, 3)
        XCTAssertEqual(nodes.filter { $0.type == 20 }.count, 3)

        // Three join keys (4, 8, 12) appear in both domains → three anchors.
        XCTAssertEqual(anchors.count, 3)
        XCTAssertEqual(anchors.map { $0.joinKey }, [4, 8, 12])
        // All three keys are in the known marker OID set.
        XCTAssertEqual(anchors.compactMap { $0.markerOid }, [4, 8, 12])
        // barSequence corresponds to the sorted type-20 index (0, 1, 2).
        XCTAssertEqual(anchors.map { $0.barSequence }, [0, 1, 2])

        // Spot-check payload fields survive round-trip.
        let node20_k4 = nodes.first { $0.type == 20 && $0.joinKey == 4 }
        XCTAssertEqual(node20_k4?.payload2, 0xDEADBEEF)
        XCTAssertEqual(node20_k4?.payload3, 0xF016884F)
    }

    // MARK: - Synthetic Blob Builder

    /// Produce a minimal ProjectData blob containing a single chunk with
    /// the given 4-character ID and body. Layout matches the 36-byte
    /// chunk header documented in `reference/LOGIC_BINARY_SPEC.md`.
    private static func makeProjectDataBlob(chunkID: String, body: Data) -> Data {
        precondition(chunkID.count == 4)

        var blob = Data()
        // Magic (4B) + 4B version-like filler to push chunks past offset 4.
        blob.append(contentsOf: [0x23, 0x47, 0xC0, 0xAB, 0x00, 0x00, 0x00, 0x00])

        // 36-byte chunk header.
        var header = Data(count: 36)

        // ID bytes are stored reversed on disk (e.g. "Song" → "gnoS").
        let idBytes = Array(chunkID.utf8).reversed()
        for (i, b) in idBytes.enumerated() { header[i] = b }

        // OID = 0 (offset 0x0A) — leave zero.

        // Anchor at 0x16: 02 00 00 00 01 00.
        header[0x16] = 0x02
        header[0x17] = 0x00
        header[0x18] = 0x00
        header[0x19] = 0x00
        header[0x1A] = 0x01
        header[0x1B] = 0x00

        // Body length at 0x1C (LE u64).
        var len = UInt64(body.count).littleEndian
        withUnsafeBytes(of: &len) { lenBytes in
            for i in 0..<8 { header[0x1C + i] = lenBytes[i] }
        }

        blob.append(header)
        blob.append(body)
        return blob
    }
}
