import XCTest
@testable import LogicProMCP
import MCP

/// set_tempo crosses three files that each had their own idea of the parameter
/// name: the dispatcher wrote "bpm", OSCChannel read "bpm", AccessibilityChannel
/// read "tempo". Because ChannelRouter treats a channel's "missing parameter"
/// as "try the next channel", the broken fallback was silent — the OSC send
/// reported success and nothing ever reached Logic Pro.
///
/// These tests pin the contract rather than the UI, so they run without Logic
/// Pro installed and without Accessibility permission.
final class SetTempoContractTests: XCTestCase {

    /// The key the dispatcher sends must be the key both channels read.
    func testChannelsReadTheKeyTheDispatcherSends() {
        let dispatched = [ChannelParam.tempo: "140"]

        XCTAssertEqual(
            AccessibilityChannel.parseTempo(dispatched), 140,
            "AccessibilityChannel must accept the dispatcher's tempo key"
        )
        XCTAssertEqual(
            OSCChannel.parseTempo(dispatched), 140,
            "OSCChannel must accept the dispatcher's tempo key"
        )
    }

    func testTempoParsingAcceptsTheLegacyKey() {
        XCTAssertEqual(AccessibilityChannel.parseTempo(["tempo": "90"]), 90)
        XCTAssertEqual(OSCChannel.parseTempo(["tempo": "90"]), 90)
    }

    func testTempoParsingRejectsMissingAndNonNumericValues() {
        XCTAssertNil(AccessibilityChannel.parseTempo([:]))
        XCTAssertNil(AccessibilityChannel.parseTempo([ChannelParam.tempo: "presto"]))
        XCTAssertNil(OSCChannel.parseTempo([:]))
        XCTAssertNil(OSCChannel.parseTempo([ChannelParam.tempo: "presto"]))
    }

    /// `Channel.execute` is reachable without TransportDispatcher's range
    /// check, so "inf" arrives as a parseable Double. It never converges, so
    /// the nudge loop would spend its whole step budget and then trap
    /// formatting the target into the error message.
    func testTempoParsingRejectsNonFiniteValues() {
        for raw in ["inf", "-inf", "infinity", "nan", "1e400"] {
            XCTAssertNil(
                AccessibilityChannel.parseTempo([ChannelParam.tempo: raw]),
                "AccessibilityChannel accepted \(raw)"
            )
            XCTAssertNil(
                OSCChannel.parseTempo([ChannelParam.tempo: raw]),
                "OSCChannel accepted \(raw)"
            )
        }
    }

    /// A finite Double can still be far outside Float's range, and a plain
    /// conversion turns it into the infinity the parser just rejected.
    func testOSCTempoParsingRejectsValuesFloatCannotHold() {
        XCTAssertNil(OSCChannel.parseTempo([ChannelParam.tempo: "1e300"]))
    }

    /// The Accessibility channel is the only one that can read the tempo back,
    /// and ChannelRouter returns on the first non-error result — so an
    /// unverifiable channel listed ahead of it would stop it from ever running.
    func testAccessibilityIsTriedBeforeOSCForSetTempo() {
        let chain = ChannelRouter.channelChain(for: "transport.set_tempo")
        XCTAssertEqual(chain.first, .accessibility, "chain was \(chain)")
        XCTAssertTrue(chain.contains(.osc), "OSC should remain as a fallback")
    }

    /// Measured against Logic Pro 12.2: walking the slider the full 20-990 span
    /// takes 6.2 to 6.7 seconds. A deadline at or under that would abort moves
    /// that were about to succeed and report them as failures, so pin the floor.
    func testTempoDeadlineClearsTheMeasuredWorstCase() {
        XCTAssertGreaterThan(ServerConfig.tempoConvergenceDeadline, 7)
    }

    /// The deadline exists to bound a stuck request. Reusing the single-call
    /// AX timeout (2s) here was the tempting wrong answer; this fails if
    /// someone collapses the two.
    func testTempoDeadlineIsNotTheSingleCallTimeout() {
        XCTAssertNotEqual(
            ServerConfig.tempoConvergenceDeadline,
            ServerConfig.axOperationTimeout
        )
    }

