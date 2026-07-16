import XCTest
@testable import LogicProMCP

/// Pure-logic tests for send_sequence validation and scheduling.
/// No Logic Pro or CoreMIDI required.
final class SequenceEventTests: XCTestCase {

    // MARK: - Parsing: valid input

    func testNoteParsesWithDefaults() throws {
        let ev = try SequenceEvent(["type": "note", "note": 60], defaultChannel: 3)
        guard case .note(let time, let ch, let note, let vel, let dur) = ev else {
            return XCTFail("expected .note, got \(ev)")
        }
        XCTAssertNil(time)
        XCTAssertEqual(ch, 3)
        XCTAssertEqual(note, 60)
        XCTAssertEqual(vel, 100)
        XCTAssertEqual(dur, 250)
    }

    func testUntypedEventDefaultsToNote() throws {
        let ev = try SequenceEvent(["note": 72], defaultChannel: 0)
        guard case .note = ev else { return XCTFail("expected .note, got \(ev)") }
    }

    func testChordParsesAllNotes() throws {
        let ev = try SequenceEvent(["type": "chord", "notes": [60, 64, 67]], defaultChannel: 0)
        guard case .chord(_, _, let notes, _, _) = ev else {
            return XCTFail("expected .chord, got \(ev)")
        }
        XCTAssertEqual(notes, [60, 64, 67])
    }

    // MARK: - Parsing: rejection (these inputs used to be coerced, dropped,
    // or trap the playback task)

    func testOutOfRangeNoteIsRejectedNotMasked() {
        XCTAssertThrowsError(try SequenceEvent(["type": "note", "note": 300], defaultChannel: 0))
        XCTAssertThrowsError(try SequenceEvent(["type": "note", "note": 128], defaultChannel: 0))
        XCTAssertThrowsError(try SequenceEvent(["type": "note", "note": -1], defaultChannel: 0))
    }

    func testMissingNoteIsRejectedNotDefaulted() {
        XCTAssertThrowsError(try SequenceEvent(["type": "note"], defaultChannel: 0))
    }

    func testChordWithInvalidMemberIsRejectedNotFiltered() {
        XCTAssertThrowsError(try SequenceEvent(["type": "chord", "notes": [60, 200, 64]], defaultChannel: 0))
        XCTAssertThrowsError(try SequenceEvent(["type": "chord", "notes": []], defaultChannel: 0))
    }

    func testUnknownTypeIsRejectedNotSkipped() {
        XCTAssertThrowsError(try SequenceEvent(["type": "warp", "note": 60], defaultChannel: 0))
    }

    func testChannelAboveFifteenIsRejected() {
        XCTAssertThrowsError(try SequenceEvent(["type": "note", "note": 60, "channel": 16], defaultChannel: 0))
    }

    func testNegativeDurationIsRejected() {
        XCTAssertThrowsError(try SequenceEvent(["type": "note", "note": 60, "duration_ms": -5], defaultChannel: 0))
    }

    func testCCRequiresControllerAndValue() {
        XCTAssertThrowsError(try SequenceEvent(["type": "cc", "controller": 7], defaultChannel: 0))
        XCTAssertNoThrow(try SequenceEvent(["type": "cc", "controller": 7, "value": 90], defaultChannel: 0))
    }

    // MARK: - Scheduling: absolute time_ms must not be delayed by durations

    func testOverlappingNotesKeepAbsoluteStarts() throws {
        // CodeRabbit's example: notes at 0 ms and 500 ms, both 1000 ms long,
        // must finish at 1500 ms -- not 2000 ms.
        let events = [
            try SequenceEvent(["type": "note", "note": 60, "time_ms": 0, "duration_ms": 1000], defaultChannel: 0),
            try SequenceEvent(["type": "note", "note": 64, "time_ms": 500, "duration_ms": 1000], defaultChannel: 0),
        ]
        let scheduled = CoreMIDIChannel.schedule(events)
        XCTAssertEqual(scheduled.map(\.startMs), [0, 500])
        let end = scheduled.map { $0.event.endOffset(from: $0.startMs) }.max()
        XCTAssertEqual(end, 1500)
    }

    func testUntimedEventsPlaySequentially() throws {
        let events = [
            try SequenceEvent(["type": "note", "note": 60, "duration_ms": 250], defaultChannel: 0),
            try SequenceEvent(["type": "rest", "duration_ms": 100], defaultChannel: 0),
            try SequenceEvent(["type": "note", "note": 62, "duration_ms": 250], defaultChannel: 0),
        ]
        let scheduled = CoreMIDIChannel.schedule(events)
        XCTAssertEqual(scheduled.map(\.startMs), [0, 250, 350])
    }

    func testUntimedOrderIsStable() throws {
        // All-untimed input must keep submitted order (the old unstable sort
        // keyed on time_ms ?? 0 could scramble it).
        let notes: [UInt8] = [60, 62, 64, 65, 67, 69, 71, 72]
        let events = try notes.map {
            try SequenceEvent(["type": "note", "note": Int($0), "duration_ms": 10], defaultChannel: 0)
        }
        let scheduled = CoreMIDIChannel.schedule(events)
        let played: [UInt8] = scheduled.compactMap {
            if case .note(_, _, let n, _, _) = $0.event { return n } else { return nil }
        }
        XCTAssertEqual(played, notes)
    }

    func testCCDoesNotAdvanceTimeline() throws {
        let events = [
            try SequenceEvent(["type": "cc", "controller": 7, "value": 100], defaultChannel: 0),
            try SequenceEvent(["type": "note", "note": 60, "duration_ms": 250], defaultChannel: 0),
        ]
        let scheduled = CoreMIDIChannel.schedule(events)
        XCTAssertEqual(scheduled.map(\.startMs), [0, 0])
    }

    // MARK: - Parameter helpers

    func testParseChannelBounds() {
        XCTAssertEqual(CoreMIDIChannel.parseChannel(nil, default: 5), 5)
        XCTAssertEqual(CoreMIDIChannel.parseChannel("15", default: 0), 15)
        XCTAssertNil(CoreMIDIChannel.parseChannel("16", default: 0))
        XCTAssertNil(CoreMIDIChannel.parseChannel("abc", default: 0))
    }

    func testParse7BitBounds() {
        XCTAssertEqual(CoreMIDIChannel.parse7Bit(nil, default: 100), 100)
        XCTAssertEqual(CoreMIDIChannel.parse7Bit("127", default: 0), 127)
        XCTAssertNil(CoreMIDIChannel.parse7Bit("128", default: 0))
        XCTAssertNil(CoreMIDIChannel.parse7Bit("200", default: 0))
    }
}
