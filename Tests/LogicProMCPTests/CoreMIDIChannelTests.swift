import XCTest
@testable import LogicProMCP

final class CoreMIDIChannelTests: XCTestCase {
    func testCoreMIDIHandlesAdvertisedMIDIOperations() async throws {
        let channel = CoreMIDIChannel(engine: MIDIEngine())
        try await channel.start()

        let cases: [(operation: String, params: [String: String])] = [
            ("midi.send_note", ["note": "60", "velocity": "100", "channel": "1", "duration_ms": "0"]),
            ("midi.send_chord", ["notes": "60,64,67", "velocity": "100", "channel": "1", "duration_ms": "0"]),
            ("midi.send_cc", ["controller": "1", "value": "64", "channel": "1"]),
            ("midi.send_program_change", ["program": "8", "channel": "1"]),
            ("midi.send_pitch_bend", ["value": "-8192", "channel": "1"]),
            ("midi.send_aftertouch", ["value": "64", "channel": "1"]),
            ("midi.send_aftertouch", ["pressure": "64", "channel": "1"]),
            ("midi.send_sysex", ["data": "F0 7F 7F 06 02 F7"]),
            ("midi.send_sysex", ["bytes": "F0 7F 7F 06 02 F7"]),
        ]

        for testCase in cases {
            let result = await channel.execute(operation: testCase.operation, params: testCase.params)
            guard case .unverified = result else {
                return XCTFail("\(testCase.operation) should be unverified, got: \(result.message)")
            }
        }

        let ports = await channel.execute(operation: "midi.list_ports", params: [:])
        guard case .success(let json) = ports,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return XCTFail("midi.list_ports should return JSON")
        }
        XCTAssertNotNil(object["sources"])
        XCTAssertNotNil(object["destinations"])

        let virtualPort = await channel.execute(
            operation: "midi.create_virtual_port",
            params: ["name": "Test Port"]
        )
        XCTAssertTrue(virtualPort.isSuccess)

        await channel.stop()
    }

    func testCoreMIDIKeepsLegacyPitchBendAlias() async throws {
        let channel = CoreMIDIChannel(engine: MIDIEngine())
        try await channel.start()

        let result = await channel.execute(
            operation: "midi.pitch_bend",
            params: ["value": "0", "channel": "1"]
        )

        guard case .unverified = result else {
            return XCTFail("midi.pitch_bend should be accepted as unverified")
        }

        await channel.stop()
    }

    func testCoreMIDIHandlesAdvertisedMMCOperations() async throws {
        let channel = CoreMIDIChannel(engine: MIDIEngine())
        try await channel.start()

        let cases: [(operation: String, params: [String: String])] = [
            ("mmc.play", [:]),
            ("mmc.stop", [:]),
            ("mmc.record_strobe", [:]),
            ("mmc.pause", [:]),
            ("mmc.locate", ["time": "00:00:01:12"]),
            ("mmc.locate", ["hours": "0", "minutes": "0", "seconds": "1", "frames": "12", "subframes": "0"]),
            ("transport.locate", ["position": "00:00:01:12"]),
        ]

        for testCase in cases {
            let result = await channel.execute(operation: testCase.operation, params: testCase.params)
            guard case .unverified = result else {
                return XCTFail("\(testCase.operation) should be unverified, got: \(result.message)")
            }
        }

        await channel.stop()
    }

    func testCoreMIDIRejectsMalformedMIDIParameters() async {
        let channel = CoreMIDIChannel(engine: MIDIEngine())

        let cases: [(operation: String, params: [String: String])] = [
            ("midi.send_chord", ["notes": "60,bad,67"]),
            ("midi.send_chord", ["notes": "60,128,67"]),
            ("midi.send_chord", ["notes": "60,,67"]),
            ("midi.send_sysex", ["data": "F0 7F nope F7"]),
            ("mmc.locate", ["time": "00:60:01:12"]),
            ("mmc.locate", ["time": "00:00:01:12:"]),
            ("mmc.locate", ["time": "00:00:01:30"]),
            ("mmc.locate", ["hours": "0", "minutes": "0", "seconds": "1", "frames": "60"]),
            ("mmc.locate", ["time": "00:00:01:12", "subframes": "100"]),
        ]

        for testCase in cases {
            let result = await channel.execute(operation: testCase.operation, params: testCase.params)
            XCTAssertFalse(
                result.isSuccess,
                "\(testCase.operation) should reject malformed params, got: \(result.message)"
            )
        }

        await channel.stop()
    }
}
