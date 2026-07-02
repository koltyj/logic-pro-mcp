import XCTest
@testable import LogicProMCP

final class CoreMIDIChannelTests: XCTestCase {
    func testAdvertisedMIDIOperationsSucceed() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        assertSuccess(await channel.execute(
            operation: "midi.send_program_change",
            params: ["program": "12", "channel": "0"]
        ))
        assertSuccess(await channel.execute(
            operation: "midi.send_pitch_bend",
            params: ["value": "-8192", "channel": "0"]
        ))
        assertSuccess(await channel.execute(
            operation: "midi.send_aftertouch",
            params: ["value": "64", "channel": "0"]
        ))
    }

    func testAdvertisedMMCOperationsSucceed() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        for operation in ["mmc.play", "mmc.stop", "mmc.record_strobe", "mmc.record_exit", "mmc.pause"] {
            assertSuccess(await channel.execute(operation: operation, params: [:]))
        }
        assertSuccess(await channel.execute(operation: "mmc.locate", params: ["time": "01:02:03:04"]))
    }

    func testParameterAliasesSucceed() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        assertSuccess(await channel.execute(
            operation: "midi.send_sysex",
            params: ["bytes": "F0 7F 7F 06 02 F7"]
        ))
        assertSuccess(await channel.execute(
            operation: "midi.send_sysex",
            params: ["data": "F0 7F 7F 06 01 F7"]
        ))
        assertSuccess(await channel.execute(
            operation: "midi.send_aftertouch",
            params: ["pressure": "80", "channel": "0"]
        ))
        assertSuccess(await channel.execute(
            operation: "midi.send_aftertouch",
            params: ["value": "81", "channel": "0"]
        ))
        assertSuccess(await channel.execute(operation: "mmc.locate", params: ["bar": "4"]))
        assertSuccess(await channel.execute(operation: "mmc.locate", params: ["time": "00:00:10:00"]))
    }

    func testChordAndVirtualPortSucceed() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        assertSuccess(await channel.execute(
            operation: "midi.send_chord",
            params: ["notes": "60,64,67", "velocity": "90", "channel": "0", "duration_ms": "1"]
        ))
        assertSuccess(await channel.execute(
            operation: "midi.create_virtual_port",
            params: ["name": "LogicProMCP-Test-\(UUID().uuidString)"]
        ))
        await channel.stop()
    }

    func testPitchBendClampsSignedAdvertisedRange() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        let lowResult = await channel.execute(
            operation: "midi.send_pitch_bend",
            params: ["value": "-9000", "channel": "0"]
        )
        assertSuccess(lowResult)
        XCTAssertEqual(lowResult.message, "Pitch bend 0 on ch 0")

        let highResult = await channel.execute(
            operation: "midi.send_pitch_bend",
            params: ["value": "9000", "channel": "0"]
        )
        assertSuccess(highResult)
        XCTAssertEqual(highResult.message, "Pitch bend 16383 on ch 0")
    }

    func testSysExRejectsMissingFraming() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        let result = await channel.execute(
            operation: "midi.send_sysex",
            params: ["data": "7F 7F 06 02"]
        )

        assertError(result, contains: "SysEx must start with F0 and end with F7")
    }

    func testUnknownOperationsStillError() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        let result = await channel.execute(operation: "midi.not_real", params: [:])

        assertError(result, contains: "Unknown CoreMIDI operation: midi.not_real")
    }

    func testInternalAliasesStillSucceed() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        assertSuccess(await channel.execute(
            operation: "midi.program_change",
            params: ["program": "12", "channel": "0"]
        ))
        assertSuccess(await channel.execute(
            operation: "midi.pitch_bend",
            params: ["value": "8192", "channel": "0"]
        ))
    }

    private func assertSuccess(
        _ result: ChannelResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .success = result else {
            XCTFail("Expected success, got \(result)", file: file, line: line)
            return
        }
    }

    private func assertError(
        _ result: ChannelResult,
        contains message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .error(let error) = result else {
            XCTFail("Expected error, got \(result)", file: file, line: line)
            return
        }
        XCTAssertTrue(error.contains(message), "Expected '\(error)' to contain '\(message)'", file: file, line: line)
    }
}
