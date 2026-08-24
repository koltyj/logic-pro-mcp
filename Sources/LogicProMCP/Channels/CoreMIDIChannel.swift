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
            return .unverified("MMC play sent; Logic delivery is not verified")

        case "transport.stop", "mmc.stop":
            await engine.sendSysEx(MMCCommands.stop())
            return .unverified("MMC stop sent; Logic delivery is not verified")

        case "transport.pause", "mmc.pause":
            await engine.sendSysEx(MMCCommands.pause())
            return .unverified("MMC pause sent; Logic delivery is not verified")

        case "transport.record", "transport.record_strobe", "mmc.record_strobe":
            await engine.sendSysEx(MMCCommands.recordStrobe())
            return .unverified("MMC record strobe sent; Logic delivery is not verified")

        case "transport.record_exit", "mmc.record_exit":
            await engine.sendSysEx(MMCCommands.recordExit())
            return .unverified("MMC record exit sent; Logic delivery is not verified")

        case "transport.fast_forward":
            await engine.sendSysEx(MMCCommands.fastForward())
            return .unverified("MMC fast forward sent; Logic delivery is not verified")

        case "transport.rewind":
            await engine.sendSysEx(MMCCommands.rewind())
            return .unverified("MMC rewind sent; Logic delivery is not verified")

        case "transport.locate", "mmc.locate":
            guard let time = Self.parseSMPTETime(params) else {
                return .error("locate requires 'time' (HH:MM:SS:FF) or hours, minutes, seconds, frames")
            }
            await engine.sendSysEx(MMCCommands.locate(
                hours: time.hours,
                minutes: time.minutes,
                seconds: time.seconds,
                frames: time.frames,
                subframes: time.subframes
            ))
            return .unverified("MMC locate sent to \(time.hours):\(time.minutes):\(time.seconds):\(time.frames).\(time.subframes); Logic delivery is not verified")

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
            return .unverified("Note \(note) sent to the virtual MIDI port; Logic delivery is not verified")

        case "midi.note_on":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("note_on requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            let velocity = params["velocity"].flatMap(UInt8.init) ?? 100
            await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            return .unverified("Note on \(note) sent to the virtual MIDI port; Logic delivery is not verified")

        case "midi.note_off":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("note_off requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendNoteOff(channel: channel, note: note)
            return .unverified("Note off \(note) sent to the virtual MIDI port; Logic delivery is not verified")

        // MARK: - CC

        case "midi.send_chord":
            guard let notesParam = params["notes"] else {
                return .error("send_chord requires 'notes' as comma-separated MIDI notes")
            }
            var notes: [UInt8] = []
            for token in notesParam.split(separator: ",", omittingEmptySubsequences: false) {
                let noteToken = token.trimmingCharacters(in: .whitespaces)
                guard let note = UInt8(noteToken), note <= 127 else {
                    return .error("send_chord requires valid MIDI note numbers; invalid token: '\(noteToken)'")
                }
                notes.append(note)
            }
            guard !notes.isEmpty else {
                return .error("send_chord requires 'notes' as comma-separated MIDI notes")
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
            return .unverified("Chord \(notes.map(String.init).joined(separator: ",")) sent to the virtual MIDI port; Logic delivery is not verified")

        case "midi.send_cc":
            guard let controller = params["controller"].flatMap(UInt8.init),
                  let value = params["value"].flatMap(UInt8.init) else {
                return .error("send_cc requires 'controller' and 'value' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendCC(channel: channel, controller: controller, value: value)
            return .unverified("CC \(controller)=\(value) sent to the virtual MIDI port; Logic delivery is not verified")

        // MARK: - Program Change

        case "midi.program_change", "midi.send_program_change":
            guard let program = params["program"].flatMap(UInt8.init) else {
                return .error("program_change requires 'program' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendProgramChange(channel: channel, program: program)
            return .unverified("Program change \(program) sent to the virtual MIDI port; Logic delivery is not verified")

        // MARK: - Pitch Bend

        case "midi.pitch_bend":
            guard let value = params["value"].flatMap(UInt16.init), value <= 16_383 else {
                return .error("pitch_bend requires 'value' (0-16383, center=8192)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendPitchBend(channel: channel, value: value)
            return .unverified("Pitch bend \(value) sent to the virtual MIDI port; Logic delivery is not verified")

        case "midi.send_pitch_bend":
            guard let value = Self.parseSignedPitchBend(params["value"]) else {
                return .error("send_pitch_bend requires 'value' (-8192...8191)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendPitchBend(channel: channel, value: value)
            return .unverified("Pitch bend \(value) sent to the virtual MIDI port; Logic delivery is not verified")

        // MARK: - Aftertouch

        case "midi.aftertouch", "midi.send_aftertouch":
            guard let pressure = (params["pressure"] ?? params["value"]).flatMap(UInt8.init) else {
                return .error("aftertouch requires 'pressure' or 'value' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendAftertouch(channel: channel, pressure: pressure)
            return .unverified("Aftertouch \(pressure) sent to the virtual MIDI port; Logic delivery is not verified")

        // MARK: - Raw SysEx

        case "midi.send_sysex":
            guard let hexString = params["bytes"] ?? params["data"] else {
                return .error("send_sysex requires 'bytes' or 'data' (hex string, e.g. 'F0 7F 7F 06 02 F7')")
            }
            var bytes: [UInt8] = []
            for token in hexString.split(whereSeparator: \.isWhitespace) {
                guard let byte = UInt8(token, radix: 16) else {
                    return .error("Malformed SysEx: invalid hex token '\(token)'")
                }
                bytes.append(byte)
            }
            guard bytes.first == 0xF0, bytes.last == 0xF7 else {
                return .error("SysEx must start with F0 and end with F7")
            }
            await engine.sendSysEx(bytes)
            return .unverified("SysEx sent to the virtual MIDI port (\(bytes.count) bytes); Logic delivery is not verified")

        case "midi.list_ports":
            return .success(await engine.portListJSON())

        case "midi.create_virtual_port":
            let name = params["name"] ?? "LogicProMCP-Virtual"
            do {
                try await engine.createVirtualPort(named: name)
                return .success("Virtual MIDI port created: \(name)")
            } catch {
                return .error("Failed to create virtual MIDI port '\(name)': \(error)")
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

    private static func parseSignedPitchBend(_ rawValue: String?) -> UInt16? {
        guard let rawValue, let intValue = Int(rawValue) else { return nil }
        guard (-8192...8191).contains(intValue) else { return nil }
        return UInt16(intValue + 8192)
    }

    private static func parseSMPTETime(_ params: [String: String]) -> (
        hours: UInt8,
        minutes: UInt8,
        seconds: UInt8,
        frames: UInt8,
        subframes: UInt8
    )? {
        if let time = params["time"] ?? params["position"] {
            let tokens = time.split(separator: ":", omittingEmptySubsequences: false)
            guard tokens.count == 4 else { return nil }
            var parts: [UInt8] = []
            for token in tokens {
                guard let value = UInt8(token) else { return nil }
                parts.append(value)
            }
            guard let subframes = parseOptionalSubframes(params) else { return nil }
            return validatedSMPTETime(
                hours: parts[0],
                minutes: parts[1],
                seconds: parts[2],
                frames: parts[3],
                subframes: subframes
            )
        }

        guard let hours = params["hours"].flatMap(UInt8.init),
              let minutes = params["minutes"].flatMap(UInt8.init),
              let seconds = params["seconds"].flatMap(UInt8.init),
              let frames = params["frames"].flatMap(UInt8.init) else {
            return nil
        }
        guard let subframes = parseOptionalSubframes(params) else { return nil }
        return validatedSMPTETime(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            subframes: subframes
        )
    }

    private static func parseOptionalSubframes(_ params: [String: String]) -> UInt8? {
        guard let rawSubframes = params["subframes"] else { return 0 }
        return UInt8(rawSubframes)
    }

    private static func validatedSMPTETime(
        hours: UInt8,
        minutes: UInt8,
        seconds: UInt8,
        frames: UInt8,
        subframes: UInt8
    ) -> (
        hours: UInt8,
        minutes: UInt8,
        seconds: UInt8,
        frames: UInt8,
        subframes: UInt8
    )? {
        guard hours <= 23,
              minutes <= 59,
              seconds <= 59,
              frames <= 29,
              subframes <= 99 else {
            return nil
        }
        return (hours, minutes, seconds, frames, subframes)
    }
}
