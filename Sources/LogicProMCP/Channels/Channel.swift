import Foundation

/// Result of a channel operation.
enum ChannelResult: Sendable {
    case success(String)
    case unverified(String)
    case error(String)

    /// The channel's answer is final: the router must not try another channel.
    ///
    /// Two situations produce it, and they share the property that matters —
    /// the channel knows the state of the thing it was asked to change, so a
    /// weaker channel can only obscure that:
    ///
    /// - A deliberate refusal, e.g. `set_tempo` declining a second request
    ///   while the first is still converging.
    /// - A measured failure: the tempo slider was nudged and read back, and it
    ///   did not reach the target.
    ///
    /// Both were observed live going out as `.error`, which the router reads as
    /// "this channel could not try" and answers by falling through to OSC. OSC
    /// cannot read the tempo back, so it replied "Set tempo to 300.0 BPM (sent
    /// via OSC)" for a slider that never moved off 200. Routing around a known
    /// answer is how a false success gets made.
    case terminal(String)

    /// True when the channel accepted the operation, even if Logic cannot confirm the outcome.
    var isSuccess: Bool {
        switch self {
        case .success, .unverified: return true
        case .error, .terminal: return false
        }
    }

    var message: String {
        switch self {
        case .success(let msg): return msg
        case .unverified(let msg): return msg
        case .error(let msg): return msg
        case .terminal(let msg): return msg
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
