import XCTest
@testable import LogicProMCP

final class ChannelRouterTests: XCTestCase {
    func testReportsEveryChannelError() async {
        let router = ChannelRouter()
        await router.register(FakeChannel(id: .accessibility, responses: ["track.delete": [.error("menu missing")]]))
        await router.register(FakeChannel(id: .cgEvent, responses: ["track.delete": [.error("not frontmost")]]))

        let result = await router.route(operation: "track.delete")

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.message.contains("Accessibility: menu missing"), result.message)
        XCTAssertTrue(result.message.contains("CGEvent: not frontmost"), result.message)
    }

    func testDialogBlocksStateChangesWithoutTouchingChannels() async {
        let accessibility = FakeChannel(id: .accessibility, responses: ["transport.play": [.success("{}")]])
        let router = ChannelRouter()
        await router.register(accessibility)
        await router.setDialogProbe { "Save changes? [buttons: Save, Cancel]" }

        let result = await router.route(operation: "transport.play")

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.message.hasPrefix("Blocked by Logic dialog: Save changes?"), result.message)
        let plays = await accessibility.callCount("transport.play")
        XCTAssertEqual(plays, 0)
    }

    func testReadsAndDialogOperationsPassTheGuard() async {
        let accessibility = FakeChannel(id: .accessibility, responses: [
            "transport.get_state": [.success("{}")],
            "dialog.respond": [.success("{}")],
        ])
        let router = ChannelRouter()
        await router.register(accessibility)
        await router.setDialogProbe { "Some dialog" }

        let read = await router.route(operation: "transport.get_state")
        let respond = await router.route(operation: "dialog.respond", params: ["button": "OK"])

        XCTAssertTrue(read.isSuccess, read.message)
        XCTAssertTrue(respond.isSuccess, respond.message)
    }

    func testNoDialogLetsCommandsThrough() async {
        let router = ChannelRouter()
        await router.register(FakeChannel(id: .accessibility, responses: ["transport.play": [.success("{}")]]))
        await router.setDialogProbe { nil }

        let result = await router.route(operation: "transport.play")

        XCTAssertTrue(result.isSuccess, result.message)
    }
}
