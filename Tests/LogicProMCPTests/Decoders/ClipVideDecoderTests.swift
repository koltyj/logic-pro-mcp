import XCTest
@testable import LogicProMCP

final class ClipVideDecoderTests: XCTestCase {

    // MARK: - Fixtures

    /// Candidate roots where the sample `.logicx` bundles may live.
    private static let sampleRoots: [String] = [
        "/Users/alan1/Projects/logic-pro-mcp",
        FileManager.default.currentDirectoryPath,
    ]

    private static let sampleBundles: [String] = [
        "logic-project-1.logicx",
        "logic-project-2.logicx",
        "logic-project-3.logicx",
    ]

    /// Locate the `ProjectData` file for a sample bundle, if present.
    private func projectDataURL(for bundleName: String) -> URL? {
        let fm = FileManager.default
        for root in Self.sampleRoots {
            let bundle = URL(fileURLWithPath: root).appendingPathComponent(bundleName)
            let altRoot = bundle.appendingPathComponent("Alternatives")
            guard fm.fileExists(atPath: altRoot.path) else { continue }

            if let entries = try? fm.contentsOfDirectory(atPath: altRoot.path) {
                for entry in entries.sorted() {
                    let candidate = altRoot
                        .appendingPathComponent(entry)
                        .appendingPathComponent("ProjectData")
                    if fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Tests

    func testAllSampleProjectsHaveExpectedClipVideStructure() throws {
        var decodedCount = 0

        for bundleName in Self.sampleBundles {
            guard let url = projectDataURL(for: bundleName) else {
                // Skip missing fixtures; CI may not carry the sample bundles.
                continue
            }
            let data = try Data(contentsOf: url)
            let (clips, vides) = ClipVideDecoder.decode(data: data)

            XCTAssertEqual(
                clips.count, 3,
                "\(bundleName): expected exactly 3 Clip chunks, got \(clips.count)"
            )
            XCTAssertEqual(
                vides.count, 1,
                "\(bundleName): expected exactly 1 Vide chunk, got \(vides.count)"
            )

            // Every Clip should advertise headerLen == 0xA0.
            for clip in clips {
                XCTAssertEqual(
                    clip.headerLen, 0xA0,
                    "\(bundleName): Clip oid=\(clip.oid) headerLen expected 0xA0, got 0x\(String(clip.headerLen, radix: 16))"
                )
                XCTAssertEqual(
                    clip.bodyLength, 85,
                    "\(bundleName): Clip oid=\(clip.oid) body length expected 85, got \(clip.bodyLength)"
                )
            }

            // Clip oid=0 should have gainFloat == 1.0 (within tolerance).
            if let clipZero = clips.first(where: { $0.oid == 0 }) {
                XCTAssertEqual(
                    clipZero.gainFloat, 1.0, accuracy: 0.001,
                    "\(bundleName): Clip oid=0 gainFloat expected 1.0, got \(clipZero.gainFloat)"
                )
            } else {
                XCTFail("\(bundleName): missing Clip record with oid=0")
            }

            // Vide body should be all zero after the 4-byte header.
            for vide in vides {
                XCTAssertTrue(
                    vide.isAllZeroAfterHeader,
                    "\(bundleName): Vide oid=\(vide.oid) expected all-zero body after header"
                )
                XCTAssertEqual(
                    vide.bodyLength, 130,
                    "\(bundleName): Vide oid=\(vide.oid) body length expected 130, got \(vide.bodyLength)"
                )
                XCTAssertEqual(
                    vide.headerLen, 0x76,
                    "\(bundleName): Vide oid=\(vide.oid) headerLen expected 0x76, got 0x\(String(vide.headerLen, radix: 16))"
                )
            }

            decodedCount += 1
        }

        XCTAssertGreaterThan(
            decodedCount, 0,
            "No sample `.logicx` bundles found. Expected one of: \(Self.sampleBundles)"
        )
    }
}
