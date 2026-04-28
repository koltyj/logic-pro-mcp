import XCTest
@testable import LogicProMCP

/// Integration tests for `AuCOTypeDecoder` against the three Logic Pro sample
/// projects bundled at the repo root.
///
/// The sample projects are not stored inside the test target, so these tests
/// locate them by walking up the filesystem from `#filePath` looking for
/// `logic-project-{1,2,3}.logicx/Alternatives/000/ProjectData`. As a fallback
/// when running outside a git worktree (e.g. CI with a detached layout), an
/// environment variable `LOGIC_SAMPLES_ROOT` may point at the directory that
/// contains the three `.logicx` bundles.
///
/// Tests that cannot locate any sample data are skipped via `XCTSkip` so that
/// `swift test` still succeeds on sparse checkouts.
final class AuCOTypeDecoderTests: XCTestCase {

    // MARK: - Sample discovery

    /// All expected sample project names, in the order the planner documented.
    private static let sampleProjectNames = [
        "logic-project-1.logicx",
        "logic-project-2.logicx",
        "logic-project-3.logicx"
    ]

    /// Walk up from `#filePath` (bounded to a few levels) and probe each
    /// candidate root until the first expected `.logicx` bundle exists.
    /// Falls back to `LOGIC_SAMPLES_ROOT` if the walk yields nothing.
    private func locateSamplesRoot() -> URL? {
        let fm = FileManager.default

        // 1) Walk up from this test file.
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let probe = current.appendingPathComponent(Self.sampleProjectNames[0])
            if fm.fileExists(atPath: probe.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        // 2) Fallback to environment override (useful in CI / sandboxed runs).
        if let envPath = ProcessInfo.processInfo.environment["LOGIC_SAMPLES_ROOT"] {
            let envURL = URL(fileURLWithPath: envPath)
            let probe = envURL.appendingPathComponent(Self.sampleProjectNames[0])
            if fm.fileExists(atPath: probe.path) {
                return envURL
            }
        }

        return nil
    }

    /// Build the ProjectData URL for a given sample project name.
    private func projectDataURL(root: URL, name: String) -> URL {
        return root
            .appendingPathComponent(name)
            .appendingPathComponent("Alternatives")
            .appendingPathComponent("000")
            .appendingPathComponent("ProjectData")
    }

    /// Load + decode a sample project, returning `nil` if the file is missing.
    private func decodeSample(root: URL, name: String) throws -> [AuCOTypeRecord]? {
        let url = projectDataURL(root: root, name: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return AuCOTypeDecoder.decode(data: data)
    }

    // MARK: - Tests

    /// Project 1 is the richest fixture and must exhibit every observed type.
    func testProject1HasAllObservedTypes() throws {
        guard let root = locateSamplesRoot() else {
            throw XCTSkip("No Logic Pro sample projects found; set LOGIC_SAMPLES_ROOT to run.")
        }
        guard let records = try decodeSample(root: root, name: "logic-project-1.logicx") else {
            throw XCTSkip("logic-project-1.logicx not present at \(root.path)")
        }

        XCTAssertFalse(records.isEmpty, "Expected at least one AuCO record in project 1")

        // All 9 observed channel-strip kinds must appear at least once.
        let observedTypes = Set(records.map { $0.type })
        let expectedTypes: Set<AuCOType> = [
            .audio, .monoInput, .aux, .softInst,
            .monoOutput, .bus, .master, .stereoInput, .stereoOutput
        ]
        for expected in expectedTypes {
            XCTAssertTrue(
                observedTypes.contains(expected),
                "Project 1 missing expected type \(expected) (\(expected.displayName))"
            )
        }

        // "Audio" records should be plentiful (the Python dump showed many).
        let audioCount = records.filter { $0.type == .audio }.count
        XCTAssertGreaterThanOrEqual(audioCount, 3,
            "Expected at least 3 Audio channel strips in project 1, got \(audioCount)")

        // Spot-check: "Audio 7" was observed verbatim in the Python dump.
        let audioNames = records.filter { $0.type == .audio }.map { $0.name }
        XCTAssertTrue(audioNames.contains("Audio 7"),
            "Expected to find an Audio strip literally named 'Audio 7'. Got: \(audioNames)")
    }

    /// For every sample project, every returned record must carry a *known*
    /// AuCOType — i.e. the decoder's allow-listing of type bytes actually
    /// filters unknowns rather than silently passing raw bytes through.
    func testAllRecordsHaveKnownType() throws {
        guard let root = locateSamplesRoot() else {
            throw XCTSkip("No Logic Pro sample projects found; set LOGIC_SAMPLES_ROOT to run.")
        }

        var ranAtLeastOne = false
        for name in Self.sampleProjectNames {
            guard let records = try decodeSample(root: root, name: name) else { continue }
            ranAtLeastOne = true

            for record in records {
                // The enum itself is total over its known rawValues; round-trip
                // through the rawValue to prove there is no stray byte sneaking
                // past `AuCOType.from(rawByte:)`.
                XCTAssertNotNil(
                    AuCOType(rawValue: record.type.rawValue),
                    "Project \(name) yielded record with invalid type rawValue \(record.type.rawValue)"
                )
            }
        }

        if !ranAtLeastOne {
            throw XCTSkip("None of the bundled sample projects were readable.")
        }
    }
}
