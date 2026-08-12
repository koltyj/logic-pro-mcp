import Foundation
import MCP

struct ProjectDispatcher {
    static let tool = Tool(
        name: "logic_project",
        description: """
            Project lifecycle in Logic Pro. \
            Commands: new, open, save, save_as, close, bounce, launch, quit. \
            Params by command: \
            open -> { path: String }; \
            save_as -> { path: String }; \
            bounce -> {} (opens bounce dialog); \
            launch/quit -> {} (app lifecycle); \
            Others -> {}
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Project command to execute"),
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
        case "new":
            let result = await router.route(operation: "project.new")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "open":
            let path: String
            switch InputValidation.logicProjectPath(params, mustExist: true) {
            case .success(let validatedPath):
                path = validatedPath
            case .failure(let message):
                return CallTool.Result(content: [.text(message)], isError: true)
            }
            let result = await router.route(
                operation: "project.open",
                params: ["path": path]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "save":
            let result = await router.route(operation: "project.save")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "save_as":
            let path: String
            switch InputValidation.logicProjectPath(params, mustExist: false) {
            case .success(let validatedPath):
                path = validatedPath
            case .failure(let message):
                return CallTool.Result(content: [.text(message)], isError: true)
            }
            let result = await router.route(
                operation: "project.save_as",
                params: ["path": path]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "close":
            let result = await router.route(operation: "project.close")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "bounce":
            let result = await router.route(operation: "project.bounce")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "launch":
            if ProcessUtils.isLogicProRunning {
                return CallTool.Result(content: [.text("Logic Pro is already running")], isError: false)
            }
            let scripts = ServerConfig.logicProBundleIDs.map {
                "tell application id \"\($0)\" to activate"
            } + ["tell application \"\(ServerConfig.logicProProcessName)\" to activate"]

            for script in scripts where (try? runAppleScript(script)) == true {
                return CallTool.Result(content: [.text("Logic Pro launched")], isError: false)
            }

            return CallTool.Result(content: [.text("Failed to launch Logic Pro")], isError: true)

        case "quit":
            if !ProcessUtils.isLogicProRunning {
                return CallTool.Result(content: [.text("Logic Pro is not running")], isError: false)
            }
            do {
                if try runAppleScript("tell \(ProcessUtils.logicProAppleScriptTarget) to quit") {
                    return CallTool.Result(content: [.text("Logic Pro quit")], isError: false)
                }
                return CallTool.Result(content: [.text("Failed to quit Logic Pro")], isError: true)
            } catch {
                return CallTool.Result(content: [.text("Failed to quit Logic Pro: \(error)")], isError: true)
            }

        default:
            return CallTool.Result(
                content: [.text("Unknown project command: \(command). Available: new, open, save, save_as, close, bounce, launch, quit")],
                isError: true
            )
        }
    }

    private static func runAppleScript(_ script: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        let deadline = Date().addingTimeInterval(ServerConfig.appleScriptTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            process.terminate()
            throw NSError(
                domain: "LogicProMCP.AppleScript",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AppleScript timed out"]
            )
        }
        return process.terminationStatus == 0
    }
}
