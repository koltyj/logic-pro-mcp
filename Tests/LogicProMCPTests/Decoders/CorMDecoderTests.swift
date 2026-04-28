import XCTest
@testable import LogicProMCP

/// Integration tests for the `CorM` CoreMIDI port-table decoder.
///
/// Assertions are driven by the three bundled `.logicx` sample projects at
/// the repository root. Known values from the reverse-engineering session:
///
/// - Every project contains exactly 2 `CorM` chunks (OIDs 232 and 236 —
///   input and output port tables respectively).
/// - `logic-project-2` has 2 ports per table; its OID=232 record names
///   (`UMC1820`, `Logic Pro Virtual In`) and OID=236 second-port name
///   (`Logic Pro Virtual Out`) are stable across decodes.
/// - `logic-project-1` and `logic-project-3` each have 1 port per table
///   containing the string `"USB MIDI Device"`.
final class CorMDecoderTests: XCTestCase {

    /// Absolute paths to the fixture `.logicx` bundles. Matches the convention
    /// established by `LayrParseTest`.
    private static let projectPaths: [String] = [
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-2.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-3.logicx",
    ]

    // MARK: - Helpers

    /// Return the raw `ProjectData` bytes for a `.logicx` bundle, or nil if
    /// the fixture is not present in this checkout (e.g. running on CI).
    private func loadProjectData(logicxPath: String) -> Data? {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: logicxPath)
            .appendingPathComponent("Alternatives")

        for index in 0...9 {
            let suffix = String(format: "%03d", index)
            let candidate = base
                .appendingPathComponent(suffix)
                .appendingPathComponent("ProjectData")
            if fm.fileExists(atPath: candidate.path) {
                return try? Data(contentsOf: candidate)
            }
        }
        return nil
    }

    /// Decode one fixture — throws XCTSkip when the fixture is missing so a
    /// shallow checkout doesn't fail the suite.
    private func decode(_ path: String) throws -> [CorMDecoder.CorMRecord] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Missing fixture: \(path)")
        }
        guard let data = loadProjectData(logicxPath: path) else {
            throw XCTSkip("Could not load ProjectData inside: \(path)")
        }
        return CorMDecoder.decode(data: data)
    }

    // MARK: - Tests

    /// Every project should decode to exactly 2 `CorM` records (one input
    /// table at OID 232, one output table at OID 236).
    func testEveryProjectHasTwoCorMChunks() throws {
        var sawAny = false
        for path in Self.projectPaths {
            let records: [CorMDecoder.CorMRecord]
            do {
                records = try decode(path)
            } catch {
                // XCTSkip or similar — tolerate missing fixtures.
                continue
            }
            sawAny = true
            XCTAssertEqual(
                records.count, 2,
                "\(path): expected exactly 2 CorM records, got \(records.count)"
            )
            let oids = Set(records.map { $0.oid })
            XCTAssertEqual(
                oids, [232, 236],
                "\(path): expected CorM OIDs {232, 236}, got \(oids)"
            )
        }
        XCTAssertTrue(
            sawAny,
            "No fixture projects could be opened — ensure logic-project-{1,2,3}.logicx exist"
        )
    }

    /// `logic-project-2` has the richer layout — two ports per table with
    /// well-known names from the reverse-engineering session.
    func testLogicProject2KnownPortNames() throws {
        let path = "/Users/alan1/Projects/logic-pro-mcp/logic-project-2.logicx"
        let records = try decode(path)

        guard let inputRecord = records.first(where: { $0.oid == 232 }) else {
            return XCTFail("logic-project-2: no CorM record for oid=232")
        }
        XCTAssertEqual(
            inputRecord.ports.count, 2,
            "logic-project-2 oid=232: expected 2 ports"
        )
        XCTAssertEqual(
            inputRecord.ports[0].name, "UMC1820",
            "logic-project-2 oid=232 port[0].name mismatch"
        )
        XCTAssertEqual(
            inputRecord.ports[1].name, "Logic Pro Virtual In",
            "logic-project-2 oid=232 port[1].name mismatch"
        )

        guard let outputRecord = records.first(where: { $0.oid == 236 }) else {
            return XCTFail("logic-project-2: no CorM record for oid=236")
        }
        XCTAssertGreaterThanOrEqual(
            outputRecord.ports.count, 2,
            "logic-project-2 oid=236: expected at least 2 ports"
        )
        XCTAssertEqual(
            outputRecord.ports[1].name, "Logic Pro Virtual Out",
            "logic-project-2 oid=236 port[1].name mismatch"
        )
    }

    /// For every parsed port across every fixture, the name must be
    /// non-empty printable ASCII. This guards against the hash-prefix bug
    /// where the 4-byte hash in front of the name can contain printable
    /// bytes that bleed into the decoded string.
    func testAllPortNamesAreNonEmptyAscii() throws {
        var sawAny = false
        for path in Self.projectPaths {
            let records: [CorMDecoder.CorMRecord]
            do {
                records = try decode(path)
            } catch {
                continue
            }
            sawAny = true

            for record in records {
                for port in record.ports {
                    XCTAssertFalse(
                        port.name.isEmpty,
                        "\(path) oid=\(record.oid): port name should not be empty"
                    )
                    XCTAssertTrue(
                        port.name.allSatisfy { ch in
                            guard let scalar = ch.unicodeScalars.first else { return false }
                            return scalar.isASCII && scalar.value >= 0x20 && scalar.value <= 0x7E
                        },
                        "\(path) oid=\(record.oid): port name \(port.name) must be printable ASCII"
                    )
                }
            }
        }
        XCTAssertTrue(sawAny, "No fixtures available to validate port names")
    }
}
