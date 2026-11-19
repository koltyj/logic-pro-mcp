import XCTest
@testable import LogicProMCP

final class BounceRequestTests: XCTestCase {
    private func parse(_ params: [String: String]) -> Result<BounceRequest, BounceError> {
        BounceRequest.parse(params)
    }

    func testDefaultsToWav() throws {
        let request = try parse(["directory": "/tmp/out", "filename": "mix"]).get()
        XCTAssertEqual(request.fileType, .wav)
        XCTAssertEqual(request.outputPath, "/tmp/out/mix.wav")
        XCTAssertNil(request.bitDepth)
        XCTAssertNil(request.sampleRate)
        XCTAssertFalse(request.overwrite)
    }

    func testStripsAMatchingExtensionAndKeepsUnicodeNames() throws {
        let request = try parse([
            "directory": "/tmp/out", "filename": "牧青1348－高牧(詩8).wav", "file_type": "aiff",
        ]).get()
        XCTAssertEqual(request.baseName, "牧青1348－高牧(詩8)")
        XCTAssertEqual(request.outputPath, "/tmp/out/牧青1348－高牧(詩8).aif")
    }

    func testParsesAllOptions() throws {
        let request = try parse([
            "directory": "/tmp/out", "filename": "mix", "file_type": "WAVE",
            "bit_depth": "24", "sample_rate": "48000", "overwrite": "true", "timeout_seconds": "120",
        ]).get()
        XCTAssertEqual(request.fileType, .wav)
        XCTAssertEqual(request.bitDepth, 24)
        XCTAssertEqual(request.sampleRate, 48_000)
        XCTAssertTrue(request.overwrite)
        XCTAssertEqual(request.timeoutSeconds, 120)
    }

    func testExpandsTilde() throws {
        let request = try parse(["directory": "~/Music", "filename": "mix"]).get()
        XCTAssertTrue(request.directory.hasPrefix("/"))
        XCTAssertTrue(request.directory.hasSuffix("/Music"))
    }

    func testPreflightChecksTheFileSystem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounce-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var request = try parse(["directory": dir.path, "filename": "mix"]).get()
        XCTAssertNil(request.preflight())

        FileManager.default.createFile(atPath: request.outputPath, contents: Data())
        XCTAssertNotNil(request.preflight(), "an existing file needs overwrite")
        request.overwrite = true
        XCTAssertNil(request.preflight())

        let missing = try parse(["directory": dir.path + "/missing", "filename": "mix"]).get()
        XCTAssertNotNil(missing.preflight())
    }

    func testRejectsBadInput() {
        let cases: [[String: String]] = [
            ["filename": "mix"],
            ["directory": "relative/dir", "filename": "mix"],
            ["directory": "/tmp"],
            ["directory": "/tmp", "filename": "../escape"],
            ["directory": "/tmp", "filename": "a/b"],
            ["directory": "/tmp", "filename": "mix", "file_type": "mp3"],
            ["directory": "/tmp", "filename": "mix", "bit_depth": "20"],
            ["directory": "/tmp", "filename": "mix", "sample_rate": "22050"],
            ["directory": "/tmp", "filename": "mix", "overwrite": "yes"],
            ["directory": "/tmp", "filename": "mix", "timeout_seconds": "1"],
        ]
        for params in cases {
            if case .success = parse(params) {
                XCTFail("Expected failure for \(params)")
            }
        }
    }
}

final class BouncePopupKindTests: XCTestCase {
    func testClassifiesPopupsByValueInAnyLanguage() {
        XCTAssertEqual(BouncePopupKind.classify(value: "WAVE"), .fileType)
        XCTAssertEqual(BouncePopupKind.classify(value: "AIFF"), .fileType)
        XCTAssertEqual(BouncePopupKind.classify(value: "48 kHz"), .sampleRate)
        XCTAssertEqual(BouncePopupKind.classify(value: "44.1 kHz"), .sampleRate)
        XCTAssertEqual(BouncePopupKind.classify(value: "32 位元浮動"), .bitDepth)
        XCTAssertEqual(BouncePopupKind.classify(value: "24-bit"), .bitDepth)
        XCTAssertEqual(BouncePopupKind.classify(value: "16 位元"), .bitDepth)
        XCTAssertEqual(BouncePopupKind.classify(value: "交錯"), .other)
        XCTAssertEqual(BouncePopupKind.classify(value: "無"), .other)
        XCTAssertEqual(BouncePopupKind.classify(value: "Off"), .other)
        XCTAssertEqual(BouncePopupKind.classify(value: nil), .other)
    }

    func testMenuTitleMatching() throws {
        let request = try BounceRequest.parse([
            "directory": "/tmp", "filename": "x", "bit_depth": "24", "sample_rate": "44100",
        ]).get()
        XCTAssertTrue(BouncePopupKind.title("24 位元", matches: .bitDepth, request: request))
        XCTAssertTrue(BouncePopupKind.title("24-bit", matches: .bitDepth, request: request))
        XCTAssertFalse(BouncePopupKind.title("32 位元浮動", matches: .bitDepth, request: request))
        XCTAssertTrue(BouncePopupKind.title("44.1 kHz", matches: .sampleRate, request: request))
        XCTAssertFalse(BouncePopupKind.title("48 kHz", matches: .sampleRate, request: request))
        XCTAssertTrue(BouncePopupKind.title("WAVE", matches: .fileType, request: request))
        XCTAssertFalse(BouncePopupKind.title("CAF", matches: .fileType, request: request))
    }
}
