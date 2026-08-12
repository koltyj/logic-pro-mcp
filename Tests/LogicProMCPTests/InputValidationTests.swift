import Foundation
import MCP
import XCTest
@testable import LogicProMCP

final class InputValidationTests: XCTestCase {
    func testNumericBounds() {
        assertSuccess(
            InputValidation.double(["tempo": .double(120)], keys: ["tempo"], range: 20...999, label: "tempo"),
            equals: 120
        )

        if case .success = InputValidation.double(
            ["tempo": .double(1_000)], keys: ["tempo"], range: 20...999, label: "tempo"
        ) {
            XCTFail("Expected out-of-range tempo to fail")
        }
        if case .success = InputValidation.int(
            ["bar": .string("not-a-number")], keys: ["bar"], default: 1, range: 1...999, label: "bar"
        ) {
            XCTFail("Expected a malformed supplied value to fail instead of using the default")
        }
    }

    func testProjectPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("Song.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        assertSuccess(
            InputValidation.logicProjectPath(["path": .string(project.path)], mustExist: true),
            equals: project.path
        )

        if case .success = InputValidation.logicProjectPath(
            ["path": .string(root.appendingPathComponent("Song.txt").path)], mustExist: true
        ) {
            XCTFail("Expected a non-Logic project path to fail")
        }

        let regularFile = root.appendingPathComponent("NotAProject.logicx")
        FileManager.default.createFile(atPath: regularFile.path, contents: Data())
        if case .success = InputValidation.logicProjectPath(
            ["path": .string(regularFile.path)], mustExist: true
        ) {
            XCTFail("Expected a regular .logicx file to fail")
        }
    }

    func testPositionFormat() {
        XCTAssertTrue(TransportDispatcher.isSafePosition("1.2.3.4"))
        XCTAssertTrue(TransportDispatcher.isSafePosition("00:01:02:03"))
        XCTAssertFalse(TransportDispatcher.isSafePosition("1::2"))
        XCTAssertFalse(TransportDispatcher.isSafePosition("1.2:3.4"))
        XCTAssertFalse(TransportDispatcher.isSafePosition("1.2.3.4.5"))
    }

    func testMIDIValues() {
        assertSuccess(InputValidation.midiChannel(["channel": .int(1)]), equals: 0)
        assertSuccess(
            InputValidation.midiNotes(["notes": .array([.int(60), .int(64), .int(67)])]),
            equals: "60,64,67"
        )

        if case .success = InputValidation.midiChannel(["channel": .int(17)]) {
            XCTFail("Expected channel 17 to fail")
        }
        if case .success = InputValidation.midiNotes(["notes": .array([.int(60), .int(128)])]) {
            XCTFail("Expected note 128 to fail")
        }
    }

    private func assertSuccess<T: Equatable>(
        _ result: Validation<T>,
        equals expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let value): XCTAssertEqual(value, expected, file: file, line: line)
        case .failure(let message): XCTFail(message, file: file, line: line)
        }
    }
}
