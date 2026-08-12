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
    static let logicProBundleIDs = ["com.apple.logic10", "com.apple.mobilelogic"]
    static let logicProBundleID = logicProBundleIDs[0]
    static let logicProProcessName = "Logic Pro"
}
