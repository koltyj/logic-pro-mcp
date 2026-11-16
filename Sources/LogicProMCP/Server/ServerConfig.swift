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

    // MARK: - Tempo Slider
    /// Logic Pro's tempo slider takes only relative steps, so setting a tempo
    /// means nudging it until it reads the target. How long to let one nudge
    /// land before re-reading the slider.
    static let tempoNudgeSettleDelay: TimeInterval = 0.06
    /// Upper bound on nudges for a single set_tempo. Coarse steps cover the
    /// slider's 5-990 range in about a hundred moves; this only stops a
    /// runaway loop if a future Logic Pro changes the step size.
    static let tempoNudgeStepBudget = 200
    /// Attempts per nudge. The state poller shares the Accessibility actor and
    /// its reads land between nudges, so Logic Pro intermittently answers
    /// kAXErrorCannotComplete. Giving up on the first one strands the tempo
    /// partway to the target.
    static let tempoNudgeRetries = 3

    /// Re-reads before believing the slider is against a limit. Each costs one
    /// `tempoNudgeSettleDelay`, paid only when a nudge appears to change
    /// nothing — which is either the 5/990 limit or a stale read.
    static let tempoStallConfirmations = 3

    /// Consecutive passes that move the slider nowhere before a pass gives up.
    /// Each pass resolves a fresh slider, so a single AXError -25202 is worth
    /// retrying rather than abandoning the step size for a smaller one.
    static let tempoStuckPassLimit = 3

    /// Wall-clock bound on one tempo change. Measured against Logic Pro 12.2,
    /// the full span of the slider — 20 to 990 or back — takes 6.2 to 6.7
    /// seconds, so this leaves better than double the headroom while still
    /// bounding a request that would otherwise run on the step budget alone.
    /// `axOperationTimeout` is deliberately not reused: at 2 seconds it is
    /// sized for a single AX call and would cut legitimate large moves short.
    static let tempoConvergenceDeadline: TimeInterval = 15

    // MARK: - Timeouts
    static let axOperationTimeout: TimeInterval = 2.0
    static let appleScriptTimeout: TimeInterval = 5.0
    static let channelHealthCheckTimeout: TimeInterval = 3.0

    // MARK: - Logic Pro
    static let logicProBundleIDs = ["com.apple.logic10", "com.apple.mobilelogic"]
    static let logicProBundleID = logicProBundleIDs[0]
    static let logicProProcessName = "Logic Pro"
}
