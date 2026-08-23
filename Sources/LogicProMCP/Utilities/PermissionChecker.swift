import Foundation
import ApplicationServices
import CoreServices

/// Checks macOS permissions required for the server to operate.
enum PermissionChecker {

    /// Result of an Apple Events (Automation) permission query.
    ///
    /// TCC distinguishes "denied" from "never asked", and the two need
    /// different advice, so this is deliberately not a Bool.
    enum AutomationStatus: Sendable, Equatable {
        case granted
        case denied
        case notYetRequested
        case targetNotRunning
        case unknown(OSStatus)

        var isGranted: Bool { self == .granted }

        var describedStatus: String {
            switch self {
            case .granted:          return "granted"
            case .denied:           return "NOT GRANTED (denied)"
            case .notYetRequested:  return "NOT GRANTED (not yet requested)"
            case .targetNotRunning: return "unknown (Logic Pro is not running)"
            case .unknown(let code): return "unknown (OSStatus \(code))"
            }
        }
    }

    struct PermissionStatus: Sendable {
        let accessibility: Bool
        let automation: AutomationStatus

        /// Kept for existing callers that only need a yes/no.
        var automationLogicPro: Bool { automation.isGranted }

        var allGranted: Bool { accessibility && automation.isGranted }

        var summary: String {
            var lines: [String] = []
            lines.append("Accessibility: \(accessibility ? "granted" : "NOT GRANTED")")
            lines.append("Automation (Logic Pro): \(automation.describedStatus)")
            if !accessibility {
                lines.append("  → System Settings > Privacy & Security > Accessibility → add your terminal app")
            }
            switch automation {
            case .denied:
                lines.append("  → System Settings > Privacy & Security > Automation → allow control of Logic Pro")
            case .notYetRequested:
                lines.append("  → macOS has not asked yet; it prompts on the first Apple Event to Logic Pro")
            case .targetNotRunning:
                lines.append("  → start Logic Pro to determine the Automation state")
            case .granted, .unknown:
                break
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

    /// Query the Apple Events (Automation) permission for Logic Pro.
    ///
    /// Asks TCC directly via AEDeterminePermissionToAutomateTarget, which
    /// reports the real authorization state without dispatching an event.
    ///
    /// The previous implementation ran `tell application "Logic Pro" to return
    /// name` and treated "no error" as granted. macOS answers `name` from the
    /// target's bundle metadata without sending an Apple Event at all, so that
    /// check succeeded even for apps that were not running and had never been
    /// granted anything — it could never report a denial. Its only real signal
    /// was whether Logic Pro was running.
    ///
    /// Pass `promptIfNeeded: true` to let macOS show its consent dialog; the
    /// default queries silently.
    static func checkAutomation(promptIfNeeded: Bool = false) -> AutomationStatus {
        guard var pid = ProcessUtils.logicProPID() else { return .targetNotRunning }

        var target = AEAddressDesc()
        let createStatus = withUnsafePointer(to: &pid) { pidPtr in
            AECreateDesc(typeKernelProcessID, pidPtr, MemoryLayout<pid_t>.size, &target)
        }
        guard createStatus == noErr else { return .unknown(OSStatus(createStatus)) }
        defer { AEDisposeDesc(&target) }

        // typeWildCard for class and ID asks about automating the target at all,
        // rather than about one specific event.
        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, promptIfNeeded
        )

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notYetRequested
        case OSStatus(procNotFound):
            return .targetNotRunning
        default:
            return .unknown(status)
        }
    }

    /// Full permission check.
    static func check() -> PermissionStatus {
        PermissionStatus(
            accessibility: checkAccessibility(),
            automation: checkAutomation()
        )
    }
}
