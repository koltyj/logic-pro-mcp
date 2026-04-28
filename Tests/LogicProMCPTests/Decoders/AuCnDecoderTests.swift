import XCTest
@testable import LogicProMCP

/// Integration tests for the `AuCn` routing-table decoder.
///
/// Each sample Logic Pro project has exactly 13 `AuCn` chunks:
/// - 12 small (132-byte) routing entries at stable routing indices
///   `{0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}` (index 1 is consumed by the
///   big enable table, not a small entry).
/// - 1 big `AuCn` enable table whose body after offset 0x80 is a flat `u32`
///   table of per-strip enable flags (each value 0 or 1).
final class AuCnDecoderTests: XCTestCase {

    /// Candidate `.logicx` projects used for integration. Paths are absolute so
    /// tests run regardless of the CWD chosen by `swift test` or Xcode.
    private static let projectPaths: [String] = [
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-2.logicx",
        "/Users/alan1/Projects/logic-pro-mcp/logic-project-3.logicx",
    ]

    /// Expected routing-index set for the 12 small `AuCn` entries. Index 1 is
    /// the big enable-table entry and therefore absent from the small-entry
    /// set.
    private static let expectedSmallIndices: Set<Int> = [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

    // MARK: - Fixture helpers

    /// Locate the `ProjectData` binary for a `.logicx` bundle by scanning the
    /// `Alternatives/NNN/ProjectData` paths (matching `ProjectDataParser`).
    private func findProjectData(logicxPath: String) -> String? {
        let fm = FileManager.default
        let altRoot = (logicxPath as NSString).appendingPathComponent("Alternatives")

        for index in 0...9 {
            let indexStr = String(format: "%03d", index)
            let candidate = (altRoot as NSString)
                .appendingPathComponent(indexStr + "/ProjectData")
            if fm.fileExists(atPath: candidate) { return candidate }
        }

        if let entries = try? fm.contentsOfDirectory(atPath: altRoot) {
            for entry in entries.sorted() {
                let candidate = (altRoot as NSString)
                    .appendingPathComponent(entry + "/ProjectData")
                if fm.fileExists(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    private func loadProjectData(logicxPath: String) -> Data? {
        guard FileManager.default.fileExists(atPath: logicxPath) else { return nil }
        guard let pdPath = findProjectData(logicxPath: logicxPath) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: pdPath))
    }

    // MARK: - Tests

    /// Every sample project must expose exactly 12 small routing entries whose
    /// indices match `expectedSmallIndices`, plus a non-nil enable table whose
    /// flag table is sized from the body beyond offset 0x80 and only contains
    /// 0/1 values.
    func testAuCnRoutingTableAcrossProjects() throws {
        var anyParsed = false

        for path in Self.projectPaths {
            guard let data = loadProjectData(logicxPath: path) else {
                print("[AuCnDecoderTests] Skipping missing / unreadable project: \(path)")
                continue
            }
            anyParsed = true

            let (entries, enableTable) = AuCnDecoder.decode(data: data)
            let projectName = (path as NSString).lastPathComponent

            print("[AuCnDecoderTests] \(projectName): entries=\(entries.count), enableTableBodyLen=\(enableTable?.bodyLength ?? -1), flags=\(enableTable?.flagCount ?? -1)")

            // 12 small routing entries.
            XCTAssertEqual(
                entries.count, 12,
                "\(projectName): expected 12 small AuCn routing entries"
            )

            // Each small entry has a 132-byte body and (index << 16) | 3 at 0x14.
            for entry in entries {
                XCTAssertEqual(
                    entry.bodyLength, 132,
                    "\(projectName): small AuCn should be 132 bytes, got \(entry.bodyLength) for oid=\(entry.oid)"
                )
                let expectedRaw = UInt32(entry.routingIndex << 16) | 0x03
                XCTAssertEqual(
                    entry.rawHeaderU32AtOffset14, expectedRaw,
                    "\(projectName): routingIndex=\(entry.routingIndex) should round-trip to \(String(expectedRaw, radix: 16)), got \(String(entry.rawHeaderU32AtOffset14, radix: 16))"
                )
            }

            // Routing indices must be exactly {0, 2..12}.
            let indexSet = Set(entries.map { $0.routingIndex })
            XCTAssertEqual(
                indexSet, Self.expectedSmallIndices,
                "\(projectName): small AuCn routing indices mismatch"
            )

            // Enable table must exist.
            let table = try XCTUnwrap(
                enableTable,
                "\(projectName): expected a big AuCn enable table"
            )

            // flags.count == (bodyLength - 0x80) / 4
            let expectedFlagCount = (table.bodyLength - 0x80) / 4
            XCTAssertEqual(
                table.flags.count, expectedFlagCount,
                "\(projectName): enableTable.flags.count should equal (bodyLength - 0x80) / 4"
            )
            XCTAssertEqual(
                table.flagCount, table.flags.count,
                "\(projectName): enableTable.flagCount should match flags array size"
            )

            // Every flag is 0 or 1.
            for flag in table.flags {
                XCTAssertTrue(
                    flag == 0 || flag == 1,
                    "\(projectName): enable flag should be 0 or 1, got \(flag)"
                )
            }
        }

        XCTAssertTrue(
            anyParsed,
            "No fixture projects could be parsed — ensure logic-project-{1,2,3}.logicx exist"
        )
    }

    /// `logic-project-1`'s big `AuCn` has a confirmed 1384-byte body this
    /// session. Assert that directly so regressions are caught immediately.
    func testAuCnEnableTableBodyLengthForProject1() throws {
        let path = "/Users/alan1/Projects/logic-pro-mcp/logic-project-1.logicx"
        guard let data = loadProjectData(logicxPath: path) else {
            throw XCTSkip("logic-project-1 fixture not available at \(path)")
        }

        let (_, enableTable) = AuCnDecoder.decode(data: data)
        let table = try XCTUnwrap(enableTable, "logic-project-1: expected big AuCn enable table")

        XCTAssertEqual(
            table.bodyLength, 1384,
            "logic-project-1 big AuCn should have a 1384-byte body (session-confirmed)"
        )
    }
}
