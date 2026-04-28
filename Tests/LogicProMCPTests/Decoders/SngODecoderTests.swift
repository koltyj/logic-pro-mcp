import XCTest
@testable import LogicProMCP

/// Integration tests for `SngODecoder` against the three bundled sample
/// projects. Every project has exactly 3 SngO chunks; their kinds are
/// consistent across projects (oid=224 drummer state, oid=244 unknown
/// flags, oid=264 tiny record or marker-list plist depending on whether
/// the project has explicit arrangement markers).
final class SngODecoderTests: XCTestCase {

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

    func testEveryProjectHasThreeSngORecords() throws {
        for sample in Self.sampleNames {
            let data = try Self.loadData(sample)
            let records = SngODecoder.decode(data: data)
            XCTAssertEqual(records.count, 3, "Expected 3 SngO records in \(sample), got \(records.count)")
        }
    }

    func testEveryProjectHasEachKind() throws {
        for sample in Self.sampleNames {
            let data = try Self.loadData(sample)
            let records = SngODecoder.decode(data: data)
            let kinds = Set(records.map { $0.kind })
            XCTAssertTrue(kinds.contains(.drummerState), "\(sample) missing drummerState")
            XCTAssertTrue(kinds.contains(.unknownFlags), "\(sample) missing unknownFlags")
            XCTAssertTrue(kinds.contains(.tinyOrMarkerList), "\(sample) missing tinyOrMarkerList")
        }
    }

    func testDrummerStateDecodes() throws {
        // At least one sample project must expose a valid drummerStateVersion.
        // Some projects serialize the drummer state without an outer
        // stateVersion key (observed in project 2) — we tolerate nil there.
        var sawAnyVersion = false
        for sample in Self.sampleNames {
            let data = try Self.loadData(sample)
            let records = SngODecoder.decode(data: data)
            guard let drummer = records.first(where: { $0.kind == .drummerState }) else {
                XCTFail("\(sample) missing drummerState record")
                continue
            }
            if let v = drummer.drummerStateVersion {
                XCTAssertGreaterThanOrEqual(v, 1)
                sawAnyVersion = true
            }
        }
        XCTAssertTrue(sawAnyVersion, "Expected at least one sample to expose a drummerStateVersion")
    }

    func testTinyOrMarkerListHasStableUID() throws {
        for sample in Self.sampleNames {
            let data = try Self.loadData(sample)
            let records = SngODecoder.decode(data: data)
            guard let tiny = records.first(where: { $0.kind == .tinyOrMarkerList }) else {
                XCTFail("\(sample) missing tinyOrMarkerList record")
                continue
            }
            XCTAssertNotNil(tiny.stableUID)
            if let uid = tiny.stableUID {
                XCTAssertEqual(uid, 0xED99_0001, "Unexpected stableUID in \(sample): \(String(uid, radix: 16))")
            }
        }
    }

    func testProject2MarkerListExtracted() throws {
        let data = try Self.loadData("logic-project-2.logicx")
        let records = SngODecoder.decode(data: data)
        guard let marker = records.first(where: { $0.kind == .tinyOrMarkerList && !$0.arrangementMarkerNames.isEmpty }) else {
            XCTFail("Expected project 2 SngO oid=264 to carry arrangement marker names")
            return
        }
        let names = Set(marker.arrangementMarkerNames)
        // Project 2's markers include Intro, Verse, Chorus, Bridge per the
        // session-verified GenM decode.
        XCTAssertFalse(names.intersection(["Intro", "Verse", "Chorus", "Bridge"]).isEmpty,
                       "Expected at least one marker name from {Intro,Verse,Chorus,Bridge}, got \(names)")
    }

    func testEmptyDataReturnsNoRecords() {
        XCTAssertTrue(SngODecoder.decode(data: Data()).isEmpty)
    }

    func testInvalidMagicReturnsNoRecords() {
        var bogus = Data(repeating: 0, count: 64)
        bogus[0] = 0xFF
        XCTAssertTrue(SngODecoder.decode(data: bogus).isEmpty)
    }
}
