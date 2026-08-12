import Foundation
import Network

/// Sends OSC messages to Logic Pro over UDP using Network.framework.
actor OSCClient {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var connection: NWConnection?
    private var isReady = false
    private var connectionGeneration = 0

    init(host: String = ServerConfig.oscHost, port: UInt16 = ServerConfig.oscSendPort) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    /// Establish the UDP connection.
    func start() async throws {
        if connection != nil {
            guard isReady else { throw OSCClientError.connectionFailed }
            return
        }

        let params = NWParameters.udp
        let conn = NWConnection(host: host, port: port, using: params)
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connection = conn

        let readyResult: Bool = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            conn.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleConnectionState(state, connection: conn, generation: generation, once: once, continuation: continuation) }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        if readyResult, connection === conn, isReady {
            Log.info("OSCClient connected to \(host):\(port)", subsystem: "osc")
        } else {
            conn.cancel()
            if connection === conn {
                connection = nil
                isReady = false
            }
            throw OSCClientError.connectionFailed
        }
    }

    /// Cancel the UDP connection.
    func stop() {
        connectionGeneration &+= 1
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

    private func handleConnectionState(
        _ state: NWConnection.State,
        connection conn: NWConnection,
        generation: Int,
        once: OnceFlag,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        guard generation == connectionGeneration, connection === conn else {
            // stop() can cancel a connection while start() is suspended. Resume that
            // pending start, but never let its terminal callback alter a newer one.
            if case .failed = state, once.tryConsume() {
                continuation.resume(returning: false)
            } else if case .cancelled = state, once.tryConsume() {
                continuation.resume(returning: false)
            }
            return
        }

        switch state {
        case .ready:
            isReady = true
            if once.tryConsume() { continuation.resume(returning: true) }
        case .failed(let error):
            isReady = false
            connection = nil
            Log.error("OSCClient connection failed: \(error)", subsystem: "osc")
            if once.tryConsume() { continuation.resume(returning: false) }
        case .cancelled:
            isReady = false
            connection = nil
            Log.info("OSCClient connection cancelled", subsystem: "osc")
            if once.tryConsume() { continuation.resume(returning: false) }
        default:
            break
        }
    }
}

enum OSCClientError: Error, Sendable {
    case connectionFailed
    case notConnected
}
