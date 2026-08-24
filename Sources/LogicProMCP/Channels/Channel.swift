import Foundation

/// Result of a channel operation.
enum ChannelResult: Sendable {
    case success(String)
    case unverified(String)
    case error(String)

    /// True when the channel accepted the operation, even if Logic cannot confirm the outcome.
    var isSuccess: Bool {
        if case .error = self { return false }
        return true
    }

    var message: String {
        switch self {
        case .success(let msg): return msg
        case .unverified(let msg): return msg
        case .error(let msg): return msg
        }
    }
}

/// Health status of a channel.
struct ChannelHealth: Sendable {
    let available: Bool
    let latencyMs: Double?
    let detail: String

    static func healthy(latencyMs: Double? = nil, detail: String = "OK") -> ChannelHealth {
        ChannelHealth(available: true, latencyMs: latencyMs, detail: detail)
    }

    static func unavailable(_ reason: String) -> ChannelHealth {
        ChannelHealth(available: false, latencyMs: nil, detail: reason)
    }
}

/// Identifies the communication channels available to the server.
enum ChannelID: String, Sendable, CaseIterable {
    case coreMIDI = "CoreMIDI"
    case accessibility = "Accessibility"
    case cgEvent = "CGEvent"
    case appleScript = "AppleScript"
    case osc = "OSC"
}

/// Protocol that all communication channels conform to.
/// Each channel wraps a native macOS control mechanism.
protocol Channel: Actor {
    /// Which channel this is.
    nonisolated var id: ChannelID { get }

    /// Initialize the channel (create MIDI ports, AX refs, etc.)
    func start() async throws

    /// Tear down the channel.
    func stop() async

    /// Execute a named operation with parameters. Returns the result.
    func execute(operation: String, params: [String: String]) async -> ChannelResult

    /// Check if this channel is currently functional.
    func healthCheck() async -> ChannelHealth
}
