import Foundation

/// Parameter keys shared between dispatchers and channels.
///
/// `ChannelRouter.route` forwards a dispatcher's params to each channel in the
/// fallback chain verbatim, so a dispatcher and a channel that spell the same
/// key differently do not fail loudly — the mismatched channel just reports a
/// missing parameter, which the router treats as "this channel could not do
/// it" and moves on. That is how set_tempo shipped with a dead Accessibility
/// fallback: the dispatcher sent "bpm", the channel read "tempo".
///
/// Keys that cross that boundary belong here, spelled once.
enum ChannelParam {
    /// Tempo in beats per minute.
    static let tempo = "bpm"

    /// The tempo a dispatcher asked for, or nil if it is absent or unusable.
    ///
    /// Every channel that handles `transport.set_tempo` reads the value through
    /// here, so the key cannot drift apart again.
    ///
    /// `Channel.execute` is reachable without going through a dispatcher, so a
    /// channel cannot assume `TransportDispatcher`'s range check ran. Non-finite
    /// values are rejected here rather than deeper in: "inf" parses as a Double,
    /// and downstream it never converges, never compares equal to anything, and
    /// traps on conversion to Int.
    static func parseTempo(_ params: [String: String]) -> Double? {
        // "tempo" was the key AccessibilityChannel used to read. Kept so a
        // caller written against the old spelling still works.
        guard let raw = params[tempo] ?? params["tempo"] else { return nil }
        guard let value = Double(raw), value.isFinite else { return nil }
        return value
    }
}
