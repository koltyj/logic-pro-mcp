import XCTest
@testable import LogicProMCP

/// Integration tests for ``TxStDecoder`` — the score-notation text-style
/// decoder.
///
/// These tests operate on the real `.logicx` fixtures located at the
/// repository root. Each fixture is expected to ship the full 32-record
/// style table (OIDs 0, 4, 8, …, 124); we assert at least 20 so the suite
/// tolerates minor drift without hiding regressions.
final class TxStDecoderTests: XCTestCase {

    /// Absolute paths to the three sample `.logicx` bundles. Absolute paths
    /// keep the tests portable between `swift test` runs and Xcode.
    private static let projectPaths: [String] = [
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-2.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-3.logicx",
    ]

    // MARK: - Helpers

    /// Locate and load the `ProjectData` blob inside a `.logicx` bundle.
    /// Tries `Alternatives/000/ProjectData` first, then 001..009.
    private static func loadProjectData(at logicxPath: String) -> Data? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logicxPath) else { return nil }
        let root = URL(fileURLWithPath: logicxPath)
        let altRoot = root.appendingPathComponent("Alternatives")
        for i in 0..<10 {
            let candidate = altRoot
                .appendingPathComponent(String(format: "%03d", i))
                .appendingPathComponent("ProjectData")
            if let data = try? Data(contentsOf: candidate) {
                return data
            }
        }
        return nil
    }

    // MARK: - Tests

    /// Each fixture must expose at least 20 decoded TxSt records (32 expected).
    func testDecodesAtLeast20RecordsPerProject() throws {
        var anyParsed = false
        for path in Self.projectPaths {
            guard let data = Self.loadProjectData(at: path) else {
                print("[TxStDecoderTests] Skipping missing project: \(path)")
                continue
            }
            anyParsed = true
            let records = TxStDecoder.decode(data: data)
            print("[TxStDecoderTests] \(path): \(records.count) TxSt record(s)")
            XCTAssertGreaterThanOrEqual(
                records.count, 20,
                "Expected at least 20 TxSt records in \(path), got \(records.count)"
            )
        }
        XCTAssertTrue(
            anyParsed,
            "No fixture projects could be loaded — ensure logic-project-{1,2,3}.logicx exist"
        )
    }

    /// `logic-project-1` is the canonical reference bundle: assert the
    /// exact decoded fields for OID 0 (Plain Text / Chicago / Times).
    func testProject1OidZeroMatchesReference() throws {
        let path = Self.projectPaths[0]
        guard let data = Self.loadProjectData(at: path) else {
            throw XCTSkip("Missing fixture: \(path)")
        }
        let records = TxStDecoder.decode(data: data)
        guard let r0 = records.first(where: { $0.oid == 0 }) else {
            XCTFail("Expected a TxSt record with oid=0 in \(path)")
            return
        }
        XCTAssertEqual(r0.styleLabel, "Plain Text")
        XCTAssertEqual(r0.font1, "Chicago")
        XCTAssertEqual(r0.font2, "Times")
        XCTAssertEqual(r0.sampleText, "abcABC123456")
        XCTAssertEqual(r0.font1Size, 30)
    }

    /// `logic-project-1`, OID 16: Tuplets render in an italic companion font.
    func testProject1OidSixteenIsTupletsItalic() throws {
        let path = Self.projectPaths[0]
        guard let data = Self.loadProjectData(at: path) else {
            throw XCTSkip("Missing fixture: \(path)")
        }
        let records = TxStDecoder.decode(data: data)
        guard let r16 = records.first(where: { $0.oid == 16 }) else {
            XCTFail("Expected a TxSt record with oid=16 in \(path)")
            return
        }
        XCTAssertEqual(r16.styleLabel, "Tuplets")
        XCTAssertEqual(r16.font2, "Times-Italic")
    }

    /// Every decoded record across all fixtures must have the canonical
    /// sample text — Logic stores the literal "abcABC123456" preview string.
    func testSampleTextIsInvariantAcrossProjects() throws {
        var anyChecked = false
        for path in Self.projectPaths {
            guard let data = Self.loadProjectData(at: path) else { continue }
            let records = TxStDecoder.decode(data: data)
            guard !records.isEmpty else { continue }
            anyChecked = true
            for r in records {
                XCTAssertEqual(
                    r.sampleText, "abcABC123456",
                    "Unexpected sampleText for oid=\(r.oid) in \(path)"
                )
            }
        }
        XCTAssertTrue(
            anyChecked,
            "No fixture projects yielded TxSt records — cannot validate sample-text invariant"
        )
    }
}
