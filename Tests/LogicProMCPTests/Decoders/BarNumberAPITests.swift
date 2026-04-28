import XCTest
@testable import LogicProMCP

/// Unit 13 — Unified bar-number API.
///
/// Validates `BarNumberAPI.build(from:)` against the three bundled sample
/// Logic Pro projects at the repository root. The tests are skipped if the
/// fixtures cannot be located (e.g. running on CI without the logicx bundles).
final class BarNumberAPITests: XCTestCase {

    // MARK: - Fixture resolution

    /// Walk up from this test file looking for a directory that contains the
    /// named `.logicx` bundle. Works for both flat checkouts and git
    /// worktrees (where the samples live at the main checkout root rather
    /// than at the worktree root).
    private func projectDataURL(for logicxName: String) -> URL? {
        let fm = FileManager.default
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()

        // Walk up to 8 levels looking for <dir>/<logicxName>.
        for _ in 0..<8 {
            let bundle = dir.appendingPathComponent(logicxName)
            if fm.fileExists(atPath: bundle.path) {
                return findProjectData(in: bundle)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private func findProjectData(in bundle: URL) -> URL? {
        let altRoot = bundle.appendingPathComponent("Alternatives")
        let fm = FileManager.default

        for i in 0...9 {
            let candidate = altRoot
                .appendingPathComponent(String(format: "%03d", i))
                .appendingPathComponent("ProjectData")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

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
        return nil
    }

    private func loadAPI(for logicxName: String) throws -> BarNumberAPI? {
        guard let url = projectDataURL(for: logicxName) else {
            // Fixture missing — skip rather than fail (mirrors how other
            // opt-in binary tests in this repo behave).
            return nil
        }
        let data = try Data(contentsOf: url)
        return BarNumberAPI.build(from: data)
    }

    private let sampleProjects = [
        "logic-project-1.logicx",
        "logic-project-2.logicx",
        "logic-project-3.logicx",
    ]

    // MARK: - Tests

    func testAnchorsNonEmptyForAllSamples() throws {
        var checked = 0
        for name in sampleProjects {
            guard let api = try loadAPI(for: name) else { continue }
            checked += 1
            XCTAssertGreaterThanOrEqual(
                api.anchors.count, 1,
                "\(name): expected at least one anchor, got \(api.anchors.count)"
            )
            XCTAssertEqual(
                api.anchors.first?.tick, 0,
                "\(name): first anchor must be at tick 0"
            )
            XCTAssertEqual(
                api.ticksPerBar, 3840,
                "\(name): ticksPerBar must be Logic's 4/4 resolution"
            )
        }
        try XCTSkipIf(checked == 0, "No sample projects available; skipping test")
    }

    func testBarForTickZeroIsOne() throws {
        var checked = 0
        for name in sampleProjects {
            guard let api = try loadAPI(for: name) else { continue }
            checked += 1
            XCTAssertEqual(
                api.bar(forTick: 0), 1.0, accuracy: 0.001,
                "\(name): bar(forTick: 0) should be 1.0"
            )
        }
        try XCTSkipIf(checked == 0, "No sample projects available; skipping test")
    }

    func testBarForOneBarInIsApproximatelyTwo() throws {
        var checked = 0
        for name in sampleProjects {
            guard let api = try loadAPI(for: name) else { continue }
            checked += 1
            let barOne = api.bar(forTick: 3840)
            XCTAssertEqual(
                barOne, 2.0, accuracy: 0.001,
                "\(name): bar(forTick: 3840) should be ~2.0, got \(barOne)"
            )
        }
        try XCTSkipIf(checked == 0, "No sample projects available; skipping test")
    }

    func testTickForBarOneIsZero() throws {
        var checked = 0
        for name in sampleProjects {
            guard let api = try loadAPI(for: name) else { continue }
            checked += 1
            XCTAssertEqual(
                api.tick(forBar: 1.0), 0,
                "\(name): tick(forBar: 1.0) should be 0"
            )
        }
        try XCTSkipIf(checked == 0, "No sample projects available; skipping test")
    }

    func testRoundTripBarTickBar() throws {
        // Sample a handful of bar positions spanning a typical song range.
        let barPositions: [Double] = [1.0, 2.0, 3.5, 5.0, 8.25, 12.0, 16.75, 20.0]
        var checked = 0
        for name in sampleProjects {
            guard let api = try loadAPI(for: name) else { continue }
            checked += 1
            for b in barPositions {
                let tick = api.tick(forBar: b)
                let roundTrip = api.bar(forTick: tick)
                XCTAssertEqual(
                    roundTrip, b, accuracy: 0.001,
                    "\(name): round-trip bar→tick→bar failed at bar=\(b) (tick=\(tick), got=\(roundTrip))"
                )
            }
        }
        try XCTSkipIf(checked == 0, "No sample projects available; skipping test")
    }

    // MARK: - Degenerate data path

    func testBuildFromEmptyDataReturnsDefaultAPI() {
        let api = BarNumberAPI.build(from: Data())
        XCTAssertEqual(api.ticksPerBar, 3840)
        XCTAssertEqual(api.anchors.count, 1)
        XCTAssertEqual(api.anchors.first?.tick, 0)
        XCTAssertEqual(api.anchors.first?.bar ?? .nan, 1.0, accuracy: 0.001)
        XCTAssertEqual(api.bar(forTick: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(api.bar(forTick: 3840), 2.0, accuracy: 0.001)
        XCTAssertEqual(api.tick(forBar: 1.0), 0)
        XCTAssertEqual(api.tick(forBar: 2.0), 3840)
    }
}
