import Foundation
import ApplicationServices

/// Checks macOS permissions required for the server to operate.
enum PermissionChecker {

    struct PermissionStatus: Sendable {
        let accessibility: Bool
        let automationLogicPro: Bool

        var allGranted: Bool { accessibility && automationLogicPro }

        var summary: String {
            var lines: [String] = []
            lines.append("Accessibility: \(accessibility ? "granted" : "NOT GRANTED")")
            lines.append("Automation (Logic Pro): \(automationLogicPro ? "granted" : "NOT GRANTED")")
            if !accessibility {
                lines.append("  → System Settings > Privacy & Security > Accessibility → add your terminal app")
            }
            if !automationLogicPro {
                lines.append("  → System Settings > Privacy & Security > Automation → allow control of Logic Pro")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Check if Accessibility API access is granted.
    /// Uses the trusted check with prompt=false to avoid triggering the system dialog.
    static func checkAccessibility(prompt: Bool = false) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Check if Automation permission for Logic Pro is granted.
    /// This attempts a lightweight AppleScript to test permission.
    static func checkAutomation() -> Bool {
        guard ProcessUtils.isLogicProRunning else {
            // Can't test automation if Logic Pro isn't running
            return false
        }
        let script = NSAppleScript(source: """
            tell \(ProcessUtils.logicProAppleScriptTarget) to return name
        """)
        var errorInfo: NSDictionary?
        _ = script?.executeAndReturnError(&errorInfo)
        return errorInfo == nil
    }

    /// Full permission check.
    static func check() -> PermissionStatus {
        PermissionStatus(
            accessibility: checkAccessibility(),
            automationLogicPro: checkAutomation()
        )
    }
}
