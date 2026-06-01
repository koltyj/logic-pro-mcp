import Foundation

/// Central configuration for the Logic Pro MCP server.
/// All tunables live here — ports, timeouts, poll intervals.
struct ServerConfig: Sendable {
    // MARK: - Server Identity
    static let serverName = "logic-pro-mcp"
    static let serverVersion = "0.1.0"

    // MARK: - OSC
    static let oscSendPort: UInt16 = 7001    // Server → Logic Pro
    static let oscReceivePort: UInt16 = 7000 // Logic Pro → Server
    static let oscHost = "127.0.0.1"

    // MARK: - MIDI
    static let virtualMIDISourceName = "LogicProMCP-Out"
    static let virtualMIDISinkName = "LogicProMCP-In"
    /// MMC device ID (0x7F = all devices)
    static let mmcDeviceID: UInt8 = 0x7F

    // MARK: - State Polling (Accessibility)
    /// Transport poll interval when actively in use (<5s since last tool call)
    static let activeTransportPollInterval: TimeInterval = 0.5
    /// Track/mixer poll interval when actively in use
    static let activeTrackPollInterval: TimeInterval = 2.0
    /// Poll interval when lightly active (5-30s idle)
    static let lightPollInterval: TimeInterval = 2.0
    /// Poll interval when idle (>30s)
    static let idlePollInterval: TimeInterval = 5.0
    /// Seconds of inactivity before switching to light polling
    static let lightIdleThreshold: TimeInterval = 5.0
    /// Seconds of inactivity before switching to idle polling
    static let idleThreshold: TimeInterval = 30.0

    // MARK: - Verify-After-Write
    /// Delay after a mutation before re-reading state via AX
    static let verifyAfterWriteDelay: TimeInterval = 0.15

    // MARK: - Timeouts
    static let axOperationTimeout: TimeInterval = 2.0
    static let appleScriptTimeout: TimeInterval = 5.0
    static let channelHealthCheckTimeout: TimeInterval = 3.0

    // MARK: - Logic Pro
    /// Primary bundle ID (desktop Logic Pro). Kept for backwards compatibility.
    static let logicProBundleID = "com.apple.logic10"
    static let logicProProcessName = "Logic Pro"
    /// All recognised Logic Pro bundle identifiers. Includes desktop Logic Pro
    /// and the Mac-Catalyst port of Logic Pro for iPad ("Logic Pro Creator Studio").
    static let logicProBundleIDs: [String] = [
        "com.apple.logic10",     // Desktop Logic Pro (10.x / 11.x)
        "com.apple.mobilelogic", // Logic Pro for iPad on Mac (Creator Studio)
    ]
    /// Display names a Logic variant may report. Used for process name matching.
    static let logicProProcessNames: [String] = [
        "Logic Pro",
        "Logic Pro Creator Studio",
    ]
}
