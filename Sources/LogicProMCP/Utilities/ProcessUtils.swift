import Foundation
import AppKit

/// Utilities for finding and interacting with the Logic Pro process.
enum ProcessUtils {
    /// Returns the running Logic Pro application, supporting known bundle IDs.
    static func logicProApp() -> NSRunningApplication? {
        for bundleID in ServerConfig.logicProBundleIDs {
            let apps = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            )
            if let app = apps.first {
                return app
            }
        }
        return nil
    }

    /// Returns the PID of Logic Pro if running, nil otherwise.
    static func logicProPID() -> pid_t? {
        logicProApp()?.processIdentifier
    }

    /// AppleScript application target for the running Logic Pro variant.
    static var logicProAppleScriptTarget: String {
        if let bundleID = logicProApp()?.bundleIdentifier {
            return "application id \"\(bundleID)\""
        }
        return "application \"\(ServerConfig.logicProProcessName)\""
    }

    /// Whether Logic Pro is currently running.
    static var isLogicProRunning: Bool {
        logicProApp() != nil
    }

    /// Bring Logic Pro to front (used sparingly — most operations don't need focus).
    static func activateLogicPro() -> Bool {
        logicProApp()?.activate() ?? false
    }
}
