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

    /// Bundle ID of the installed Logic Pro variant, whether or not it is running.
    ///
    /// Prefers the running instance, then falls back to Launch Services so the
    /// right identifier is known before Logic Pro starts. Without the second
    /// step, a machine carrying only the unified build shipped with Apple
    /// Creator Studio (`com.apple.mobilelogic`) fell back to the display name
    /// "Logic Pro", which does not exist on disk there.
    static func installedLogicProBundleID() -> String? {
        if let running = logicProApp()?.bundleIdentifier { return running }
        for bundleID in ServerConfig.logicProBundleIDs
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return bundleID
        }
        return nil
    }

    /// AppleScript target for the detected Logic Pro variant.
    static var logicProAppleScriptTarget: String {
        guard let bundleID = installedLogicProBundleID() else {
            return "application \"\(ServerConfig.logicProProcessName)\""
        }
        return "application id \"\(bundleID)\""
    }

    /// Launch Logic Pro and wait for it to register as running.
    ///
    /// Goes through Launch Services rather than AppleScript `activate`:
    /// dispatching an Apple Event is precisely what needs the Automation grant
    /// this is used to obtain, so scripting the launch is circular.
    ///
    /// - Returns: `true` once Logic Pro is running, `false` on timeout or if no
    ///   supported variant is installed.
    @discardableResult
    static func launchLogicPro(timeout: TimeInterval = 60) -> Bool {
        if isLogicProRunning { return true }
        guard
            let bundleID = installedLogicProBundleID(),
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isLogicProRunning { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return isLogicProRunning
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
