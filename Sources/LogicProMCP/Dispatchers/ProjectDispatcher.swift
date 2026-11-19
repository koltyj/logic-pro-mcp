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
            bounce -> {} opens the Bounce dialog; \
            bounce -> { directory: String, filename: String, file_type?: "wav"|"aiff"|"caf", \
            bit_depth?: 16|24|32, sample_rate?: Int, overwrite?: Bool, timeout_seconds?: Number } \
            bounces the project (cycle range if Cycle is on) to one PCM file and waits until it is written. \
            Returns { path, bytes }; \
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
            let exportKeys = ["directory", "filename", "file_type", "bit_depth", "sample_rate"]
            guard exportKeys.contains(where: { params[$0] != nil }) else {
                let result = await router.route(operation: "project.bounce")
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            let exportParams = bounceParams(params)
            // Validate before touching Logic, so a bad call never opens the dialog.
            switch BounceRequest.parse(exportParams) {
            case .failure(let error):
                return CallTool.Result(content: [.text(error.message)], isError: true)
            case .success(let request):
                if let problem = request.preflight() {
                    return CallTool.Result(content: [.text(problem.message)], isError: true)
                }
            }
            let opened = await router.route(operation: "project.bounce")
            guard opened.isSuccess else {
                return CallTool.Result(content: [.text(opened.message)], isError: true)
            }
            let result = await router.route(operation: "project.bounce_export", params: exportParams)
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

            if ProcessUtils.isLogicProRunning {
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

    /// Flatten MCP values into the string params channels take.
    static func bounceParams(_ params: [String: Value]) -> [String: String] {
        var result: [String: String] = [:]
        for key in ["directory", "filename", "file_type"] {
            if let value = params[key]?.stringValue { result[key] = value }
        }
        for key in ["bit_depth", "sample_rate"] {
            if let value = params[key]?.intValue {
                result[key] = String(value)
            } else if let value = params[key]?.doubleValue {
                result[key] = value == value.rounded() ? String(Int(value)) : String(value)
            } else if let value = params[key]?.stringValue {
                result[key] = value
            }
        }
        if let value = params["overwrite"]?.boolValue { result["overwrite"] = String(value) }
        if let value = params["timeout_seconds"]?.doubleValue {
            result["timeout_seconds"] = String(value)
        } else if let value = params["timeout_seconds"]?.intValue {
            result["timeout_seconds"] = String(value)
        }
        return result
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