    /// A conclusive failure is not a success. The dispatchers turn `isSuccess`
    /// straight into the MCP `isError` flag, so getting this wrong tells the
    /// caller the tempo changed when the channel reported that it did not.
    func testTerminalResultIsNotASuccess() {
        XCTAssertFalse(ChannelResult.terminal("busy").isSuccess)
        XCTAssertEqual(ChannelResult.terminal("busy").message, "busy")
    }

    /// The router must stop on a conclusive answer instead of falling through.
    ///
    /// Observed live before this was added: the Accessibility channel refused
    /// an overlapping set_tempo, the router read that as "channel failed" and
    /// tried OSC, and OSC — which cannot read the tempo back — answered "Set
    /// tempo to 300.0 BPM (sent via OSC)" while the slider sat at 200. The
    /// same laundering happened when the convergence loop ran out of budget.
    func testRouterStopsOnATerminalResultInsteadOfFallingThroughToOSC() async {
        let router = ChannelRouter()
        await router.register(StubChannel(id: .accessibility, result: .terminal("busy")))
        await router.register(StubChannel(id: .osc, result: .unverified("sent via OSC")))

        let result = await router.route(operation: "transport.set_tempo", params: [:])

        XCTAssertFalse(result.isSuccess, "a refusal must not read as success")
        XCTAssertEqual(result.message, "busy", "the OSC answer leaked through")
    }

    /// The counterpart: a plain failure still falls through, so the terminal
    /// case above is doing something a `.error` would not have done. A channel
    /// that could not even try — no Accessibility permission, no slider — has
    /// no information to protect, and the fallback is worth having.
    func testRouterStillFallsThroughOnAPlainError() async {
        let router = ChannelRouter()
        await router.register(StubChannel(id: .accessibility, result: .error("no slider")))
        await router.register(StubChannel(id: .osc, result: .unverified("sent via OSC")))

        let result = await router.route(operation: "transport.set_tempo", params: [:])

        XCTAssertEqual(result.message, "sent via OSC")
    }
}

/// Answers one canned result, so a routing test needs neither Logic Pro nor
/// Accessibility permission.
private actor StubChannel: Channel {
    nonisolated let id: ChannelID
    private let result: ChannelResult
    private(set) var calls = 0

    init(id: ChannelID, result: ChannelResult) {
        self.id = id
        self.result = result
    }

    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy() }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        calls += 1
        return result
    }
}

/// A set_tempo that arrives without a tempo must not touch the project.
///
/// It used to default to 120. Observed from the user's side as the project
/// tempo "going to 120 a lot": a caller that put `tempo` next to `command`
/// rather than inside `params` got a successful reset to 120 every time.
final class SetTempoMissingTempoTests: XCTestCase {
    private func dispatch(_ params: [String: Value]) async -> (CallTool.Result, Int) {
        let router = ChannelRouter()
        let channel = StubChannel(id: .accessibility, result: .success("{\"tempo\":120}"))
        await router.register(channel)
        let result = await TransportDispatcher.handle(
            command: "set_tempo", params: params, router: router, cache: StateCache()
        )
        return (result, await channel.calls)
    }

    func testMissingTempoIsAnErrorAndReachesNoChannel() async {
        let (result, calls) = await dispatch([:])
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(calls, 0, "a request without a tempo still reached a channel")
    }

    /// The error has to say where the tempo goes, or a caller that made the
    /// mistake once will make it again on the retry.
    func testMissingTempoMessageShowsTheParamsShape() {
        XCTAssertTrue(TransportDispatcher.missingTempoMessage.contains(#""params": {"tempo""#))
    }

    func testTempoInsideParamsStillReachesTheChannel() async {
        let (result, calls) = await dispatch(["tempo": .double(128)])
        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(calls, 1)
    }
}
