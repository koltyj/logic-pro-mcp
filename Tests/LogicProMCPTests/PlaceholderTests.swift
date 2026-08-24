import XCTest
@testable import LogicProMCP

final class PlaceholderTests: XCTestCase {
    func testAutomationPermissionStatus() {
        let granted = PermissionChecker.PermissionStatus(
            accessibility: true,
            automation: .granted
        )
        XCTAssertTrue(granted.automationLogicPro)
        XCTAssertTrue(granted.allGranted)

        let denied = PermissionChecker.PermissionStatus(
            accessibility: true,
            automation: .denied
        )
        XCTAssertFalse(denied.automationLogicPro)
        XCTAssertFalse(denied.allGranted)
        XCTAssertTrue(denied.summary.contains("Automation (Logic Pro): NOT GRANTED (denied)"))
    }

    func testUnverifiedDeliveryIsAcceptedWithoutClaimingVerification() {
        let result = ChannelResult.unverified("sent, not verified")
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.message, "sent, not verified")
    }
}
