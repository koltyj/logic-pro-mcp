import MCP
import XCTest
@testable import LogicProMCP

final class MixerDispatcherTests: XCTestCase {
    func testVolumeUsesTheAdvertisedParameterContract() async {
        let channel = CapturingMixerChannel(id: .osc)
        let router = ChannelRouter()
        await router.register(channel)

        let result = await MixerDispatcher.handle(
            command: "set_volume",
            params: ["track": .int(4), "value": .double(0.75)],
            router: router,
            cache: StateCache()
        )

        XCTAssertFalse(result.isError == true)
        let call = await channel.lastCall
        XCTAssertEqual(call?.operation, "mixer.set_volume")
        XCTAssertEqual(call?.params, ["track": "4", "value": "0.75"])
    }

    func testPanUsesTheAdvertisedParameterContract() async {
        let channel = CapturingMixerChannel(id: .osc)
        let router = ChannelRouter()
        await router.register(channel)

        let result = await MixerDispatcher.handle(
            command: "set_pan",
            params: ["track": .int(2), "value": .double(-0.5)],
            router: router,
            cache: StateCache()
        )

        XCTAssertFalse(result.isError == true)
        let call = await channel.lastCall
        XCTAssertEqual(call?.operation, "mixer.set_pan")
        XCTAssertEqual(call?.params, ["track": "2", "value": "-0.5"])
    }

    func testMasterVolumeRoutesThroughAccessibilityWithValue() async {
        let channel = CapturingMixerChannel(id: .accessibility)
        let router = ChannelRouter()
        await router.register(channel)

        let result = await MixerDispatcher.handle(
            command: "set_master_volume",
            params: ["value": .double(0.6)],
            router: router,
            cache: StateCache()
        )

        XCTAssertFalse(result.isError == true)
        let call = await channel.lastCall
        XCTAssertEqual(call?.operation, "mixer.set_master_volume")
        XCTAssertEqual(call?.params, ["value": "0.6"])
    }

    func testMasterStripCandidatesPreferMasterThenStereoOut() {
        XCTAssertEqual(
            AXLogicProElements.masterStripCandidateIndices(
                descriptions: ["Audio 1", "Stereo Out", "Master"]
            ),
            [2, 1]
        )
        XCTAssertEqual(
            AXLogicProElements.masterStripCandidateIndices(descriptions: ["Audio 1", "Stereo Out"]),
            [1]
        )
        XCTAssertEqual(
            AXLogicProElements.masterStripCandidateIndices(descriptions: ["Audio 1", "Aux 1"]),
            []
        )
    }

    func testMalformedMixerValuesAreRejectedBeforeRouting() async {
        let cases: [(command: String, params: [String: Value])] = [
            ("set_volume", ["value": .double(0.5)]),
            ("set_pan", ["track": .int(1), "value": .double(2)]),
            ("set_master_volume", ["value": .string("loud")]),
        ]

        for testCase in cases {
            let osc = CapturingMixerChannel(id: .osc)
            let accessibility = CapturingMixerChannel(id: .accessibility)
            let router = ChannelRouter()
            await router.register(osc)
            await router.register(accessibility)

            let result = await MixerDispatcher.handle(
                command: testCase.command,
                params: testCase.params,
                router: router,
                cache: StateCache()
            )

            XCTAssertTrue(result.isError == true)
            let oscCall = await osc.lastCall
            let accessibilityCall = await accessibility.lastCall
            XCTAssertNil(oscCall)
            XCTAssertNil(accessibilityCall)
        }
    }
}

private actor CapturingMixerChannel: Channel {
    nonisolated let id: ChannelID
    private(set) var lastCall: (operation: String, params: [String: String])?

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        lastCall = (operation, params)
        return .success("ok")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy()
    }
}
