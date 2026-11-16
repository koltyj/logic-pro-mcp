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

// Handle --request-permissions flag
//
// --check-permissions queries TCC without prompting by design, so on a machine
// that has never been asked it reports NOT GRANTED indefinitely and no dialog
// ever appears. This flag is the counterpart: it lets macOS raise both consent
// dialogs so the grants can actually be established.
//
// TCC attributes the request to the responsible process, not to this binary.
// Run it from whichever host normally launches the server — grants obtained
// under Terminal do not carry over to an MCP client that spawns it.
if CommandLine.arguments.contains("--request-permissions") {
    var lines: [String] = []

    let accessibility = PermissionChecker.checkAccessibility(prompt: true)
    lines.append("Accessibility: \(accessibility ? "granted" : "NOT GRANTED")")
    if !accessibility {
        lines.append("  → approve the dialog, then re-run: an already-running process does not pick up the grant")
    }

    // checkAutomation resolves its target by PID, so Logic Pro has to be
    // running or TCC has nothing to be asked about.
    if !ProcessUtils.isLogicProRunning {
        lines.append("Logic Pro is not running — launching it to request Automation access")
        if !ProcessUtils.launchLogicPro() {
            lines.append("Automation (Logic Pro): unknown (could not launch Logic Pro)")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
    }

    let automation = PermissionChecker.checkAutomation(promptIfNeeded: true)
    lines.append("Automation (Logic Pro): \(automation.describedStatus)")
    if case .denied = automation {
        lines.append("  → previously denied; reset with `tccutil reset AppleEvents <host-bundle-id>`, then re-run")
    }

    FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    exit(accessibility && automation.isGranted ? 0 : 1)
}

// Start the MCP server
let server = LogicProServer()
do {
    try await server.start()
} catch {
    Log.error("Server failed: \(error)", subsystem: "main")
    exit(1)
}
