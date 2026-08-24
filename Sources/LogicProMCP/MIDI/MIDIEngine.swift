import CoreMIDI
import Foundation

/// Actor wrapping CoreMIDI. Creates a virtual source (for sending MIDI to Logic Pro)
/// and a virtual destination (for receiving MIDI from Logic Pro).
actor MIDIEngine {
    private var client: MIDIClientRef = 0
    private var virtualSource: MIDIEndpointRef = 0
    private var virtualDestination: MIDIEndpointRef = 0
    private var additionalVirtualSources: [MIDIEndpointRef] = []
    private var additionalVirtualDestinations: [MIDIEndpointRef] = []
    private var additionalVirtualPortNames: Set<String> = []
    private var isRunning = false

    /// Stream of inbound MIDI packets from Logic Pro via the virtual destination.
    let inboundMessages: AsyncStream<MIDIFeedback.Event>
    private let inboundContinuation: AsyncStream<MIDIFeedback.Event>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<MIDIFeedback.Event>.makeStream()
        self.inboundMessages = stream
        self.inboundContinuation = continuation
    }

    deinit {
        inboundContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Create the CoreMIDI client, virtual source, and virtual destination.
    func start() throws {
        guard !isRunning else { return }

        var status = noErr

        // Create client.
        let clientName = ServerConfig.virtualMIDISourceName as CFString
        status = MIDIClientCreateWithBlock(clientName, &client) { [weak self] notification in
            self?.handleMIDINotification(notification)
        }
        guard status == noErr else {
            throw MIDIEngineError.clientCreationFailed(status)
        }

        // Virtual source — data we send appears here for Logic to receive.
        let sourceName = ServerConfig.virtualMIDISourceName as CFString
        status = MIDISourceCreate(client, sourceName, &virtualSource)
        guard status == noErr else {
            throw MIDIEngineError.sourceCreationFailed(status)
        }

        // Virtual destination — Logic sends data here for us to receive.
        let sinkName = ServerConfig.virtualMIDISinkName as CFString
        let continuation = self.inboundContinuation
        status = MIDIDestinationCreateWithBlock(client, sinkName, &virtualDestination) { packetList, _ in
            let packets = packetList.pointee
            MIDIFeedback.parse(packetList: packets, into: continuation)
        }
        guard status == noErr else {
            throw MIDIEngineError.destinationCreationFailed(status)
        }

        isRunning = true
        Log.info("MIDIEngine started — source: \(ServerConfig.virtualMIDISourceName), sink: \(ServerConfig.virtualMIDISinkName)", subsystem: "midi")
    }

    /// Tear down all CoreMIDI resources.
    func stop() {
        guard isRunning else { return }
        for source in additionalVirtualSources where source != 0 {
            MIDIEndpointDispose(source)
        }
        for destination in additionalVirtualDestinations where destination != 0 {
            MIDIEndpointDispose(destination)
        }
        if virtualSource != 0 { MIDIEndpointDispose(virtualSource) }
        if virtualDestination != 0 { MIDIEndpointDispose(virtualDestination) }
        if client != 0 { MIDIClientDispose(client) }
        additionalVirtualSources.removeAll()
        additionalVirtualDestinations.removeAll()
        additionalVirtualPortNames.removeAll()
        virtualSource = 0
        virtualDestination = 0
        client = 0
        isRunning = false
        inboundContinuation.finish()
        Log.info("MIDIEngine stopped", subsystem: "midi")
    }

    var isActive: Bool { isRunning && client != 0 }

    func portListJSON() -> String {
        let sources = (0..<MIDIGetNumberOfSources()).compactMap { endpointName(MIDIGetSource($0)) }
        let destinations = (0..<MIDIGetNumberOfDestinations()).compactMap { endpointName(MIDIGetDestination($0)) }
        let data = try? JSONSerialization.data(withJSONObject: [
            "sources": sources,
            "destinations": destinations,
        ])
        return data.flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"sources\":[],\"destinations\":[]}"
    }

    private func endpointName(_ endpoint: MIDIEndpointRef) -> String? {
        guard endpoint != 0 else { return nil }
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    /// Create an additional virtual source/destination pair.
    func createVirtualPort(named name: String) throws {
        if !isRunning {
            try start()
        }
        guard !additionalVirtualPortNames.contains(name) else { return }
        guard additionalVirtualPortNames.count < 16 else {
            throw MIDIEngineError.virtualPortLimitReached
        }

        var source: MIDIEndpointRef = 0
        var destination: MIDIEndpointRef = 0
        let sourceName = "\(name)-Out" as CFString
        let destinationName = "\(name)-In" as CFString

        var status = MIDISourceCreate(client, sourceName, &source)
        guard status == noErr else {
            throw MIDIEngineError.sourceCreationFailed(status)
        }

        let continuation = self.inboundContinuation
        status = MIDIDestinationCreateWithBlock(client, destinationName, &destination) { packetList, _ in
            let packets = packetList.pointee
            MIDIFeedback.parse(packetList: packets, into: continuation)
        }
        guard status == noErr else {
            MIDIEndpointDispose(source)
            throw MIDIEngineError.destinationCreationFailed(status)
        }

        additionalVirtualSources.append(source)
        additionalVirtualDestinations.append(destination)
        additionalVirtualPortNames.insert(name)
    }

    // MARK: - Send: Notes

    @discardableResult
    func sendNoteOn(channel: UInt8 = 0, note: UInt8, velocity: UInt8 = 100) -> Bool {
        let status: UInt8 = 0x90 | (channel & 0x0F)
        return sendShortMessage([status, note & 0x7F, velocity & 0x7F])
    }

    @discardableResult
    func sendNoteOff(channel: UInt8 = 0, note: UInt8, velocity: UInt8 = 0) -> Bool {
        let status: UInt8 = 0x80 | (channel & 0x0F)
        return sendShortMessage([status, note & 0x7F, velocity & 0x7F])
    }

    // MARK: - Send: Control Change

    @discardableResult
    func sendCC(channel: UInt8 = 0, controller: UInt8, value: UInt8) -> Bool {
        let status: UInt8 = 0xB0 | (channel & 0x0F)
        return sendShortMessage([status, controller & 0x7F, value & 0x7F])
    }

    // MARK: - Send: Program Change

    @discardableResult
    func sendProgramChange(channel: UInt8 = 0, program: UInt8) -> Bool {
        let status: UInt8 = 0xC0 | (channel & 0x0F)
        return sendShortMessage([status, program & 0x7F])
    }

    // MARK: - Send: Pitch Bend

    /// Send pitch bend. `value` is 14-bit (0-16383), center = 8192.
    @discardableResult
    func sendPitchBend(channel: UInt8 = 0, value: UInt16 = 8192) -> Bool {
        let clamped = min(value, 16383)
        let lsb = UInt8(clamped & 0x7F)
        let msb = UInt8((clamped >> 7) & 0x7F)
        let status: UInt8 = 0xE0 | (channel & 0x0F)
        return sendShortMessage([status, lsb, msb])
    }

    // MARK: - Send: Aftertouch

    /// Channel pressure (mono aftertouch).
    @discardableResult
    func sendAftertouch(channel: UInt8 = 0, pressure: UInt8) -> Bool {
        let status: UInt8 = 0xD0 | (channel & 0x0F)
        return sendShortMessage([status, pressure & 0x7F])
    }

    /// Polyphonic key pressure.
    @discardableResult
    func sendPolyAftertouch(channel: UInt8 = 0, note: UInt8, pressure: UInt8) -> Bool {
        let status: UInt8 = 0xA0 | (channel & 0x0F)
        return sendShortMessage([status, note & 0x7F, pressure & 0x7F])
    }

    // MARK: - Send: SysEx

    /// Send a complete SysEx message (must start with 0xF0 and end with 0xF7).
    @discardableResult
    func sendSysEx(_ bytes: [UInt8]) -> Bool {
        guard bytes.first == 0xF0, bytes.last == 0xF7 else {
            Log.error("Invalid SysEx: must start with F0 and end with F7", subsystem: "midi")
            return false
        }
        return sendRawBytes(bytes)
    }

    // MARK: - Send: Raw

    /// Send arbitrary MIDI bytes through the virtual source.
    @discardableResult
    func sendRawBytes(_ bytes: [UInt8]) -> Bool {
        guard isRunning else {
            Log.warn("MIDIEngine not running — dropping message", subsystem: "midi")
            return false
        }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            let packetListSize = MemoryLayout<MIDIPacketList>.size + bytes.count
            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: packetListSize,
                alignment: MemoryLayout<MIDIPacketList>.alignment
            )
            defer { storage.deallocate() }

            let packetList = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
            let packet = MIDIPacketListInit(packetList)
            _ = MIDIPacketListAdd(
                packetList,
                packetListSize,
                packet,
                0,
                bytes.count,
                baseAddress
            )

            let sources = ([virtualSource] + additionalVirtualSources).filter { $0 != 0 }
            guard !sources.isEmpty else {
                Log.error("No MIDI sources available", subsystem: "midi")
                return false
            }
            var accepted = true
            for source in sources {
                let status = MIDIReceived(source, packetList)
                if status != noErr {
                    Log.error("MIDIReceived failed with status \(status)", subsystem: "midi")
                    accepted = false
                }
            }
            return accepted
        }
    }

    // MARK: - Private

    private func sendShortMessage(_ bytes: [UInt8]) -> Bool {
        let accepted = sendRawBytes(bytes)
        if accepted {
            Log.debug("MIDI out: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))", subsystem: "midi")
        }
        return accepted
    }

    private nonisolated func handleMIDINotification(_ notification: UnsafePointer<MIDINotification>) {
        let id = notification.pointee.messageID
        switch id {
        case .msgSetupChanged:
            Log.debug("MIDI setup changed", subsystem: "midi")
        case .msgObjectAdded:
            Log.debug("MIDI object added", subsystem: "midi")
        case .msgObjectRemoved:
            Log.debug("MIDI object removed", subsystem: "midi")
        default:
            Log.debug("MIDI notification: \(id.rawValue)", subsystem: "midi")
        }
    }
}

// MARK: - Errors

enum MIDIEngineError: Error, Sendable {
    case clientCreationFailed(OSStatus)
    case sourceCreationFailed(OSStatus)
    case destinationCreationFailed(OSStatus)
    case virtualPortLimitReached
}
