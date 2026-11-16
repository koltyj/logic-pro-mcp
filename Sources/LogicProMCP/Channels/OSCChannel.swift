import Foundation

/// Channel that routes operations to Logic Pro via OSC over UDP.
actor OSCChannel: Channel {
    let id: ChannelID = .osc
    private let client: OSCClient
    private let server: OSCServer

    init(client: OSCClient, server: OSCServer) {
        self.client = client
        self.server = server
    }

    func start() async throws {
        try await client.start()
        try await server.start()
        Log.info("OSCChannel started", subsystem: "osc")
    }

    func stop() async {
        await client.stop()
        await server.stop()
        Log.info("OSCChannel stopped", subsystem: "osc")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        switch operation {
        // MARK: - Mixer

        case "mixer.set_volume":
            guard let track = params["track"].flatMap(Int.init),
                  let volume = params["value"].flatMap(Float.init) else {
                return .error("set_volume requires 'track' (int) and 'value' (float 0.0-1.0)")
            }
            let msg = OSCMessage(address: "/track/\(track)/volume", arguments: [.float(volume)])
            return await send(msg, description: "Set track \(track) volume to \(volume)")

        case "mixer.set_pan":
            guard let track = params["track"].flatMap(Int.init),
                  let pan = params["value"].flatMap(Float.init) else {
                return .error("set_pan requires 'track' (int) and 'value' (float -1.0 to 1.0)")
            }
            let msg = OSCMessage(address: "/track/\(track)/pan", arguments: [.float(pan)])
            return await send(msg, description: "Set track \(track) pan to \(pan)")

        case "mixer.set_mute":
            guard let track = params["track"].flatMap(Int.init) else {
                return .error("set_mute requires 'track' (int)")
            }
            let muted = params["muted"] == "true" || params["muted"] == "1"
            let msg = OSCMessage(address: "/track/\(track)/mute", arguments: [.int(muted ? 1 : 0)])
            return await send(msg, description: "Set track \(track) mute=\(muted)")

        case "mixer.set_solo":
            guard let track = params["track"].flatMap(Int.init) else {
                return .error("set_solo requires 'track' (int)")
            }
            let soloed = params["soloed"] == "true" || params["soloed"] == "1"
            let msg = OSCMessage(address: "/track/\(track)/solo", arguments: [.int(soloed ? 1 : 0)])
            return await send(msg, description: "Set track \(track) solo=\(soloed)")

        case "mixer.set_send":
            guard let track = params["track"].flatMap(Int.init),
                  let sendIndex = params["send"].flatMap(Int.init),
                  let level = params["level"].flatMap(Float.init) else {
                return .error("set_send requires 'track' (int), 'send' (int), 'level' (float)")
            }
            let msg = OSCMessage(address: "/track/\(track)/send/\(sendIndex)/level", arguments: [.float(level)])
            return await send(msg, description: "Set track \(track) send \(sendIndex) level to \(level)")

        // MARK: - Transport

        case "transport.set_tempo":
            guard let tempo = Self.parseTempo(params) else {
                return .error("set_tempo requires '\(ChannelParam.tempo)' (float)")
            }
            let msg = OSCMessage(address: "/tempo", arguments: [.float(tempo)])
            return await send(msg, description: "Set tempo to \(tempo) BPM")

        case "transport.play":
            let msg = OSCMessage(address: "/play", arguments: [.int(1)])
            return await send(msg, description: "OSC play")

        case "transport.stop":
            let msg = OSCMessage(address: "/stop", arguments: [.int(1)])
            return await send(msg, description: "OSC stop")

        case "transport.record":
            let msg = OSCMessage(address: "/record", arguments: [.int(1)])
            return await send(msg, description: "OSC record")

        // MARK: - Track Selection

        case "track.select":
            guard let track = params["track"].flatMap(Int.init) else {
                return .error("track.select requires 'track' (int)")
            }
            let msg = OSCMessage(address: "/track/\(track)/select", arguments: [.int(1)])
            return await send(msg, description: "Select track \(track)")

        // MARK: - Raw OSC

        case "osc.send":
            guard let address = params["address"] else {
                return .error("osc.send requires 'address' (OSC path)")
            }
            var arguments: [OSCArgument] = []
            // Support a single typed argument for flexibility.
            if let intVal = params["int"].flatMap(Int32.init) {
                arguments.append(.int(intVal))
            }
            if let floatVal = params["float"].flatMap(Float.init) {
                arguments.append(.float(floatVal))
            }
            if let stringVal = params["string"] {
                arguments.append(.string(stringVal))
            }
            let msg = OSCMessage(address: address, arguments: arguments)
            return await send(msg, description: "OSC \(address)")

        default:
            return .error("Unknown OSC operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        let connected = await client.isConnected
        let listening = await server.isListening
        if connected && listening {
            return .healthy(detail: "OSC client connected, server listening")
        } else if connected {
            return .healthy(detail: "OSC client connected (server not listening)")
        } else {
            return .unavailable("OSC client not connected")
        }
    }

    // MARK: - Private

    /// The tempo for an OSC `/tempo` message, or nil if the request has none.
    ///
    /// Reads the key through `ChannelParam` so this channel and the
    /// Accessibility channel cannot drift apart again. Not private: the
    /// contract test calls this, so a revert to `params["tempo"]` here fails
    /// the test instead of silently disabling the fallback.
    static func parseTempo(_ params: [String: String]) -> Float? {
        guard let value = ChannelParam.parseTempo(params) else { return nil }
        let tempo = Float(value)
        // Double values beyond Float's range become infinity, which OSC would
        // happily encode and send.
        guard tempo.isFinite else { return nil }
        return tempo
    }

    /// Send one OSC message.
    ///
    /// OSC here is UDP, and Logic Pro only listens at all once the user has
    /// added a Logic Control surface pointing at this port. A datagram sent
    /// into a port nobody is bound to still "succeeds" — the send call cannot
    /// tell the two cases apart — so this reports .unverified, the same way
    /// CGEventChannel and CoreMIDIChannel already report their own writes.
    /// Reporting .success here is what let set_tempo answer "Set tempo to
    /// 140.0 BPM" while Logic Pro stayed at 120.
    private func send(_ message: OSCMessage, description: String) async -> ChannelResult {
        do {
            try await client.send(message: message)
            return .unverified("\(description) (sent via OSC; Logic delivery is not verified)")
        } catch {
            Log.error("OSC send failed: \(error)", subsystem: "osc")
            return .error("OSC send failed: \(error.localizedDescription)")
        }
    }
}
