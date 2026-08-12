import os
import XCTest
@testable import LogicProMCP

final class OnceFlagTests: XCTestCase {
    func testConsumesOnlyOnceAcrossConcurrentCalls() {
        let flag = OnceFlag()
        let consumedCount = OSAllocatedUnfairLock(initialState: 0)

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if flag.tryConsume() {
                consumedCount.withLock { $0 += 1 }
            }
        }

        XCTAssertEqual(consumedCount.withLock { $0 }, 1)
    }
}
