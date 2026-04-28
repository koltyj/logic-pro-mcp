import XCTest
@testable import LogicProMCP

/// Integration tests for `ScoreSetDecoder`.
///
/// These tests load each of the three bundled `.logicx` fixtures, extract
/// the raw `ProjectData` blob, and assert that the decoder surfaces exactly
/// one `ScSt` score set (oid=12) and one `InSt` root (oid=0, label
/// "Score Set") per project. At least one project must surface the
/// instrument entry "Guitar".
final class ScoreSetDecoderTests: XCTestCase {

    // MARK: Fixtures

    /// The three sample `.logicx` projects shipped at the repo root.
    private static let projectPaths: [String] = [
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-2.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-3.logicx",
    ]

    // MARK: Helpers

    /// Locate the `ProjectData` inside a `.logicx` bundle. Tries the numbered
    /// Alternatives (000..009) first, then falls back to a directory scan.
    private func loadProjectData(at logicxPath: String) throws -> Data {
        let base = URL(fileURLWithPath: logicxPath)
            .appendingPathComponent("Alternatives")

        for i in 0...9 {
            let candidate = base
                .appendingPathComponent(String(format: "%03d", i))
                .appendingPathComponent("ProjectData")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
        }

        if let entries = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
            for entry in entries.sorted() {
                let candidate = base
                    .appendingPathComponent(entry)
                    .appendingPathComponent("ProjectData")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return try Data(contentsOf: candidate)
                }
            }
        }

        throw XCTSkip("No ProjectData found under \(logicxPath)")
    }

    // MARK: Tests

    /// Every fixture must yield exactly one `InSt` root labeled "Score Set".
    func testInstRootLabelAcrossProjects() throws {
        var anyParsed = false
        for path in Self.projectPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                print("[ScoreSetDecoderTests] Skipping missing project: \(path)")
                continue
            }
            let data = try loadProjectData(at: path)
            let (_, roots) = ScoreSetDecoder.decode(data: data)
            anyParsed = true

            XCTAssertEqual(roots.count, 1, "Expected exactly one InSt root for \(path)")
            XCTAssertEqual(
                roots.first?.label,
                "Score Set",
                "Expected InSt label == \"Score Set\" for \(path) (got \(roots.first?.label ?? "<nil>"))"
            )
            XCTAssertEqual(roots.first?.oid, 0, "Expected InSt oid=0 for \(path)")
        }
        XCTAssertTrue(anyParsed, "No fixture projects were parseable")
    }

    /// Every fixture must yield exactly one `ScSt` score set with oid=12.
    func testScoreSetCountAndOidAcrossProjects() throws {
        var anyParsed = false
        for path in Self.projectPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let data = try loadProjectData(at: path)
            let (sets, _) = ScoreSetDecoder.decode(data: data)
            anyParsed = true

            XCTAssertEqual(sets.count, 1, "Expected exactly one ScSt score set for \(path)")
            XCTAssertEqual(sets.first?.oid, 12, "Expected ScSt oid=12 for \(path)")
            XCTAssertFalse(
                sets.first?.rootName.isEmpty ?? true,
                "ScSt rootName should be non-empty for \(path)"
            )
        }
        XCTAssertTrue(anyParsed, "No fixture projects were parseable")
    }

    /// `logic-project-1.logicx` must expose the "Guitar" instrument entry in
    /// its score set (as either the root title or an instrument name). This
    /// exercises the ASCII-scan path end-to-end.
    func testScoreSetContainsGuitarForProject1() throws {
        let path = "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("logic-project-1.logicx not found at \(path)")
        }
        let data = try loadProjectData(at: path)
        let (sets, _) = ScoreSetDecoder.decode(data: data)

        guard let set = sets.first else {
            XCTFail("No score set decoded for \(path)")
            return
        }

        let allEntries: [String] = [set.rootName] + set.instrumentNames
        XCTAssertTrue(
            allEntries.contains("Guitar"),
            "Expected \"Guitar\" among decoded entries \(allEntries)"
        )
    }
}
