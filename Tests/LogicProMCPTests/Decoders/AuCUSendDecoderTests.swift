import XCTest
@testable import LogicProMCP

/// Integration tests for ``AuCUSendDecoder`` — the structured extractor for
/// Logic Pro's 76-byte AuCU send sub-records.
///
/// Tests run against the three bundled `.logicx` fixtures at the repository
/// root. Each fixture's `ProjectData` is loaded directly (not via
/// `ProjectDataParser`, which the decoder intentionally does not import) and
/// passed to `AuCUSendDecoder.decode(data:)`.
final class AuCUSendDecoderTests: XCTestCase {

    /// Absolute paths to the fixture projects' raw `ProjectData` files.
    private static let projectDataPaths: [String] = [
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx/Alternatives/000/ProjectData",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-2.logicx/Alternatives/000/ProjectData",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-3.logicx/Alternatives/000/ProjectData",
    ]

    /// Unity-gain raw value (0 dB). See `reference/LOGIC_BINARY_SPEC.md` §5.
    private static let unityGainRaw: UInt32 = 0x5A000000

    /// Load all available fixtures. Missing files are logged and skipped to
    /// keep the suite robust to fixtures being removed locally.
    private static func loadAllFixtures() -> [(path: String, data: Data)] {
        var result: [(String, Data)] = []
        for path in projectDataPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                print("[AuCUSendDecoderTests] Skipping missing fixture: \(path)")
                continue
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                print("[AuCUSendDecoderTests] Failed to read: \(path)")
                continue
            }
            result.append((path, data))
        }
        return result
    }

    /// Each fixture must yield at least one 76-byte AuCU send sub-record.
    func testDecodeReturnsNonEmptyForAllProjects() throws {
        let fixtures = Self.loadAllFixtures()
        try XCTSkipIf(fixtures.isEmpty, "No fixture ProjectData files available")

        for (path, data) in fixtures {
            let records = AuCUSendDecoder.decode(data: data)
            print("[AuCUSendDecoderTests] \(path): \(records.count) send record(s)")
            XCTAssertFalse(
                records.isEmpty,
                "Expected at least one AuCU send record from \(path)"
            )
        }
    }

    /// The derived `sendLevelDB` must always fall inside the documented
    /// clamp range of `[-144.0, +24.0]`.
    func testSendLevelDBIsWithinClampRange() throws {
        let fixtures = Self.loadAllFixtures()
        try XCTSkipIf(fixtures.isEmpty, "No fixture ProjectData files available")

        for (path, data) in fixtures {
            let records = AuCUSendDecoder.decode(data: data)
            for rec in records {
                XCTAssertGreaterThanOrEqual(
                    rec.sendLevelDB, -144.0,
                    "sendLevelDB below clamp floor in \(path) at index \(rec.indexInChunk)"
                )
                XCTAssertLessThanOrEqual(
                    rec.sendLevelDB, 24.0,
                    "sendLevelDB above clamp ceiling in \(path) at index \(rec.indexInChunk)"
                )
            }
        }
    }

    /// At least one record across all fixtures must have `sendEnabled == true`
    /// (the spec's canonical "send on" state with `u16@0x18 == 0x0000`).
    func testAtLeastOneSendEnabledRecordExists() throws {
        let fixtures = Self.loadAllFixtures()
        try XCTSkipIf(fixtures.isEmpty, "No fixture ProjectData files available")

        var sawEnabled = false
        for (_, data) in fixtures {
            let records = AuCUSendDecoder.decode(data: data)
            if records.contains(where: { $0.sendEnabled == true }) {
                sawEnabled = true
                break
            }
        }
        XCTAssertTrue(
            sawEnabled,
            "Expected at least one AuCU record with sendEnabled == true across all fixtures"
        )
    }

    /// At least one record across all fixtures must carry a canonical send
    /// level from the spec's `-inf/-6/0/+6 dB` validation set. Fixtures don't
    /// always contain unity-gain sends (most sends in idle projects are
    /// disabled or muted to -inf), so we accept any of:
    ///   - `u32Offset24 == 0x00000000` → -144 dB (negative infinity)
    ///   - `u32Offset24 == 0x5A000000` → 0 dB (unity)
    /// and verify the decoded `sendLevelDB` matches the expected value.
    func testAtLeastOneCanonicalLevelRecordExists() throws {
        let fixtures = Self.loadAllFixtures()
        try XCTSkipIf(fixtures.isEmpty, "No fixture ProjectData files available")

        var sawNegInf = false
        var sawUnity = false
        for (_, data) in fixtures {
            let records = AuCUSendDecoder.decode(data: data)
            for rec in records {
                if rec.u32Offset24 == 0x0000_0000 && abs(rec.sendLevelDB - (-144.0)) < 0.01 {
                    sawNegInf = true
                }
                if rec.u32Offset24 == Self.unityGainRaw && abs(rec.sendLevelDB) < 0.01 {
                    sawUnity = true
                }
                if sawNegInf && sawUnity { break }
            }
        }
        XCTAssertTrue(
            sawNegInf || sawUnity,
            "Expected at least one AuCU record with a canonical send level (0x00000000→-144 dB or 0x5A000000→0 dB) across all fixtures"
        )
    }
}
