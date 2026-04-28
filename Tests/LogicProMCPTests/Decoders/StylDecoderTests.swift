import XCTest
@testable import LogicProMCP

/// Integration tests for `StylDecoder`.
///
/// These tests operate on the three stock `.logicx` fixtures at the repository
/// root. Every stock project ships with the same 32 built-in Score Style
/// definitions, so `decode` must return exactly 32 records for each project.
///
/// Specific known records in `logic-project-1.logicx` are spot-checked by OID
/// and label to catch regressions in the length-prefix scan or marker search.
final class StylDecoderTests: XCTestCase {

    /// Candidate `.logicx` fixtures. Paths are absolute so the test suite is
    /// indifferent to the CWD chosen by `swift test` or Xcode.
    private static let projectPaths: [String] = [
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-2.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-3.logicx",
    ]

    // MARK: - Helpers

    /// Locate a readable `ProjectData` file inside a `.logicx` bundle.
    /// Mirrors the same Alternatives scan used by `ProjectDataParser`.
    private func loadProjectData(at logicxPath: String) throws -> Data? {
        let logicxURL = URL(fileURLWithPath: logicxPath)
        let altRoot = logicxURL.appendingPathComponent("Alternatives")
        let fm = FileManager.default

        for index in 0...9 {
            let indexStr = String(format: "%03d", index)
            let candidate = altRoot
                .appendingPathComponent(indexStr)
                .appendingPathComponent("ProjectData")
            if fm.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
        }

        if let entries = try? fm.contentsOfDirectory(atPath: altRoot.path) {
            for entry in entries.sorted() {
                let candidate = altRoot
                    .appendingPathComponent(entry)
                    .appendingPathComponent("ProjectData")
                if fm.fileExists(atPath: candidate.path) {
                    return try Data(contentsOf: candidate)
                }
            }
        }
        return nil
    }

    // MARK: - Tests

    /// Every stock project must contain exactly 32 Score Style definitions.
    /// Also asserts that every decoded label is non-empty.
    func testDecodeReturnsExactly32RecordsForEachProject() throws {
        var sawAnyProject = false

        for path in Self.projectPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                print("[StylDecoderTests] Skipping missing project: \(path)")
                continue
            }
            guard let data = try loadProjectData(at: path) else {
                XCTFail("Could not load ProjectData from \(path)")
                continue
            }
            sawAnyProject = true

            let records = StylDecoder.decode(data: data)
            print("[StylDecoderTests] \(path): \(records.count) Styl record(s)")

            XCTAssertEqual(
                records.count,
                32,
                "Expected 32 Styl records in \(path), got \(records.count)"
            )

            for record in records {
                XCTAssertFalse(
                    record.label.isEmpty,
                    "Decoded Styl label must not be empty (oid=\(record.oid))"
                )
            }
        }

        XCTAssertTrue(
            sawAnyProject,
            "No fixture projects could be loaded — ensure logic-project-{1,2,3}.logicx exist"
        )
    }

    /// Spot-check specific OIDs in logic-project-1 against the ground-truth
    /// catalog captured while reverse-engineering the Styl layout.
    func testLogicProject1SpecificOIDs() throws {
        let path = "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("logic-project-1.logicx not available")
        }
        guard let data = try loadProjectData(at: path) else {
            XCTFail("Could not load ProjectData from \(path)")
            return
        }

        let records = StylDecoder.decode(data: data)
        let byOid = Dictionary(uniqueKeysWithValues: records.map { ($0.oid, $0) })

        // oid=8 → "Piano 1/3" (may carry binary artefact bytes either side of
        // the ASCII run; compare after whitespace trim per the plan).
        guard let r8 = byOid[8] else {
            XCTFail("Missing Styl record with oid=8 (expected \"Piano 1/3\")")
            return
        }
        XCTAssertEqual(
            r8.label.trimmingCharacters(in: .whitespaces),
            "Piano 1/3",
            "oid=8 label should trim to \"Piano 1/3\", got \"\(r8.label)\""
        )

        // oid=108 → "Drums" (exact match).
        guard let r108 = byOid[108] else {
            XCTFail("Missing Styl record with oid=108 (expected \"Drums\")")
            return
        }
        XCTAssertEqual(r108.label, "Drums", "oid=108 should decode to exactly \"Drums\"")

        // oid=52 → "Trumpet in B" (exact match).
        guard let r52 = byOid[52] else {
            XCTFail("Missing Styl record with oid=52 (expected \"Trumpet in B\")")
            return
        }
        XCTAssertEqual(
            r52.label,
            "Trumpet in B",
            "oid=52 should decode to exactly \"Trumpet in B\""
        )
    }
}
