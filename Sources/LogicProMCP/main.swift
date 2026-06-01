import Foundation

// Handle --check-permissions flag
if CommandLine.arguments.contains("--check-permissions") {
    let status = PermissionChecker.check()
    FileHandle.standardError.write(Data((status.summary + "\n").utf8))
    if status.allGranted {
        exit(0)
    } else {
        exit(1)
    }
}

// Handle `doctor` subcommand
if CommandLine.arguments.contains("doctor") {
    let code = await DoctorCommand.run()
    exit(Int32(code))
}

// Start the MCP server
let server = LogicProServer()
do {
    try await server.start()
} catch {
    Log.error("Server failed: \(error)", subsystem: "main")
    exit(1)
}
