import Foundation
@testable import LogicProMCP

/// Scriptable channel: returns queued responses per operation; the last response repeats.
actor FakeChannel: Channel {
    nonisolated let id: ChannelID
    private var responses: [String: [ChannelResult]]
    private var recorded: [String] = []

    init(id: ChannelID, responses: [String: [ChannelResult]] = [:]) {
        self.id = id
        self.responses = responses
    }

    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy() }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        recorded.append(operation)
        guard var queue = responses[operation], let first = queue.first else {
            return .error("FakeChannel has no response for \(operation)")
        }
        if queue.count > 1 { queue.removeFirst() }
        responses[operation] = queue
        return first
    }

    func callCount(_ operation: String) -> Int {
        recorded.filter { $0 == operation }.count
    }
}
