import Foundation
import MCP

struct TransportDispatcher {
    static let tool = Tool(
        name: "logic_transport",
        description: """
            Control Logic Pro transport. \
            Commands: play, stop, record, pause, rewind, fast_forward, \
            toggle_cycle, toggle_metronome, set_tempo, goto_position, \
            set_cycle_range, toggle_count_in. \
            Params by command: \
            set_tempo -> { tempo: Float } (20.0-999.0); \
            goto_position -> { bar: Int } or { time: "HH:MM:SS:FF" }; \
            set_cycle_range -> { start: Int, end: Int } (bar numbers); \
            Others -> {} (no params)
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Transport command to execute"),
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
        case "play":
            let result = await router.route(operation: "transport.play")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "stop":
            let result = await router.route(operation: "transport.stop")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "record":
            let result = await router.route(operation: "transport.record")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "pause":
            let result = await router.route(operation: "transport.pause")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "rewind":
            let result = await router.route(operation: "transport.rewind")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "fast_forward":
            let result = await router.route(operation: "transport.fast_forward")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "toggle_cycle":
            let result = await router.route(operation: "transport.toggle_cycle")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "toggle_metronome":
            let result = await router.route(operation: "transport.toggle_metronome")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "toggle_count_in":
            let result = await router.route(operation: "transport.toggle_count_in")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_tempo":
            let tempoResult = InputValidation.double(params, keys: ["tempo", "bpm"], default: 120.0, range: 20.0...999.0, label: "tempo")
            guard case .success(let tempo) = tempoResult else { return tempoResult.callToolResult() }
            let result = await router.route(
                operation: "transport.set_tempo",
                params: ["bpm": String(tempo)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "goto_position":
            if let bar = params["bar"]?.intValue {
                guard bar >= 1 else {
                    return CallTool.Result(content: [.text("bar must be 1 or greater")], isError: true)
                }
                let result = await router.route(
                    operation: "transport.goto_position",
                    params: ["position": "\(bar).1.1.1"]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            let time = params["time"]?.stringValue
                ?? params["position"]?.stringValue
                ?? "1.1.1.1"
            guard Self.isSafePosition(time) else {
                return CallTool.Result(content: [.text("time/position must use digits separated by ':' or '.'")], isError: true)
            }
            let result = await router.route(
                operation: "transport.goto_position",
                params: ["position": time]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_cycle_range":
            let start = params["start"]?.intValue ?? 1
            let end = params["end"]?.intValue ?? 5
            guard start >= 1, end >= start else {
                return CallTool.Result(content: [.text("cycle range requires start >= 1 and end >= start")], isError: true)
            }
            let result = await router.route(
                operation: "transport.set_cycle_range",
                params: ["start": "\(start).1.1.1", "end": "\(end).1.1.1"]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown transport command: \(command). Available: play, stop, record, pause, rewind, fast_forward, toggle_cycle, toggle_metronome, set_tempo, goto_position, set_cycle_range, toggle_count_in")],
                isError: true
            )
        }
    }

    private static func isSafePosition(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789:.")
        return !value.isEmpty
            && value.count <= 32
            && value.rangeOfCharacter(from: allowed.inverted) == nil
            && value.contains { $0 == "." || $0 == ":" }
    }
}
