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
}
