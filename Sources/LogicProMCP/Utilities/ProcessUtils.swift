import Foundation
import AppKit

/// Utilities for finding and interacting with the Logic Pro process.
enum ProcessUtils {
    /// Returns the running Logic Pro application for a supported bundle ID.
    static func logicProApp() -> NSRunningApplication? {
        for bundleID in ServerConfig.logicProBundleIDs {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first {
                return app
            }
        }
        return nil
    }

    /// Returns the PID of Logic Pro if running, nil otherwise.
    static func logicProPID() -> pid_t? {
        logicProApp()?.processIdentifier
    }

    /// AppleScript target for the detected Logic Pro variant.
    static var logicProAppleScriptTarget: String {
        guard let bundleID = logicProApp()?.bundleIdentifier else {
            return "application \"\(ServerConfig.logicProProcessName)\""
        }
        return "application id \"\(bundleID)\""
    }

    /// System Events target for the detected Logic Pro process.
    static var logicProSystemEventsProcessTarget: String {
        guard let app = logicProApp() else {
            return "process \"\(ServerConfig.logicProProcessName)\""
        }
        return "first process whose unix id is \(app.processIdentifier)"
    }

    /// Whether Logic Pro is currently running.
    static var isLogicProRunning: Bool {
        logicProApp() != nil
    }

    /// Whether Logic Pro is currently the frontmost application.
    static var isLogicProFrontmost: Bool {
        logicProApp()?.isActive ?? false
    }

    /// Bring Logic Pro to front. Required before posting CGEvents: Logic Pro
    /// silently discards synthetic key events unless it is the active app.
    static func activateLogicPro() -> Bool {
        logicProApp()?.activate() ?? false
    }
}
