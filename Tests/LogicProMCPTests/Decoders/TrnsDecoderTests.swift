import Foundation
import XCTest
@testable import LogicProMCP

/// Tests for `TrnsDecoder`. Open each reference `.logicx` project, locate its
/// `ProjectData` binary, decode the `Trns` chunk(s), and assert the invariants
/// observed across all three samples.
final class TrnsDecoderTests: XCTestCase {

    // MARK: - Sample discovery

    /// Candidate roots where the three reference `.logicx` projects may live.
    /// The tests are designed to skip gracefully when the samples are missing
    /// so CI environments without them do not fail hard.
    private static let sampleRoots: [String] = [
        "/Users/alan1/Projects/logic-pro-mcp",
        ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_ROOT"] ?? "",
    ]

    private static let sampleNames: [String] = [
        "logic-project-1.logicx",
        "logic-project-2.logicx",
        "logic-project-3.logicx",
    ]

    /// Return absolute paths to each reference project's `ProjectData` file
    /// that actually exists on disk.
    private func discoverProjectDataFiles() -> [(name: String, path: String)] {
        let fm = FileManager.default
        var results: [(String, String)] = []
        for name in Self.sampleNames {
            for root in Self.sampleRoots where !root.isEmpty {
                let bundle = (root as NSString).appendingPathComponent(name)
                let alts = (bundle as NSString).appendingPathComponent("Alternatives")
                guard fm.fileExists(atPath: alts) else { continue }
                // Try numbered alternatives 000..009
                var found: String?
                for index in 0...9 {
                    let indexStr = String(format: "%03d", index)
                    let candidate = ((alts as NSString)
                        .appendingPathComponent(indexStr) as NSString)
                        .appendingPathComponent("ProjectData")
                    if fm.fileExists(atPath: candidate) {
                        found = candidate
                        break
                    }
                }
                if let path = found {
                    results.append((name, path))
                    break
                }
            }
        }
        return results
    }

    // MARK: - Tests

    func testTrnsChunkInvariantsAcrossSamples() throws {
        let samples = discoverProjectDataFiles()
        try XCTSkipIf(samples.isEmpty, "No reference .logicx samples available on this host")

        for (name, path) in samples {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let globals = TrnsDecoder.decode(data: data)
            XCTAssertEqual(
                globals.count, 1,
                "\(name): expected exactly 1 Trns chunk, got \(globals.count)"
            )
            guard let trns = globals.first else { continue }

            XCTAssertEqual(trns.oid, 0, "\(name): Trns oid should be 0")
            XCTAssertEqual(
                trns.bodyLength, 492,
                "\(name): Trns body length should be 492"
            )
            // u32@0 is a small length-ish constant; observed 0x410 or 0x420.
            XCTAssertTrue(
                trns.header1 > 0 && trns.header1 < 0x10000,
                "\(name): header1 should be a small positive constant, got 0x\(String(trns.header1, radix: 16))"
            )
            // The u32 at offset 0x50 matches Logic's canonical ticks-per-bar.
            XCTAssertEqual(
                trns.gridValue, 3840,
                "\(name): gridValue (u32@0x50) should equal 3840 (ticks per bar)"
            )
            // Weak sanity: at least one of the two grid constants must appear.
            XCTAssertTrue(
                trns.containsTicksPerBar || trns.containsDivisionGrid,
                "\(name): expected body to contain a recognised grid constant"
            )
            // Pre-roll field is best-effort; empty is acceptable, but any
            // entries surfaced must actually be negative when read as Int16.
            XCTAssertGreaterThanOrEqual(trns.preRollU32s.count, 0)
            for value in trns.preRollU32s {
                let low16 = UInt16(value & 0xFFFF)
                XCTAssertTrue(
                    low16 >= 0x8000 && low16 != 0xFFFF,
                    "\(name): preRollU32s entry 0x\(String(value, radix: 16)) does not match the negative-low16 rule"
                )
            }
        }
    }

    func testDecodeReturnsEmptyForInvalidMagic() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertTrue(TrnsDecoder.decode(data: garbage).isEmpty)
    }

    func testDecodeReturnsEmptyForEmptyData() {
        XCTAssertTrue(TrnsDecoder.decode(data: Data()).isEmpty)
    }
}
