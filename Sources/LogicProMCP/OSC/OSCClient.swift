import Foundation
import Network

/// Sends OSC messages to Logic Pro over UDP using Network.framework.
actor OSCClient {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var connection: NWConnection?
    private var isReady = false

    init(host: String = ServerConfig.oscHost, port: UInt16 = ServerConfig.oscSendPort) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    /// Establish the UDP connection.
    func start() async throws {
        guard connection == nil else { return }

        let params = NWParameters.udp
        let conn = NWConnection(host: host, port: port, using: params)

        let readyResult: Bool = await withCheckedContinuation { continuation in
            // NWConnection state handler can fire multiple times (e.g. .ready then .cancelled
            // on shutdown). A CheckedContinuation must only be resumed once.
            let guard_ = OnceFlag()
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { await self?.setReady(true) }
                    if guard_.tryConsume() { continuation.resume(returning: true) }
                case .failed(let error):
                    Task { await self?.setReady(false) }
                    Log.error("OSCClient connection failed: \(error)", subsystem: "osc")
                    if guard_.tryConsume() { continuation.resume(returning: false) }
                case .cancelled:
                    Task { await self?.setReady(false) }
                    Log.info("OSCClient connection cancelled", subsystem: "osc")
                    if guard_.tryConsume() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        if readyResult {
            self.connection = conn
            // Set readiness synchronously: the Task dispatched by the state
            // handler races with this method returning, and a caller's
            // immediate send() must not see isReady == false.
            self.isReady = true
            Log.info("OSCClient connected to \(host):\(port)", subsystem: "osc")
        } else {
            conn.cancel()
            throw OSCClientError.connectionFailed
        }
    }

    /// Cancel the UDP connection.
    func stop() {
        connection?.cancel()
        connection = nil
        isReady = false
        Log.info("OSCClient stopped", subsystem: "osc")
    }

    /// Send an OSC message.
    func send(message: OSCMessage) async throws {
        guard let connection, isReady else {
            throw OSCClientError.notConnected
        }

        let data = message.encode()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        Log.debug("OSC sent: \(message.address) (\(data.count) bytes)", subsystem: "osc")
    }

    var isConnected: Bool { isReady && connection != nil }

    private func setReady(_ value: Bool) {
        isReady = value
    }
}

enum OSCClientError: Error, Sendable {
    case connectionFailed
    case notConnected
}
