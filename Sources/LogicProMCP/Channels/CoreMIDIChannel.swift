import Foundation

/// Channel that routes operations through CoreMIDI / MMC.
actor CoreMIDIChannel: Channel {
    let id: ChannelID = .coreMIDI
    private let engine: MIDIEngine

    init(engine: MIDIEngine) {
        self.engine = engine
    }

    func start() async throws {
        try await engine.start()
        Log.info("CoreMIDIChannel started", subsystem: "midi")
    }

    func stop() async {
        await engine.stop()
        Log.info("CoreMIDIChannel stopped", subsystem: "midi")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        switch operation {
        // MARK: - Transport (MMC)

        case "transport.play", "mmc.play":
            await engine.sendSysEx(MMCCommands.play())
            return .success("MMC play sent")

        case "transport.stop", "mmc.stop":
            await engine.sendSysEx(MMCCommands.stop())
            return .success("MMC stop sent")

        case "transport.pause", "mmc.pause":
            await engine.sendSysEx(MMCCommands.pause())
            return .success("MMC pause sent")

        case "transport.record_strobe", "mmc.record_strobe":
            await engine.sendSysEx(MMCCommands.recordStrobe())
            return .success("MMC record strobe sent")

        case "transport.record_exit", "mmc.record_exit":
            await engine.sendSysEx(MMCCommands.recordExit())
            return .success("MMC record exit sent")

        case "transport.fast_forward":
            await engine.sendSysEx(MMCCommands.fastForward())
            return .success("MMC fast forward sent")

        case "transport.rewind":
            await engine.sendSysEx(MMCCommands.rewind())
            return .success("MMC rewind sent")

        case "transport.locate", "mmc.locate":
            guard let position = parseLocatePosition(params) else {
                return .error("locate requires hours/minutes/seconds/frames, time, or bar")
            }
            await engine.sendSysEx(MMCCommands.locate(hours: position.hours, minutes: position.minutes, seconds: position.seconds, frames: position.frames, subframes: position.subframes))
            return .success("MMC locate sent to \(position.description)")

        // MARK: - Note Send

        case "midi.send_note":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("send_note requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            let velocity = params["velocity"].flatMap(UInt8.init) ?? 100
            let durationMs = params["duration_ms"].flatMap(UInt64.init) ?? 250
            await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
            await engine.sendNoteOff(channel: channel, note: note)
            return .success("Note \(note) on ch \(channel) vel \(velocity) dur \(durationMs)ms")

        case "midi.send_chord":
            guard let notes = parseNoteList(params["notes"]) else {
                return .error("send_chord requires 'notes' (comma-separated 0-127 values)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            let velocity = params["velocity"].flatMap(UInt8.init) ?? 100
            let durationMs = params["duration_ms"].flatMap(UInt64.init) ?? 250
            for note in notes {
                await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            }
            try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
            for note in notes {
                await engine.sendNoteOff(channel: channel, note: note)
            }
            return .success("Chord \(notes.map(String.init).joined(separator: ",")) on ch \(channel) vel \(velocity) dur \(durationMs)ms")

        case "midi.note_on":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("note_on requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            let velocity = params["velocity"].flatMap(UInt8.init) ?? 100
            await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            return .success("Note on \(note) ch \(channel) vel \(velocity)")

        case "midi.note_off":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("note_off requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendNoteOff(channel: channel, note: note)
            return .success("Note off \(note) ch \(channel)")

        // MARK: - CC

        case "midi.send_cc":
            guard let controller = params["controller"].flatMap(UInt8.init),
                  let value = params["value"].flatMap(UInt8.init) else {
                return .error("send_cc requires 'controller' and 'value' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendCC(channel: channel, controller: controller, value: value)
            return .success("CC \(controller)=\(value) on ch \(channel)")

        // MARK: - Program Change

        case "midi.program_change", "midi.send_program_change":
            guard let program = params["program"].flatMap(UInt8.init) else {
                return .error("program_change requires 'program' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendProgramChange(channel: channel, program: program)
            return .success("Program change \(program) on ch \(channel)")

        // MARK: - Pitch Bend

        case "midi.pitch_bend", "midi.send_pitch_bend":
            guard let value = parsePitchBendValue(params["value"], operation: operation) else {
                return .error("pitch_bend requires 'value' (-8192 to 8191 or 0-16383)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendPitchBend(channel: channel, value: value)
            return .success("Pitch bend \(value) on ch \(channel)")

        // MARK: - Aftertouch

        case "midi.aftertouch", "midi.send_aftertouch":
            guard let pressure = (params["pressure"] ?? params["value"]).flatMap(UInt8.init) else {
                return .error("aftertouch requires 'pressure' or 'value' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendAftertouch(channel: channel, pressure: pressure)
            return .success("Aftertouch \(pressure) on ch \(channel)")

        // MARK: - Raw SysEx

        case "midi.send_sysex":
            guard let data = params["bytes"] ?? params["data"] else {
                return .error("send_sysex requires 'bytes' or 'data' (hex string, e.g. 'F0 7F 7F 06 02 F7')")
            }
            guard let bytes = parseMIDIBytes(data) else {
                return .error("send_sysex requires valid hex bytes")
            }
            guard bytes.first == 0xF0, bytes.last == 0xF7 else {
                return .error("SysEx must start with F0 and end with F7")
            }
            await engine.sendSysEx(bytes)
            return .success("SysEx sent (\(bytes.count) bytes)")

        // MARK: - Virtual Ports

        case "midi.create_virtual_port":
            guard let name = params["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("create_virtual_port requires 'name'")
            }
            do {
                try await engine.createVirtualPort(name: name)
                return .success("Virtual MIDI port created: \(name)")
            } catch {
                return .error("Failed to create virtual MIDI port: \(error)")
            }

        default:
            return .error("Unknown CoreMIDI operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        let active = await engine.isActive
        if active {
            return .healthy(detail: "CoreMIDI client active, virtual ports created")
        } else {
            return .unavailable("CoreMIDI client not initialized")
        }
    }

    private struct LocatePosition {
        let hours: UInt8
        let minutes: UInt8
        let seconds: UInt8
        let frames: UInt8
        let subframes: UInt8
        let description: String
    }

    private func parseLocatePosition(_ params: [String: String]) -> LocatePosition? {
        if let time = params["time"] {
            return parseLocateTime(time, subframes: params["subframes"].flatMap(UInt8.init) ?? 0)
        }

        if let bar = params["bar"].flatMap(Int.init) {
            let totalSeconds = max(bar - 1, 0) * 2
            return locatePosition(totalSeconds: totalSeconds, description: "bar \(bar)")
        }

        guard let hours = params["hours"].flatMap(UInt8.init),
              let minutes = params["minutes"].flatMap(UInt8.init),
              let seconds = params["seconds"].flatMap(UInt8.init),
              let frames = params["frames"].flatMap(UInt8.init) else {
            return nil
        }
        let subframes = params["subframes"].flatMap(UInt8.init) ?? 0
        return LocatePosition(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            subframes: subframes,
            description: "\(hours):\(minutes):\(seconds):\(frames).\(subframes)"
        )
    }

    private func parseLocateTime(_ time: String, subframes: UInt8) -> LocatePosition? {
        let parts = time.split(separator: ":")
        guard parts.count == 4 || parts.count == 5,
              let hours = UInt8(parts[0]),
              let minutes = UInt8(parts[1]),
              let seconds = UInt8(parts[2]),
              let frames = UInt8(parts[3]) else {
            return nil
        }
        let parsedSubframes = parts.count == 5 ? UInt8(parts[4]) : subframes
        guard let sf = parsedSubframes else { return nil }
        return LocatePosition(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            subframes: sf,
            description: "\(hours):\(minutes):\(seconds):\(frames).\(sf)"
        )
    }

    private func locatePosition(totalSeconds: Int, description: String) -> LocatePosition {
        let clampedSeconds = min(totalSeconds, 23 * 60 * 60 + 59 * 60 + 59)
        let hours = UInt8(clampedSeconds / 3600)
        let minutes = UInt8((clampedSeconds % 3600) / 60)
        let seconds = UInt8(clampedSeconds % 60)
        return LocatePosition(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: 0,
            subframes: 0,
            description: description
        )
    }

    private func parseNoteList(_ value: String?) -> [UInt8]? {
        guard let value else { return nil }
        let tokens = value.split { character in
            character == "," || character == " " || character == "[" || character == "]"
        }
        guard !tokens.isEmpty else { return nil }
        var notes: [UInt8] = []
        for token in tokens {
            guard let note = UInt8(token) else { return nil }
            notes.append(note)
        }
        return notes.isEmpty ? nil : notes
    }

    private func parsePitchBendValue(_ value: String?, operation: String) -> UInt16? {
        guard let value = value.flatMap(Int.init) else { return nil }
        if operation == "midi.send_pitch_bend" || value < 0 {
            let clamped = min(max(value, -8192), 8191)
            return UInt16(clamped + 8192)
        }
        return UInt16(min(max(value, 0), 16383))
    }

    private func parseMIDIBytes(_ value: String) -> [UInt8]? {
        let tokens = value.split { character in
            character == " " || character == "," || character == "[" || character == "]"
        }
        guard !tokens.isEmpty else { return nil }
        var bytes: [UInt8] = []
        for token in tokens {
            let tokenString = String(token)
            let trimmed = if tokenString.hasPrefix("0x") || tokenString.hasPrefix("0X") {
                String(tokenString.dropFirst(2))
            } else {
                tokenString
            }
            guard let byte = UInt8(trimmed, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
