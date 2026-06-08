import XCTest
@testable import LogicProMCP

final class CoreMIDIChannelTests: XCTestCase {
    func testCoreMIDIHandlesAdvertisedMIDIOperations() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        let cases: [(operation: String, params: [String: String])] = [
            ("midi.send_note", ["note": "60", "velocity": "100", "channel": "1", "duration_ms": "0"]),
            ("midi.send_chord", ["notes": "60,64,67", "velocity": "100", "channel": "1", "duration_ms": "0"]),
            ("midi.send_cc", ["controller": "1", "value": "64", "channel": "1"]),
            ("midi.send_program_change", ["program": "8", "channel": "1"]),
            ("midi.send_pitch_bend", ["value": "-8192", "channel": "1"]),
            ("midi.send_aftertouch", ["value": "64", "channel": "1"]),
            ("midi.send_sysex", ["data": "F0 7F 7F 06 02 F7"]),
            ("midi.create_virtual_port", ["name": "Test Port"]),
        ]

        for testCase in cases {
            let result = await channel.execute(operation: testCase.operation, params: testCase.params)
            XCTAssertTrue(
                result.isSuccess,
                "\(testCase.operation) should be handled, got: \(result.message)"
            )
        }

        await channel.stop()
    }

    func testCoreMIDIKeepsLegacyPitchBendAlias() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        let result = await channel.execute(
            operation: "midi.pitch_bend",
            params: ["value": "0", "channel": "1"]
        )

        XCTAssertTrue(result.isSuccess, "midi.pitch_bend should keep accepting raw 14-bit values")
    }

    func testCoreMIDIHandlesAdvertisedMMCOperations() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        let cases: [(operation: String, params: [String: String])] = [
            ("mmc.play", [:]),
            ("mmc.stop", [:]),
            ("mmc.record_strobe", [:]),
            ("mmc.pause", [:]),
            ("mmc.locate", ["time": "00:00:01:12"]),
        ]

        for testCase in cases {
            let result = await channel.execute(operation: testCase.operation, params: testCase.params)
            XCTAssertTrue(
                result.isSuccess,
                "\(testCase.operation) should be handled, got: \(result.message)"
            )
        }
    }
}
