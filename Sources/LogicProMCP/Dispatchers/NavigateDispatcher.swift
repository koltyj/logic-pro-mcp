import Foundation
import MCP

struct NavigateDispatcher {
    static let tool = Tool(
        name: "logic_navigate",
        description: """
            Navigation and markers in Logic Pro. \
            Commands: goto_bar, get_markers, goto_marker, create_marker, delete_marker, \
            rename_marker, zoom_to_fit, set_zoom, toggle_view. \
            Params by command: \
            goto_bar -> { bar: Int }; \
            goto_marker -> { index: Int } or { name: String }; \
            create_marker -> { name: String } (at current playhead); \
            rename_marker -> { index: Int, name: String }; \
            delete_marker -> { index: Int }; \
            set_zoom -> { level: String } ("in", "out", "fit"); \
            toggle_view -> { view: String } ("mixer", "piano_roll", "score", \
            "step_editor", "library", "inspector", "automation")
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Navigation command to execute"),
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
        case "goto_bar":
            let bar = params["bar"]?.intValue ?? 1
            let result = await router.route(
                operation: "nav.goto_bar",
                params: ["bar": String(bar)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "get_markers":
            let result = await router.route(operation: "nav.get_markers")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "goto_marker":
            let listed = await router.route(operation: "nav.get_markers")
            let decoder = JSONDecoder()
            guard listed.isSuccess,
                  let markers = try? decoder.decode([MarkerState].self, from: Data(listed.message.utf8)) else {
                return CallTool.Result(content: [.text("Cannot read markers: \(listed.message)")], isError: true)
            }
            let marker: MarkerState? = if let index = params["index"]?.intValue {
                markers.first { $0.id == index }
            } else if let name = params["name"]?.stringValue {
                markers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    ?? markers.first { $0.name.localizedCaseInsensitiveContains(name) }
            } else { nil }
            guard let marker, let bar = marker.position.split(separator: " ").first.flatMap({ Int($0) }) else {
                let names = markers.map(\.name).joined(separator: ", ")
                return CallTool.Result(content: [.text("No matching marker. Markers: \(names.isEmpty ? "none" : names)")], isError: true)
            }
            let moved = await router.route(
                operation: "transport.goto_position", params: ["bar": String(bar), "position": "\(bar).1.1.1"]
            )
            let text = moved.isSuccess ? "Playhead at marker '\(marker.name)' (bar \(bar))" : moved.message
            return CallTool.Result(content: [.text(text)], isError: !moved.isSuccess)

        case "create_marker":
            let name = params["name"]?.stringValue ?? "Marker"
            let result = await router.route(
                operation: "nav.create_marker",
                params: ["name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "delete_marker":
            let index = params["index"]?.intValue ?? 0
            let result = await router.route(
                operation: "nav.delete_marker",
                params: ["index": String(index)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "rename_marker":
            let index = params["index"]?.intValue ?? 0
            let name = params["name"]?.stringValue ?? ""
            let result = await router.route(
                operation: "nav.rename_marker",
                params: ["index": String(index), "name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "zoom_to_fit":
            let result = await router.route(operation: "nav.zoom_to_fit")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_zoom":
            let level = params["level"]?.stringValue ?? "fit"
            switch level {
            case "in":
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": "8"]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            case "out":
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": "2"]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            case "fit":
                let result = await router.route(operation: "nav.zoom_to_fit")
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            default:
                // Treat as numeric zoom level
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": level]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }

        case "toggle_view":
            let view = params["view"]?.stringValue ?? "mixer"
            let operation: String
            switch view {
            case "mixer": operation = "view.toggle_mixer"
            case "piano_roll": operation = "view.toggle_piano_roll"
            case "score": operation = "view.toggle_score_editor"
            case "step_editor": operation = "view.toggle_step_editor"
            case "library": operation = "view.toggle_library"
            case "inspector": operation = "view.toggle_inspector"
            case "automation": operation = "automation.toggle_view"
            default:
                return CallTool.Result(
                    content: [.text("Unknown view: \(view). Available: mixer, piano_roll, score, step_editor, library, inspector, automation")],
                    isError: true
                )
            }
            let result = await router.route(operation: operation)
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown navigate command: \(command). Available: goto_bar, get_markers, goto_marker, create_marker, delete_marker, rename_marker, zoom_to_fit, set_zoom, toggle_view")],
                isError: true
            )
        }
    }
}
