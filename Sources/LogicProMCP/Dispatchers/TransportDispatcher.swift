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
            let tempo: Double
            switch InputValidation.double(
                params,
                keys: ["tempo", "bpm"],
                default: 120,
                range: 20...999,
                label: "tempo"
            ) {
            case .success(let value): tempo = value
            case .failure(let message):
                return CallTool.Result(content: [.text(message)], isError: true)
            }
            let result = await router.route(
                operation: "transport.set_tempo",
                params: ["bpm": String(tempo)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "goto_position":
            if params["bar"] != nil {
                let bar: Int
                switch InputValidation.int(params, keys: ["bar"], range: 1...999_999, label: "bar") {
                case .success(let value): bar = value
                case .failure(let message):
                    return CallTool.Result(content: [.text(message)], isError: true)
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
                return CallTool.Result(
                    content: [.text("time/position must use digits separated by ':' or '.'")],
                    isError: true
                )
            }
            let result = await router.route(
                operation: "transport.goto_position",
                params: ["position": time]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_cycle_range":
            let start: Int
            let end: Int
            switch InputValidation.int(params, keys: ["start"], default: 1, range: 1...999_999, label: "start") {
            case .success(let value): start = value
            case .failure(let message):
                return CallTool.Result(content: [.text(message)], isError: true)
            }
            switch InputValidation.int(params, keys: ["end"], default: 5, range: 1...999_999, label: "end") {
            case .success(let value): end = value
            case .failure(let message):
                return CallTool.Result(content: [.text(message)], isError: true)
            }
            guard end >= start else {
                return CallTool.Result(content: [.text("end must be greater than or equal to start")], isError: true)
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

    static func isSafePosition(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 32 else { return false }
        guard value.contains(":") != value.contains(".") else { return false }
        let separator: Character = value.contains(":") ? ":" : "."
        let fields = value.split(separator: separator, omittingEmptySubsequences: false)
        return fields.count == 4 && fields.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}
