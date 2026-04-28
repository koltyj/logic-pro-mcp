import XCTest
@testable import LogicProMCP

/// Tests for `HyprDecoder` against the three sample Logic projects bundled at
/// the repo root (`logic-project-1.logicx`, …-2, …-3). These tests require the
/// sample projects to be present on disk; if they are missing the test is
/// skipped rather than failed, so CI environments without the fixtures still
/// pass.
final class HyprDecoderTests: XCTestCase {

    // MARK: - Sample Discovery

    /// Repo-root-relative sample project names. All three are required to be
    /// present for these tests to run (they ship together).
    private static let sampleProjectNames: [String] = [
        "logic-project-1.logicx",
        "logic-project-2.logicx",
        "logic-project-3.logicx",
    ]

    /// Walk up from this test file to find the repo root (the directory that
    /// contains `Package.swift`). Returns nil if no such root is found.
    /// Honors the `LOGIC_SAMPLES_ROOT` environment variable when set — useful
    /// for running tests in a git worktree whose root does not contain the
    /// logic-project-*.logicx fixtures.
    private static func repoRoot() -> URL? {
        if let override = ProcessInfo.processInfo.environment["LOGIC_SAMPLES_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            let packageExists = FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
            let samplesExist = FileManager.default.fileExists(atPath: url.appendingPathComponent("logic-project-1.logicx").path)
            if packageExists && samplesExist {
                return url
            }
        }
        return nil
    }

    /// Resolve the ProjectData file for a given .logicx bundle.
    private static func projectData(for sample: String) -> URL? {
        guard let root = repoRoot() else { return nil }
        let logicx = root.appendingPathComponent(sample)
        let altRoot = logicx.appendingPathComponent("Alternatives")
        for index in 0...9 {
            let indexStr = String(format: "%03d", index)
            let candidate = altRoot
                .appendingPathComponent(indexStr)
                .appendingPathComponent("ProjectData")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func loadSampleData() throws -> [(name: String, data: Data)] {
        var out: [(String, Data)] = []
        for sample in sampleProjectNames {
            guard let url = projectData(for: sample) else {
                throw XCTSkip("Sample project '\(sample)' not present at repo root")
            }
            let data = try Data(contentsOf: url)
            out.append((sample, data))
        }
        return out
    }

    // MARK: - Tests

    func testEveryProjectHasThreeHyprChunks() throws {
        for (name, data) in try Self.loadSampleData() {
            let records = HyprDecoder.decode(data: data)
            XCTAssertEqual(
                records.count, 3,
                "\(name): expected exactly 3 Hypr chunks, got \(records.count)"
            )
        }
    }

    func testAutomationModeChunkContainsExpectedEntries() throws {
        for (name, data) in try Self.loadSampleData() {
            let records = HyprDecoder.decode(data: data)
            guard let record = records.first(where: { $0.oid == 0 }) else {
                XCTFail("\(name): missing Hypr oid=0 (automationMode)")
                continue
            }
            XCTAssertEqual(record.category, .automationMode, "\(name) oid=0 category")
            XCTAssertTrue(
                record.entries.contains("Volume"),
                "\(name) oid=0 entries missing 'Volume': \(record.entries)"
            )
            XCTAssertTrue(
                record.entries.contains("Automatic"),
                "\(name) oid=0 entries missing 'Automatic': \(record.entries)"
            )
        }
    }

    func testMidiControlsChunkContainsExpectedEntries() throws {
        for (name, data) in try Self.loadSampleData() {
            let records = HyprDecoder.decode(data: data)
            guard let record = records.first(where: { $0.oid == 4 }) else {
                XCTFail("\(name): missing Hypr oid=4 (midiControls)")
                continue
            }
            XCTAssertEqual(record.category, .midiControls, "\(name) oid=4 category")
            for expected in ["MIDI Controls", "Pitch Bend", "Aftertouch"] {
                XCTAssertTrue(
                    record.entries.contains(expected),
                    "\(name) oid=4 entries missing '\(expected)': \(record.entries)"
                )
            }
        }
    }

    func testGmDrumKitChunkContainsExpectedEntries() throws {
        for (name, data) in try Self.loadSampleData() {
            let records = HyprDecoder.decode(data: data)
            guard let record = records.first(where: { $0.oid == 8 }) else {
                XCTFail("\(name): missing Hypr oid=8 (gmDrumKit)")
                continue
            }
            XCTAssertEqual(record.category, .gmDrumKit, "\(name) oid=8 category")
            for expected in ["GM Drum Kit", "KICK 1", "Closed HH"] {
                XCTAssertTrue(
                    record.entries.contains(expected),
                    "\(name) oid=8 entries missing '\(expected)': \(record.entries)"
                )
            }
            XCTAssertGreaterThanOrEqual(
                record.entries.count, 60,
                "\(name) oid=8 entry count (\(record.entries.count)) below 60"
            )
        }
    }
}
