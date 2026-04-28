import XCTest
@testable import LogicProMCP

/// Tests for the isolated `AuCO204Decoder` against the three bundled
/// sample Logic Pro projects.
final class AuCO204DecoderTests: XCTestCase {

    // MARK: - Sample-project discovery

    /// Resolve the absolute path of one of the bundled sample `.logicx`
    /// projects (`logic-project-1.logicx`, etc.).
    ///
    /// Discovery order:
    /// 1. `LOGIC_SAMPLES_ROOT` env var, if set.
    /// 2. Walk up from `#filePath` to find a directory that contains the
    ///    sample bundles at the repo root.
    private func sampleProjectPath(_ name: String, file: StaticString = #filePath) -> String? {
        if let root = ProcessInfo.processInfo.environment["LOGIC_SAMPLES_ROOT"] {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }

        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Load the raw `ProjectData` bytes for a sample `.logicx` bundle.
    private func loadProjectData(_ bundleName: String) -> Data? {
        guard let bundlePath = sampleProjectPath(bundleName) else { return nil }
        let altRoot = URL(fileURLWithPath: bundlePath).appendingPathComponent("Alternatives")
        let fm = FileManager.default

        for idx in 0...9 {
            let indexStr = String(format: "%03d", idx)
            let candidate = altRoot
                .appendingPathComponent(indexStr)
                .appendingPathComponent("ProjectData")
            if fm.fileExists(atPath: candidate.path),
               let data = try? Data(contentsOf: candidate) {
                return data
            }
        }

        if let entries = try? fm.contentsOfDirectory(atPath: altRoot.path) {
            for entry in entries.sorted() {
                let candidate = altRoot
                    .appendingPathComponent(entry)
                    .appendingPathComponent("ProjectData")
                if fm.fileExists(atPath: candidate.path),
                   let data = try? Data(contentsOf: candidate) {
                    return data
                }
            }
        }
        return nil
    }

    // MARK: - Tests

    /// Project 1 has exactly 12 extended (204-byte) AuCO records, as
    /// observed via Python analysis.
    func testProject1Has12ExtendedRecords() throws {
        guard let data = loadProjectData("logic-project-1.logicx") else {
            throw XCTSkip("Sample logic-project-1.logicx not found")
        }

        let records = AuCO204Decoder.decode(data: data)
        XCTAssertEqual(
            records.count, 12,
            "Expected 12 × 204-byte AuCO records in logic-project-1"
        )
    }

    /// Project 1 must contain an "Audio 1" record with type byte 0x40.
    func testProject1ContainsAudio1WithCorrectType() throws {
        guard let data = loadProjectData("logic-project-1.logicx") else {
            throw XCTSkip("Sample logic-project-1.logicx not found")
        }

        let records = AuCO204Decoder.decode(data: data)
        guard let audio1 = records.first(where: { $0.name == "Audio 1" }) else {
            XCTFail("No record named 'Audio 1' found in logic-project-1")
            return
        }

        XCTAssertEqual(
            audio1.typeByte, 0x40,
            "Audio 1 should have typeByte 0x40 (Audio)"
        )
    }

    /// Every decoded record from every bundled project must have exactly
    /// 11 extended flags, each being 0 or 1.
    func testExtendedFlagsShapeAcrossAllSamples() throws {
        var anyProjectChecked = false
        for name in ["logic-project-1.logicx",
                     "logic-project-2.logicx",
                     "logic-project-3.logicx"] {
            guard let data = loadProjectData(name) else { continue }
            anyProjectChecked = true

            let records = AuCO204Decoder.decode(data: data)
            for record in records {
                XCTAssertEqual(
                    record.extendedFlags.count,
                    AuCO204Decoder.extendedFlagCount,
                    "Record \(record.name) in \(name) has "
                    + "\(record.extendedFlags.count) flags (expected 11)"
                )
                for (idx, value) in record.extendedFlags.enumerated() {
                    XCTAssert(
                        value == 0 || value == 1,
                        "Record \(record.name) in \(name) flag[\(idx)] "
                        + "= \(value); expected 0 or 1"
                    )
                }
            }
        }

        if !anyProjectChecked {
            throw XCTSkip("No sample .logicx projects found")
        }
    }

    /// Sanity check: the decoder returns an empty array for empty or
    /// obviously-invalid input, and never crashes on short data.
    func testDecoderHandlesInvalidInputGracefully() {
        XCTAssertEqual(AuCO204Decoder.decode(data: Data()).count, 0)
        XCTAssertEqual(
            AuCO204Decoder.decode(data: Data([0x00, 0x01, 0x02, 0x03])).count,
            0
        )
        // Valid magic, nothing else.
        let magicOnly = Data([0x23, 0x47, 0xC0, 0xAB])
        XCTAssertEqual(AuCO204Decoder.decode(data: magicOnly).count, 0)
    }
}
