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

        case "transport.play":
            await engine.sendSysEx(MMCCommands.play())
            return .success("MMC play sent")

        case "transport.stop":
            await engine.sendSysEx(MMCCommands.stop())
            return .success("MMC stop sent")

        case "transport.pause":
            await engine.sendSysEx(MMCCommands.pause())
            return .success("MMC pause sent")

        case "transport.record_strobe":
            await engine.sendSysEx(MMCCommands.recordStrobe())
            return .success("MMC record strobe sent")

        case "transport.record_exit":
            await engine.sendSysEx(MMCCommands.recordExit())
            return .success("MMC record exit sent")

        case "transport.fast_forward":
            await engine.sendSysEx(MMCCommands.fastForward())
            return .success("MMC fast forward sent")

        case "transport.rewind":
            await engine.sendSysEx(MMCCommands.rewind())
            return .success("MMC rewind sent")

        case "transport.locate":
            guard let h = params["hours"].flatMap(UInt8.init),
                  let m = params["minutes"].flatMap(UInt8.init),
                  let s = params["seconds"].flatMap(UInt8.init),
                  let f = params["frames"].flatMap(UInt8.init) else {
                return .error("locate requires hours, minutes, seconds, frames")
            }
            let sf = params["subframes"].flatMap(UInt8.init) ?? 0
            await engine.sendSysEx(MMCCommands.locate(hours: h, minutes: m, seconds: s, frames: f, subframes: sf))
            return .success("MMC locate sent to \(h):\(m):\(s):\(f).\(sf)")

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
            // Parse comma-separated notes. Every token must parse and be in
            // range -- silently dropping bad tokens would play a different
            // chord than the caller asked for, and out-of-range values would
            // otherwise be masked to unrelated notes by MIDIEngine.
            guard let notesStr = params["notes"], !notesStr.isEmpty else {
                return .error("send_chord requires 'notes' (comma-separated MIDI note numbers)")
            }
            var chordNotes: [UInt8] = []
            for token in notesStr.split(separator: ",") {
                let trimmed = token.trimmingCharacters(in: .whitespaces)
                guard let note = UInt8(trimmed), note <= 127 else {
                    return .error("send_chord: invalid note '\(trimmed)' -- each note must be 0-127")
                }
                chordNotes.append(note)
            }
            guard !chordNotes.isEmpty else {
                return .error("send_chord: no note numbers in '\(notesStr)'")
            }
            guard let chordChannel = Self.parseChannel(params["channel"], default: 0) else {
                return .error("send_chord: 'channel' must be 0-15")
            }
            guard let chordVelocity = Self.parse7Bit(params["velocity"], default: 100) else {
                return .error("send_chord: 'velocity' must be 0-127")
            }
            let chordDurationMs = params["duration_ms"].flatMap(UInt64.init) ?? 500
            // All notes on simultaneously
            for n in chordNotes {
                await engine.sendNoteOn(channel: chordChannel, note: n, velocity: chordVelocity)
            }
            try? await Task.sleep(nanoseconds: chordDurationMs * 1_000_000)
            // All notes off simultaneously
            for n in chordNotes {
                await engine.sendNoteOff(channel: chordChannel, note: n)
            }
            return .success("Chord [\(chordNotes.map(String.init).joined(separator: ","))] on ch \(chordChannel) vel \(chordVelocity) dur \(chordDurationMs)ms")

        case "midi.send_sequence":
            // Parse JSON-encoded sequence of timed events -- returns IMMEDIATELY, plays in background.
            // This prevents the MCP connection from timing out on long sequences.
            guard let eventsJSON = params["events"] else {
                return .error("send_sequence requires 'events' (JSON array of timed events)")
            }
            guard let eventsData = eventsJSON.data(using: .utf8),
                  let rawEvents = try? JSONSerialization.jsonObject(with: eventsData) as? [[String: Any]] else {
                return .error("send_sequence: 'events' must be a valid JSON array")
            }
            guard !rawEvents.isEmpty else {
                return .error("send_sequence: events array is empty")
            }
            guard let seqChannel = Self.parseChannel(params["channel"], default: 0) else {
                return .error("send_sequence: 'channel' must be 0-15")
            }

            // Validate every event up front, so a bad payload is rejected here
            // instead of being coerced (or trapping on UInt8 conversion, which
            // would kill the whole server) mid-playback in the detached task.
            var events: [SequenceEvent] = []
            for (index, raw) in rawEvents.enumerated() {
                do {
                    events.append(try SequenceEvent(raw, defaultChannel: seqChannel))
                } catch let error as SequenceEventError {
                    return .error("send_sequence: event \(index): \(error.message)")
                } catch {
                    return .error("send_sequence: event \(index): \(error)")
                }
            }

            // Assign each event an absolute start on one timeline. Events keep
            // their submitted order for equal explicit times (stable sort);
            // events without time_ms play sequentially from the running cursor,
            // preserving duration/rest-driven sequencing.
            let scheduled = Self.schedule(events)
            let eventCount = scheduled.count
            let estimatedDurationMs = scheduled.map { $0.event.endOffset(from: $0.startMs) }.max() ?? 0

            // Fire and forget -- play sequence in detached task. Note starts
            // are slept-to against one monotonic origin and note-offs are
            // dispatched independently, so a long duration never delays the
            // next event's start.
            let engineRef = self.engine
            Task.detached {
                let origin = ContinuousClock.now
                for (event, startMs) in scheduled {
                    try? await Task.sleep(until: origin + .milliseconds(Int64(startMs)), clock: .continuous)
                    switch event {
                    case .note(_, let ch, let note, let vel, let dur):
                        await engineRef.sendNoteOn(channel: ch, note: note, velocity: vel)
                        Task {
                            try? await Task.sleep(for: .milliseconds(Int64(dur)))
                            await engineRef.sendNoteOff(channel: ch, note: note)
                        }

                    case .chord(_, let ch, let notes, let vel, let dur):
                        for n in notes {
                            await engineRef.sendNoteOn(channel: ch, note: n, velocity: vel)
                        }
                        Task {
                            try? await Task.sleep(for: .milliseconds(Int64(dur)))
                            for n in notes {
                                await engineRef.sendNoteOff(channel: ch, note: n)
                            }
                        }

                    case .rest:
                        break  // rests only occupy the timeline; scheduling already accounted for them

                    case .cc(_, let ch, let controller, let value):
                        await engineRef.sendCC(channel: ch, controller: controller, value: value)

                    case .programChange(_, let ch, let program):
                        await engineRef.sendProgramChange(channel: ch, program: program)
                    }
                }
                Log.info("Sequence playback dispatched: \(scheduled.count) events over ~\(estimatedDurationMs)ms", subsystem: "midi")
            }

            return .success("Sequence started: \(eventCount) events, ~\(estimatedDurationMs)ms duration (playing in background)")

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

        case "midi.program_change":
            guard let program = params["program"].flatMap(UInt8.init) else {
                return .error("program_change requires 'program' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendProgramChange(channel: channel, program: program)
            return .success("Program change \(program) on ch \(channel)")

        // MARK: - Pitch Bend

        case "midi.pitch_bend":
            guard let value = params["value"].flatMap(UInt16.init) else {
                return .error("pitch_bend requires 'value' (0-16383, center=8192)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendPitchBend(channel: channel, value: value)
            return .success("Pitch bend \(value) on ch \(channel)")

        // MARK: - Aftertouch

        case "midi.aftertouch":
            guard let pressure = params["pressure"].flatMap(UInt8.init) else {
                return .error("aftertouch requires 'pressure' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendAftertouch(channel: channel, pressure: pressure)
            return .success("Aftertouch \(pressure) on ch \(channel)")

        // MARK: - Raw SysEx

        case "midi.send_sysex":
            guard let hexString = params["bytes"] else {
                return .error("send_sysex requires 'bytes' (hex string, e.g. 'F0 7F 7F 06 02 F7')")
            }
            let bytes = hexString.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            guard bytes.first == 0xF0, bytes.last == 0xF7 else {
                return .error("SysEx must start with F0 and end with F7")
            }
            await engine.sendSysEx(bytes)
            return .success("SysEx sent (\(bytes.count) bytes)")

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
}

// MARK: - Parameter validation helpers

extension CoreMIDIChannel {
    /// Parse an optional string parameter as a MIDI channel (0-15).
    /// Returns the default when absent, nil when present but invalid --
    /// out-of-range channels must be rejected, not masked by MIDIEngine.
    static func parseChannel(_ raw: String?, default def: UInt8) -> UInt8? {
        guard let raw else { return def }
        guard let value = UInt8(raw), value <= 15 else { return nil }
        return value
    }

    /// Parse an optional string parameter as a 7-bit MIDI value (0-127).
    static func parse7Bit(_ raw: String?, default def: UInt8) -> UInt8? {
        guard let raw else { return def }
        guard let value = UInt8(raw), value <= 127 else { return nil }
        return value
    }

    /// Assign every event an absolute start time (ms) on one timeline.
    /// Events are stably ordered by explicit time_ms (submitted order breaks
    /// ties, so purely sequential input keeps its order). An event without
    /// time_ms starts at the running cursor; note/chord/rest advance the
    /// cursor by their duration, cc/program_change do not.
    static func schedule(_ events: [SequenceEvent]) -> [(event: SequenceEvent, startMs: UInt64)] {
        let ordered = events.enumerated()
            .sorted { ($0.element.timeMs ?? 0, $0.offset) < ($1.element.timeMs ?? 0, $1.offset) }
            .map(\.element)

        var cursor: UInt64 = 0
        var scheduled: [(event: SequenceEvent, startMs: UInt64)] = []
        for event in ordered {
            let start = event.timeMs ?? cursor
            scheduled.append((event, start))
            cursor = event.advancesTimeline ? start + event.durationMs : max(cursor, start)
        }
        return scheduled
    }
}

// MARK: - Sequence events

/// A fully validated send_sequence event. All range checks happen in the
/// parser so the playback task never performs a trapping integer conversion.
enum SequenceEvent: Sendable {
    case note(timeMs: UInt64?, channel: UInt8, note: UInt8, velocity: UInt8, durationMs: UInt64)
    case chord(timeMs: UInt64?, channel: UInt8, notes: [UInt8], velocity: UInt8, durationMs: UInt64)
    case rest(timeMs: UInt64?, durationMs: UInt64)
    case cc(timeMs: UInt64?, channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(timeMs: UInt64?, channel: UInt8, program: UInt8)

    var timeMs: UInt64? {
        switch self {
        case .note(let t, _, _, _, _), .chord(let t, _, _, _, _), .rest(let t, _),
             .cc(let t, _, _, _), .programChange(let t, _, _):
            return t
        }
    }

    var durationMs: UInt64 {
        switch self {
        case .note(_, _, _, _, let d), .chord(_, _, _, _, let d), .rest(_, let d):
            return d
        case .cc, .programChange:
            return 0
        }
    }

    /// Whether the event occupies time on the sequence timeline.
    var advancesTimeline: Bool {
        switch self {
        case .note, .chord, .rest: return true
        case .cc, .programChange: return false
        }
    }

    /// Timeline position at which this event is finished, given its start.
    func endOffset(from startMs: UInt64) -> UInt64 {
        startMs + durationMs
    }

    init(_ raw: [String: Any], defaultChannel: UInt8) throws {
        let type = raw["type"] as? String ?? "note"
        let timeMs = try Self.optionalUInt64(raw, "time_ms")
        let channel = try Self.bounded(raw, "channel", max: 15, default: defaultChannel)

        switch type {
        case "note":
            guard raw["note"] != nil else {
                throw SequenceEventError("'note' is required (0-127)")
            }
            self = .note(
                timeMs: timeMs,
                channel: channel,
                note: try Self.bounded(raw, "note", max: 127, default: 0),
                velocity: try Self.bounded(raw, "velocity", max: 127, default: 100),
                durationMs: try Self.optionalUInt64(raw, "duration_ms") ?? 250
            )

        case "chord":
            guard let rawNotes = raw["notes"] as? [Any], !rawNotes.isEmpty else {
                throw SequenceEventError("'notes' is required (non-empty array of 0-127)")
            }
            var notes: [UInt8] = []
            for member in rawNotes {
                guard let n = member as? Int, (0...127).contains(n) else {
                    throw SequenceEventError("'notes' contains invalid entry '\(member)' -- each note must be 0-127")
                }
                notes.append(UInt8(n))
            }
            self = .chord(
                timeMs: timeMs,
                channel: channel,
                notes: notes,
                velocity: try Self.bounded(raw, "velocity", max: 127, default: 100),
                durationMs: try Self.optionalUInt64(raw, "duration_ms") ?? 500
            )

        case "rest":
            self = .rest(
                timeMs: timeMs,
                durationMs: try Self.optionalUInt64(raw, "duration_ms") ?? 250
            )

        case "cc":
            guard raw["controller"] != nil, raw["value"] != nil else {
                throw SequenceEventError("'controller' and 'value' are required (0-127)")
            }
            self = .cc(
                timeMs: timeMs,
                channel: channel,
                controller: try Self.bounded(raw, "controller", max: 127, default: 0),
                value: try Self.bounded(raw, "value", max: 127, default: 0)
            )

        case "program_change":
            guard raw["program"] != nil else {
                throw SequenceEventError("'program' is required (0-127)")
            }
            self = .programChange(
                timeMs: timeMs,
                channel: channel,
                program: try Self.bounded(raw, "program", max: 127, default: 0)
            )

        default:
            throw SequenceEventError("unknown event type '\(type)' -- supported: note, chord, rest, cc, program_change")
        }
    }

    /// Read an optional integer field, requiring 0...max when present.
    private static func bounded(_ raw: [String: Any], _ key: String, max: Int, default def: UInt8) throws -> UInt8 {
        guard let value = raw[key] else { return def }
        guard let n = value as? Int, (0...max).contains(n) else {
            throw SequenceEventError("'\(key)' must be an integer 0-\(max), got '\(value)'")
        }
        return UInt8(n)
    }

    /// Read an optional non-negative integer field as milliseconds.
    private static func optionalUInt64(_ raw: [String: Any], _ key: String) throws -> UInt64? {
        guard let value = raw[key] else { return nil }
        guard let n = value as? Int, n >= 0 else {
            throw SequenceEventError("'\(key)' must be a non-negative integer, got '\(value)'")
        }
        return UInt64(n)
    }
}

struct SequenceEventError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
