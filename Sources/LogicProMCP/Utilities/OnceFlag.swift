import os

/// Thread-safe one-shot flag for guarding continuation resumption.
final class OnceFlag: Sendable {
    private let consumed = OSAllocatedUnfairLock(initialState: false)

    func tryConsume() -> Bool {
        consumed.withLock {
            guard !$0 else { return false }
            $0 = true
            return true
        }
    }
}
