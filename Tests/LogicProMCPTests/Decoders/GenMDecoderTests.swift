import XCTest
@testable import LogicProMCP

/// Integration tests for `GenMDecoder` against the bundled real Logic Pro
/// project fixtures at the repository root.
///
/// GenM chunks encode Logic's arrangement-marker title list as an
/// `NSKeyedArchiver` bplist. Only some projects ship one (observed: project 1
/// and project 3 do not; project 2 does, with seven named slots).
final class GenMDecoderTests: XCTestCase {

    private static func samplesRoot() -> String {
        if let root = ProcessInfo.processInfo.environment["LOGIC_SAMPLES_ROOT"],
           !root.isEmpty {
            return root
        }
        return "/Users/alan1/Projects/logic-pro-mcp"
    }

    private static func projectPath(_ index: Int) -> String {
        return "\(samplesRoot())/logic-project-\(index).logicx"
    }

    private static func loadProjectData(_ index: Int) throws -> Data {
        let logicx = projectPath(index)
        guard FileManager.default.fileExists(atPath: logicx) else {
            throw XCTSkip("Missing fixture: \(logicx)")
        }
        let url = URL(fileURLWithPath: logicx)
        let altRoot = url.appendingPathComponent("Alternatives")
        for i in 0...9 {
            let candidate = altRoot
                .appendingPathComponent(String(format: "%03d", i))
                .appendingPathComponent("ProjectData")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
        }
        throw XCTSkip("No ProjectData in \(logicx)")
    }

    /// Project 1 does not contain a GenM chunk — the decoder must return an
    /// empty list without throwing.
    func testProject1HasNoArrangementMarkerTitles() throws {
        let data = try Self.loadProjectData(1)
        let titles = GenMDecoder.decode(data: data)
        XCTAssertTrue(
            titles.isEmpty,
            "Project 1 has no GenM chunk; expected empty list, got \(titles)"
        )
    }

    /// Project 2 contains a single GenM chunk with user-defined names
    /// "Intro", "Verse", "Chorus", "Bridge". Assert the decoded set contains
    /// the canonical Logic arrangement-marker names.
    func testProject2DecodesKnownArrangementMarkerTitles() throws {
        let data = try Self.loadProjectData(2)
        let titles = GenMDecoder.decode(data: data)
        XCTAssertFalse(
            titles.isEmpty,
            "Project 2 should have a GenM chunk with arrangement-marker titles"
        )

        let names = Set(titles.compactMap { $0.name })
        // Canonical arrangement marker names observed in project 2.
        XCTAssertTrue(
            names.contains("Intro"),
            "Expected 'Intro' in decoded names: \(names)"
        )
        XCTAssertTrue(
            names.contains("Chorus"),
            "Expected 'Chorus' in decoded names: \(names)"
        )
        XCTAssertTrue(
            names.contains("Verse"),
            "Expected 'Verse' in decoded names: \(names)"
        )
        XCTAssertTrue(
            names.contains("Bridge"),
            "Expected 'Bridge' in decoded names: \(names)"
        )

        // Slot indices should be unique and sorted ascending.
        let slotIndices = titles.map { $0.slotIndex }
        XCTAssertEqual(
            Set(slotIndices).count,
            slotIndices.count,
            "Slot indices should be unique: \(slotIndices)"
        )
        XCTAssertEqual(
            slotIndices,
            slotIndices.sorted(),
            "Titles should come back sorted by slotIndex"
        )

        // At least one typed entry (type > 0) should carry a name, confirming
        // that the type/name resolution actually landed on real data.
        let typedNamed = titles.filter { $0.type > 0 && $0.name != nil }
        XCTAssertFalse(
            typedNamed.isEmpty,
            "Expected at least one entry with type>0 and a non-nil name"
        )
    }

    /// Project 3 does not contain a GenM chunk. Decoding must still succeed
    /// and return an empty list.
    func testProject3DecodesWithoutError() throws {
        let data = try Self.loadProjectData(3)
        let titles = GenMDecoder.decode(data: data)
        XCTAssertTrue(
            titles.isEmpty,
            "Project 3 has no GenM chunk; expected empty list, got \(titles)"
        )
    }

    /// The path-based overload should produce the same result as the
    /// data-based one for the same fixture.
    func testPathOverloadMatchesDataOverload() throws {
        let data = try Self.loadProjectData(2)
        let fromData = GenMDecoder.decode(data: data)
        let fromPath = GenMDecoder.decode(path: Self.projectPath(2))
        XCTAssertEqual(
            fromData,
            fromPath,
            "Path-based decode should match data-based decode"
        )
    }
}
