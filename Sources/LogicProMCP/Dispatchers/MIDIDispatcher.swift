import Foundation
import MCP

struct MIDIDispatcher {
    static let tool = Tool(
        name: "logic_midi",
        description: """
            MIDI operations in Logic Pro. \
            Commands: send_note, send_chord, send_sequence, send_cc, send_program_change, \
            send_pitch_bend, send_aftertouch, send_sysex, \
            create_virtual_port, mmc_play, mmc_stop, mmc_record, mmc_locate. \
            Params by command: \
            send_note -> { note: Int, velocity: Int, channel: Int, duration_ms: Int }; \
            send_chord -> { notes: [Int], velocity: Int, channel: Int, duration_ms: Int }; \
            send_sequence -> { events: [...], channel: Int } where each event is one of \
            {type:"note", note: Int, velocity: Int?, channel: Int?, duration_ms: Int?, time_ms: Int?}, \
            {type:"chord", notes: [Int], velocity: Int?, channel: Int?, duration_ms: Int?, time_ms: Int?}, \
            {type:"rest", duration_ms: Int?, time_ms: Int?}, \
            {type:"cc", controller: Int, value: Int, channel: Int?, time_ms: Int?}, \
            {type:"program_change", program: Int, channel: Int?, time_ms: Int?} \
            (time_ms = absolute start; events without time_ms play sequentially); \
            send_cc -> { controller: Int, value: Int, channel: Int }; \
            send_program_change -> { program: Int, channel: Int }; \
            send_pitch_bend -> { value: Int, channel: Int } (-8192 to 8191); \
            send_aftertouch -> { value: Int, channel: Int }; \
            send_sysex -> { bytes: [Int] } or { data: String } (hex); \
            mmc_locate -> { bar: Int } or { time: "HH:MM:SS:FF" }; \
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
            let note = params["note"]?.intValue ?? 60
            let velocity = params["velocity"]?.intValue ?? 100
            let channel = params["channel"]?.intValue ?? 1
            let durationMs = params["duration_ms"]?.intValue ?? 500
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
            // Accept either array of ints or comma-separated string
            let notesStr: String
            if let arr = params["notes"]?.arrayValue {
                notesStr = arr.compactMap { $0.intValue }.map(String.init).joined(separator: ",")
            } else {
                notesStr = params["notes"]?.stringValue ?? ""
            }
            let velocity = params["velocity"]?.intValue ?? 100
            let channel = params["channel"]?.intValue ?? 1
            let durationMs = params["duration_ms"]?.intValue ?? 500
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

        case "send_sequence":
            // Accept events as a JSON array (already a Value array from MCP).
            // Reject anything that can't be represented instead of silently
            // dropping it -- a mixed-validity request must not report success
            // while playing fewer or altered events than submitted.
            let eventsJSON: String
            if let arr = params["events"]?.arrayValue {
                var jsonEvents: [[String: Any]] = []
                for (index, item) in arr.enumerated() {
                    guard case .object(let obj) = item else {
                        return CallTool.Result(
                            content: [.text("send_sequence: event \(index) is not an object")],
                            isError: true
                        )
                    }
                    var dict: [String: Any] = [:]
                    for (k, v) in obj {
                        if let i = v.intValue { dict[k] = i }
                        else if let d = v.doubleValue { dict[k] = Int(d) }
                        else if let s = v.stringValue { dict[k] = s }
                        else if let a = v.arrayValue {
                            var members: [Int] = []
                            for (memberIndex, member) in a.enumerated() {
                                if let i = member.intValue { members.append(i) }
                                else if let d = member.doubleValue { members.append(Int(d)) }
                                else {
                                    return CallTool.Result(
                                        content: [.text("send_sequence: event \(index) field '\(k)'[\(memberIndex)] is not a number")],
                                        isError: true
                                    )
                                }
                            }
                            dict[k] = members
                        }
                        else {
                            return CallTool.Result(
                                content: [.text("send_sequence: event \(index) field '\(k)' has an unsupported type")],
                                isError: true
                            )
                        }
                    }
                    jsonEvents.append(dict)
                }
                guard let data = try? JSONSerialization.data(withJSONObject: jsonEvents),
                      let str = String(data: data, encoding: .utf8) else {
                    return CallTool.Result(
                        content: [.text("send_sequence: failed to encode events")],
                        isError: true
                    )
                }
                eventsJSON = str
            } else if let str = params["events"]?.stringValue {
                eventsJSON = str
            } else {
                return CallTool.Result(
                    content: [.text("send_sequence requires 'events' (array of event objects, or a JSON string)")],
                    isError: true
                )
            }
            let seqChannel = params["channel"]?.intValue ?? 1
            let seqResult = await router.route(
                operation: "midi.send_sequence",
                params: [
                    "events": eventsJSON,
                    "channel": String(seqChannel),
                ]
            )
            return CallTool.Result(content: [.text(seqResult.message)], isError: !seqResult.isSuccess)

        case "send_cc":
            let controller = params["controller"]?.intValue ?? 0
            let value = params["value"]?.intValue ?? 0
            let channel = params["channel"]?.intValue ?? 1
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
            let program = params["program"]?.intValue ?? 0
            let channel = params["channel"]?.intValue ?? 1
            let result = await router.route(
                operation: "midi.send_program_change",
                params: ["program": String(program), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_pitch_bend":
            let value = params["value"]?.intValue ?? 0
            let channel = params["channel"]?.intValue ?? 1
            let result = await router.route(
                operation: "midi.send_pitch_bend",
                params: ["value": String(value), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_aftertouch":
            let value = params["value"]?.intValue ?? 0
            let channel = params["channel"]?.intValue ?? 1
            let result = await router.route(
                operation: "midi.send_aftertouch",
                params: ["value": String(value), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_sysex":
            let data: String
            if let bytes = params["bytes"]?.arrayValue {
                data = bytes.compactMap { $0.intValue }
                    .map { String(format: "%02X", $0) }
                    .joined(separator: " ")
            } else {
                data = params["data"]?.stringValue ?? ""
            }
            let result = await router.route(
                operation: "midi.send_sysex",
                params: ["data": data]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "create_virtual_port":
            let name = params["name"]?.stringValue ?? "Virtual Port"
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
            if let bar = params["bar"]?.intValue {
                let result = await router.route(
                    operation: "mmc.locate",
                    params: ["bar": String(bar)]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            let time = params["time"]?.stringValue ?? "00:00:00:00"
            let result = await router.route(
                operation: "mmc.locate",
                params: ["time": time]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown MIDI command: \(command). Available: send_note, send_chord, send_sequence, send_cc, send_program_change, send_pitch_bend, send_aftertouch, send_sysex, create_virtual_port, mmc_play, mmc_stop, mmc_record, mmc_locate")],
                isError: true
            )
        }
    }
}
