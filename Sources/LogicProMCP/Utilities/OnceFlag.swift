import Foundation
import os

/// Thread-safe one-shot flag for guarding CheckedContinuation resumption.
/// `tryConsume()` returns `true` exactly once, regardless of how many
/// threads call it concurrently.
final class OnceFlag: Sendable {
    private let _consumed = OSAllocatedUnfairLock(initialState: false)

    func tryConsume() -> Bool {
        _consumed.withLock { consumed in
            if consumed { return false }
            consumed = true
            return true
        }
    }
}
