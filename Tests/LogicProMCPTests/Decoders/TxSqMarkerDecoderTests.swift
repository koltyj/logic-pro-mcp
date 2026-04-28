import XCTest
@testable import LogicProMCP

/// Integration tests for `TxSqMarkerDecoder` against the three bundled sample
/// Logic projects. Project 1 has no TxSq chunks; projects 2 and 3 carry
/// short-ASCII arrangement-marker TxSq chunks whose names we can recover.
final class TxSqMarkerDecoderTests: XCTestCase {

    // MARK: - Sample Discovery

    private static let sampleNames = [
        "logic-project-1.logicx",
        "logic-project-2.logicx",
        "logic-project-3.logicx",
    ]

    private static func repoRoot() -> URL? {
        if let override = ProcessInfo.processInfo.environment["LOGIC_SAMPLES_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            let pkg = url.appendingPathComponent("Package.swift")
            let sample = url.appendingPathComponent("logic-project-1.logicx")
            if FileManager.default.fileExists(atPath: pkg.path),
               FileManager.default.fileExists(atPath: sample.path) {
                return url
            }
        }
        return nil
    }

    private static func projectData(for sample: String) -> URL? {
        guard let root = repoRoot() else { return nil }
        let altRoot = root.appendingPathComponent(sample).appendingPathComponent("Alternatives")
        for i in 0...9 {
            let candidate = altRoot
                .appendingPathComponent(String(format: "%03d", i))
                .appendingPathComponent("ProjectData")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func loadData(_ sample: String) throws -> Data {
        guard let url = projectData(for: sample) else {
            throw XCTSkip("Sample project '\(sample)' not available")
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Tests

    func testProject1HasNoTxSqMarkers() throws {
        let data = try Self.loadData("logic-project-1.logicx")
        let markers = TxSqMarkerDecoder.decode(data: data)
        XCTAssertTrue(markers.isEmpty, "Expected no TxSq marker chunks in project 1, got \(markers.count)")
    }

    func testProject2ContainsExpectedMarkers() throws {
        let data = try Self.loadData("logic-project-2.logicx")
        let markers = TxSqMarkerDecoder.decode(data: data)
        let names = Set(markers.map { $0.markerName })
        XCTAssertTrue(names.contains("Intro"),  "Expected 'Intro' marker, got \(names)")
        XCTAssertTrue(names.contains("Chorus"), "Expected 'Chorus' marker, got \(names)")
        XCTAssertTrue(names.contains("Bridge"), "Expected 'Bridge' marker, got \(names)")
    }

    func testProject3ContainsAtLeastOneExpectedMarker() throws {
        let data = try Self.loadData("logic-project-3.logicx")
        let markers = TxSqMarkerDecoder.decode(data: data)
        XCTAssertFalse(markers.isEmpty, "Expected at least one TxSq marker in project 3")
        let expected: Set<String> = ["Intro", "Verse", "Chorus", "Bridge"]
        let names = Set(markers.map { $0.markerName })
        XCTAssertFalse(names.intersection(expected).isEmpty,
                       "Expected project 3 to contain at least one of \(expected), got \(names)")
    }

    func testAllMarkerNamesAreNonEmpty() throws {
        for sample in Self.sampleNames {
            guard let data = try? Self.loadData(sample) else { continue }
            let markers = TxSqMarkerDecoder.decode(data: data)
            for m in markers {
                XCTAssertFalse(m.markerName.isEmpty, "Empty markerName in \(sample) oid=\(m.oid)")
                XCTAssertTrue(m.markerName.count <= 32, "Marker name too long in \(sample): \(m.markerName)")
            }
        }
    }

    func testEmptyDataReturnsNoRecords() {
        XCTAssertTrue(TxSqMarkerDecoder.decode(data: Data()).isEmpty)
    }

    func testInvalidMagicReturnsNoRecords() {
        var bogus = Data(repeating: 0, count: 64)
        bogus[0] = 0xFF
        XCTAssertTrue(TxSqMarkerDecoder.decode(data: bogus).isEmpty)
    }
}
