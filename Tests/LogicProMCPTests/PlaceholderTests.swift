import XCTest
import MCP
@testable import LogicProMCP

final class PlaceholderTests: XCTestCase {
    func testBinaryExists() throws {
        // Placeholder: integration tests require Logic Pro to be running.
        XCTAssertTrue(true)
    }

    func testMIDIChannelUsesOneBasedInputAndZeroBasedCoreMIDIOutput() {
        assertSuccess(InputValidation.midiChannel(["channel": .int(1)]), equals: 0)
        assertSuccess(InputValidation.midiChannel(["channel": .int(16)]), equals: 15)

        if case .failure(let message) = InputValidation.midiChannel(["channel": .int(17)]) {
            XCTAssertTrue(message.contains("channel"))
        } else {
            XCTFail("Expected channel 17 to fail validation")
        }
    }

    func testNumericBoundsRejectOutOfRangeValues() {
        assertSuccess(
            InputValidation.double(["tempo": .double(120)], keys: ["tempo"], range: 20...999, label: "tempo"),
            equals: 120
        )

        if case .failure(let message) = InputValidation.double(
            ["tempo": .double(1_000)],
            keys: ["tempo"],
            range: 20...999,
            label: "tempo"
        ) {
            XCTAssertTrue(message.contains("tempo"))
        } else {
            XCTFail("Expected tempo 1000 to fail validation")
        }
    }

    func testLogicProjectPathRequiresLogicxExtensionAndExistingPathWhenOpening() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("Song.logicx", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        assertSuccess(
            InputValidation.logicProjectPath(["path": .string(project.path)], mustExist: true),
            equals: project.path
        )

        if case .failure(let message) = InputValidation.logicProjectPath(
            ["path": .string(root.appendingPathComponent("Song.txt").path)],
            mustExist: true
        ) {
            XCTAssertTrue(message.contains(".logicx"))
        } else {
            XCTFail("Expected non-.logicx path to fail validation")
        }
    }

    private func assertSuccess<T: Equatable>(
        _ result: Validation<T>,
        equals expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let value):
            XCTAssertEqual(value, expected, file: file, line: line)
        case .failure(let message):
            XCTFail("Expected success, got failure: \(message)", file: file, line: line)
        }
    }
}
