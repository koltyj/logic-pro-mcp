import Foundation
import AppKit

/// Utilities for finding and interacting with the Logic Pro process.
enum ProcessUtils {
    /// Returns the PID of any recognised Logic Pro variant if running.
    /// Checks all bundle IDs in ServerConfig.logicProBundleIDs (desktop + Creator Studio).
    static func logicProPID() -> pid_t? {
        for bundleID in ServerConfig.logicProBundleIDs {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first {
                return app.processIdentifier
            }
        }
        return nil
    }

    /// Whether any Logic Pro variant is currently running.
    static var isLogicProRunning: Bool {
        logicProPID() != nil
    }

    /// Bring Logic Pro to front (whichever variant is running).
    static func activateLogicPro() -> Bool {
        for bundleID in ServerConfig.logicProBundleIDs {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first {
                return app.activate()
            }
        }
        return false
    }
}
