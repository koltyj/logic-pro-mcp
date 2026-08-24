import CoreGraphics
import Foundation

/// Channel that sends keyboard shortcuts to Logic Pro via CGEvent.
/// Uses CGEvent.postToPid() to deliver keystrokes to the Logic Pro process.
/// This is the primary channel for transport control and editing operations.
///
/// Logic Pro discards posted key events unless it is the frontmost application,
/// so every send activates it first. Note that postToPid() returns no delivery
/// receipt, so a successful result means "posted", not "acted upon".
actor CGEventChannel: Channel {
    let id: ChannelID = .cgEvent

    /// A keyboard shortcut definition.
    private struct Shortcut: Sendable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags

        static func key(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [])
        }

        static func cmd(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskCommand)
        }

        static func cmdShift(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [.maskCommand, .maskShift])
        }

        static func option(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskAlternate)
        }

        static func cmdOption(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [.maskCommand, .maskAlternate])
        }
    }

    /// Mapping from operation strings to keyboard shortcuts.
    /// Key codes: https://developer.apple.com/documentation/coregraphics/cgkeycode
    private static let keyMap: [String: Shortcut] = [
        // Transport
        "transport.play":             .key(49),         // Space
        "transport.stop":             .key(49),         // Space (toggles)
        "transport.record":           .key(15),         // R
        "transport.pause":            .key(49),         // Space
        "transport.rewind":           .key(123),        // Left arrow
        "transport.fast_forward":     .key(124),        // Right arrow
        "transport.toggle_cycle":     .key(8),          // C
        "transport.toggle_metronome": .key(40),         // K
        "transport.goto_position":    .key(44),         // / (opens Go To Position)

        // Editing
        "edit.undo":                  .cmd(6),          // Cmd+Z
        "edit.redo":                  .cmdShift(6),     // Cmd+Shift+Z
        "edit.cut":                   .cmd(7),          // Cmd+X
        "edit.copy":                  .cmd(8),          // Cmd+C
        "edit.paste":                 .cmd(9),          // Cmd+V
        "edit.delete":                .key(51),         // Delete
        "edit.select_all":            .cmd(0),          // Cmd+A
        "edit.split":                 .cmd(17),         // Cmd+T

        // Views
        "view.toggle_mixer":          .key(7),          // X
        "view.toggle_piano_roll":     .key(35),         // P
        "view.toggle_library":        .key(16),         // Y
        "view.toggle_inspector":      .key(34),         // I
        "view.toggle_score_editor":   .cmdOption(35),   // Cmd+Option+P (approximate)
        "view.toggle_step_editor":    .cmdOption(34),   // Cmd+Option+I (approximate)

        // Project
        "project.save":               .cmd(1),          // Cmd+S
        "project.save_as":            .cmdShift(1),     // Cmd+Shift+S
        "project.close":              .cmd(13),         // Cmd+W

        // Track creation
        "track.create_audio":         .cmdOption(0),    // Option+Cmd+A (approximate)
        "track.create_instrument":    .cmdOption(1),    // Option+Cmd+S (approximate)
        "track.create_drummer":       .cmdOption(6),    // (approximate)
        "track.duplicate":            .cmd(2),          // Cmd+D
        "track.delete":               .cmd(51),         // Cmd+Delete

        // Navigation
        "nav.create_marker":          .cmdOption(39),   // (approximate)
        "nav.zoom_to_fit":            .key(6),          // Z
        "edit.join":                  .cmd(38),         // Cmd+J
        "edit.quantize":              .key(44),         // Q (approximate)
        "edit.bounce_in_place":       .cmdOption(11),   // (approximate)

        // Automation
        "automation.toggle_view":     .key(0),          // A
    ]

    func start() async throws {
        guard ProcessUtils.isLogicProRunning else {
            Log.warn("Logic Pro not running at CGEvent channel start", subsystem: "cgEvent")
            return
        }
        Log.info("CGEvent channel started", subsystem: "cgEvent")
    }

    func stop() async {
        Log.info("CGEvent channel stopped", subsystem: "cgEvent")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard let pid = ProcessUtils.logicProPID() else {
            return .error("Logic Pro is not running")
        }

        if operation == "transport.goto_position" {
            guard let position = params["position"] else {
                return .error("Missing 'position' parameter")
            }
            // Activate only once the request is known to be actionable, so an
            // invalid call does not steal the user's active application.
            guard await ensureFrontmost() else {
                return .error("Could not bring Logic Pro to the front; it would discard the keystroke")
            }
            guard postKeyEvent(keyCode: 44, flags: [], pid: pid) else {
                return .error("Failed to open Go To Position")
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return .error("Cancelled before entering the Go To Position value")
            }
            // Focus can move during the 100ms wait, and Logic Pro would then
            // discard the remaining events while postKeyEvent still reported
            // success. Re-check rather than assume the earlier activation held.
            guard await ensureFrontmost() else {
                return .error("Could not bring Logic Pro to the front; it would discard the keystroke")
            }
            guard postText(position, pid: pid), postKeyEvent(keyCode: 36, flags: [], pid: pid) else {
                return .error("Failed to enter Go To Position value")
            }
            return .success("{\"position\":\"\(position)\"}")
        }

        guard let shortcut = Self.keyMap[operation] else {
            return .error("No keyboard shortcut mapped for: \(operation)")
        }

        guard await ensureFrontmost() else {
            return .error("Could not bring Logic Pro to the front; it would discard the keystroke")
        }

        let sent = postKeyEvent(keyCode: shortcut.keyCode, flags: shortcut.flags, pid: pid)
        if sent {
            return .success("{\"operation\":\"\(operation)\",\"sent\":true}")
        } else {
            return .error("Failed to post CGEvent for \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        guard ProcessUtils.logicProPID() != nil else {
            return .unavailable("Cannot determine Logic Pro PID")
        }
        return .healthy(detail: "CGEvent ready")
    }

    // MARK: - Event Posting

    /// Bring Logic Pro to the front and wait for the activation to land.
    /// Logic Pro ignores events posted via postToPid() while another app is
    /// active, so this is a precondition for delivery, not an optimisation.
    private func ensureFrontmost() async -> Bool {
        // CallTool handlers run in cancellable tasks. Never report success once
        // cancelled, or execute() would go on to post a keystroke the client no
        // longer wants.
        if Task.isCancelled { return false }
        if ProcessUtils.isLogicProFrontmost { return true }
        guard ProcessUtils.activateLogicPro() else {
            Log.error("activateLogicPro() failed", subsystem: "cgEvent")
            return false
        }
        // Activation is asynchronous; poll briefly rather than sleeping blind.
        for _ in 0..<20 {
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                // Cancelled mid-wait. `try?` here would swallow that and let a
                // stale keystroke through.
                Log.debug("Cancelled while waiting for Logic Pro to activate", subsystem: "cgEvent")
                return false
            }
            if ProcessUtils.isLogicProFrontmost { return true }
        }
        Log.warn("Logic Pro did not become frontmost within 500ms", subsystem: "cgEvent")
        return false
    }

    /// Post a key-down/key-up pair to a specific PID.
    private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.error("Failed to create CGEventSource", subsystem: "cgEvent")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.error("Failed to create CGEvent for keyCode \(keyCode)", subsystem: "cgEvent")
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.postToPid(pid)
        keyUp.postToPid(pid)

        Log.debug("Posted key \(keyCode) flags \(flags.rawValue) to PID \(pid)", subsystem: "cgEvent")
        return true
    }

    private func postText(_ text: String, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        let characters = Array(text.utf16)
        characters.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }
}
