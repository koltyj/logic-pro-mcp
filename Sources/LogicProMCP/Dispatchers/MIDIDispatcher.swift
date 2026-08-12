import Foundation
import MCP

struct MIDIDispatcher {
    static let tool = Tool(
        name: "logic_midi",
        description: """
            MIDI operations in Logic Pro. \
            Commands: send_note, send_chord, send_cc, send_program_change, \
            send_pitch_bend, send_aftertouch, send_sysex, \
            create_virtual_port, mmc_play, mmc_stop, mmc_record, mmc_locate. \
            Params by command: \
            send_note -> { note: Int, velocity: Int, channel: Int, duration_ms: Int }; \
            send_chord -> { notes: [Int], velocity: Int, channel: Int, duration_ms: Int }; \
            send_cc -> { controller: Int, value: Int, channel: Int }; \
            send_program_change -> { program: Int, channel: Int }; \
            send_pitch_bend -> { value: Int, channel: Int } (-8192 to 8191); \
            send_aftertouch -> { value: Int, channel: Int }; \
            send_sysex -> { bytes: [Int] } or { data: String } (hex); \
            mmc_locate -> { time: "HH:MM:SS:FF" }; \
            create_virtual_port -> { name: String }
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("MIDI command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "send_note":
            let note: Int
            let velocity: Int
            let channel: Int
            let durationMs: Int
            switch InputValidation.int(params, keys: ["note"], default: 60, range: 0...127, label: "note") {
            case .success(let value): note = value
            case .failure(let message): return error(message)
            }
            switch InputValidation.int(params, keys: ["velocity"], default: 100, range: 0...127, label: "velocity") {
            case .success(let value): velocity = value
            case .failure(let message): return error(message)
            }
            switch InputValidation.midiChannel(params) {
            case .success(let value): channel = value
            case .failure(let message): return error(message)
            }
            switch InputValidation.int(params, keys: ["duration_ms"], default: 500, range: 0...10_000, label: "duration_ms") {
            case .success(let value): durationMs = value
            case .failure(let message): return error(message)
            }
            let result = await router.route(
                operation: "midi.send_note",
                params: [
                    "note": String(note),
                    "velocity": String(velocity),
                    "channel": String(channel),
                    "duration_ms": String(durationMs),
                ]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_chord":
            let notesStr: String
            let velocity: Int
            let channel: Int
            let durationMs: Int
            switch InputValidation.midiNotes(params) {
            case .success(let value): notesStr = value
            case .failure(let message): return error(message)
            }
            switch InputValidation.int(params, keys: ["velocity"], default: 100, range: 0...127, label: "velocity") {
            case .success(let value): velocity = value
            case .failure(let message): return error(message)
            }
            switch InputValidation.midiChannel(params) {
            case .success(let value): channel = value
            case .failure(let message): return error(message)
            }
            switch InputValidation.int(params, keys: ["duration_ms"], default: 500, range: 0...10_000, label: "duration_ms") {
            case .success(let value): durationMs = value
            case .failure(let message): return error(message)
            }
            let result = await router.route(
                operation: "midi.send_chord",
                params: [
                    "notes": notesStr,
                    "velocity": String(velocity),
                    "channel": String(channel),
                    "duration_ms": String(durationMs),
                ]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_cc":
            let controller: Int
            let value: Int
            let channel: Int
            switch InputValidation.int(params, keys: ["controller"], default: 0, range: 0...127, label: "controller") {
            case .success(let parsed): controller = parsed
            case .failure(let message): return error(message)
            }
            switch InputValidation.int(params, keys: ["value"], default: 0, range: 0...127, label: "value") {
            case .success(let parsed): value = parsed
            case .failure(let message): return error(message)
            }
            switch InputValidation.midiChannel(params) {
            case .success(let parsed): channel = parsed
            case .failure(let message): return error(message)
            }
            let result = await router.route(
                operation: "midi.send_cc",
                params: [
                    "controller": String(controller),
                    "value": String(value),
                    "channel": String(channel),
                ]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_program_change":
            let program: Int
            let channel: Int
            switch InputValidation.int(params, keys: ["program"], default: 0, range: 0...127, label: "program") {
            case .success(let value): program = value
            case .failure(let message): return error(message)
            }
            switch InputValidation.midiChannel(params) {
            case .success(let value): channel = value
            case .failure(let message): return error(message)
            }
            let result = await router.route(
                operation: "midi.send_program_change",
                params: ["program": String(program), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_pitch_bend":
            let value: Int
            let channel: Int
            switch InputValidation.int(params, keys: ["value"], default: 0, range: -8192...8191, label: "value") {
            case .success(let parsed): value = parsed
            case .failure(let message): return error(message)
            }
            switch InputValidation.midiChannel(params) {
            case .success(let parsed): channel = parsed
            case .failure(let message): return error(message)
            }
            let result = await router.route(
                operation: "midi.send_pitch_bend",
                params: ["value": String(value), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_aftertouch":
            let value: Int
            let channel: Int
            switch InputValidation.int(params, keys: ["value"], default: 0, range: 0...127, label: "value") {
            case .success(let parsed): value = parsed
            case .failure(let message): return error(message)
            }
            switch InputValidation.midiChannel(params) {
            case .success(let parsed): channel = parsed
            case .failure(let message): return error(message)
            }
            let result = await router.route(
                operation: "midi.send_aftertouch",
                params: ["value": String(value), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_sysex":
            let data: String
            if let bytes = params["bytes"]?.arrayValue {
                let parsed = bytes.compactMap(\.intValue)
                guard parsed.count == bytes.count, parsed.count <= 1_024,
                      parsed.allSatisfy({ (0...255).contains($0) }) else {
                    return error("bytes must contain at most 1024 values between 0 and 255")
                }
                data = parsed.map { String(format: "%02X", $0) }.joined(separator: " ")
            } else {
                data = params["data"]?.stringValue ?? ""
            }
            let tokens = data.split { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }
            let parsed = tokens.compactMap { UInt8($0, radix: 16) }
            guard parsed.count == tokens.count, (2...1_024).contains(parsed.count),
                  parsed.first == 0xF0, parsed.last == 0xF7 else {
                return error("SysEx must be 2-1024 hex bytes starting with F0 and ending with F7")
            }
            let result = await router.route(
                operation: "midi.send_sysex",
                params: ["data": parsed.map { String(format: "%02X", $0) }.joined(separator: " ")]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "create_virtual_port":
            let name: String
            switch InputValidation.string(params, keys: ["name"], default: "Virtual Port", maxLength: 64, label: "name") {
            case .success(let value): name = value
            case .failure(let message): return error(message)
            }
            let result = await router.route(
                operation: "midi.create_virtual_port",
                params: ["name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_play":
            let result = await router.route(operation: "mmc.play")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_stop":
            let result = await router.route(operation: "mmc.stop")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_record":
            let result = await router.route(operation: "mmc.record_strobe")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_locate":
            if params["bar"] != nil {
                return error("mmc_locate requires time as HH:MM:SS:FF; bar positions cannot be converted without tempo and time-signature context")
            }
            let time = params["time"]?.stringValue ?? "00:00:00:00"
            let result = await router.route(
                operation: "mmc.locate",
                params: ["time": time]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown MIDI command: \(command). Available: send_note, send_chord, send_cc, send_program_change, send_pitch_bend, send_aftertouch, send_sysex, create_virtual_port, mmc_play, mmc_stop, mmc_record, mmc_locate")],
                isError: true
            )
        }
    }

    private static func error(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(message)], isError: true)
    }
}
