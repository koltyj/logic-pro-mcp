import Foundation

// MARK: - BarNumberAPI
//
// Unified tick <-> bar conversion built directly from a Logic Pro `ProjectData`
// binary blob. This type is intentionally **independent** of
// `ProjectDataParser`: it reimplements the minimum chunk scan and tempo / marker
// decode it needs so callers can map ticks to bars without running the full
// parser pipeline.
//
// Patterns mirrored from `ProjectDataParser.swift`:
//   * Chunk scanner (anchor-pattern detection)             — parser ~L264
//   * Standard tempo signature `7F 00 00 01`               — parser L522
//   * Type-96 tempo bridge pair                             — parser L565
//   * Type-18 marker triplet                                — parser L450
//   * Timeline tick offset from the earliest marker tick    — parser L818
//
// Tick conventions
// ----------------
// Logic's tick grid at 4/4 is `ticksPerBar = 3840`. Within a tempo segment we
// assume a constant time signature of 4/4, so bar is a linear function of tick
// inside that segment: `bar = (tick - anchorTick) / 3840 + anchorBar`.
//
// Ticks arriving from tempo and marker events are in the project's absolute
// timeline space. Logic can include a large pre-roll before bar 1; we subtract
// `timelineTickOffset` (computed from the smallest type-18 marker tick) so that
// **normalized tick 0 aligns with bar 1.0**. Callers that already have relative
// ticks (e.g., from `ParsedRegion.startTick`, which is already offset-adjusted)
// can pass them directly to `bar(forTick:)`.

/// A single tempo-map anchor used by `BarNumberAPI`.
///
/// An anchor ties a normalized tick (offset-adjusted, with tick 0 == bar 1.0)
/// to a fractional 1-based bar number and the BPM that is in effect at that
/// anchor going forward (until the next anchor, if any).
public struct BarAnchor: Sendable, Codable, Hashable {
    /// Normalized tick: `raw_absolute_tick - timelineTickOffset`.
    public let tick: Int
    /// 1-based fractional bar number at `tick`.
    public let bar: Double
    /// BPM that takes effect **at this anchor** and extends forward.
    public let bpm: Double

    public init(tick: Int, bar: Double, bpm: Double) {
        self.tick = tick
        self.bar = bar
        self.bpm = bpm
    }
}

/// Unified bar-number API computed from a `ProjectData` blob.
///
/// Use `BarNumberAPI.build(from:)` to construct one from raw bytes. The
/// resulting value is `Sendable` and cheap to copy.
public struct BarNumberAPI: Sendable, Codable {

    // MARK: Stored properties

    /// Tempo anchors sorted by `tick`; `anchors[0].tick == 0` is guaranteed
    /// whenever at least one tempo event was discovered.
    public let anchors: [BarAnchor]

    /// Ticks per bar at 4/4 (Logic's resolution = 3840).
    public let ticksPerBar: Int

    /// The timeline pre-roll offset subtracted from raw tempo/marker ticks so
    /// that anchor ticks are relative (tick 0 == bar 1.0). Mirrors
    /// `ProjectDataParser.computeTimelineTickOffset`.
    public let timelineTickOffset: Int

    // MARK: Construction

    public init(anchors: [BarAnchor], ticksPerBar: Int, timelineTickOffset: Int) {
        self.anchors = anchors
        self.ticksPerBar = ticksPerBar
        self.timelineTickOffset = timelineTickOffset
    }

    /// Build a `BarNumberAPI` from a `ProjectData` byte blob.
    ///
    /// - Parameter data: Contents of `<project>.logicx/Alternatives/XXX/ProjectData`.
    /// - Returns: A `BarNumberAPI` with at least one anchor when any tempo event
    ///   was discovered. If the blob is empty or has no decodable tempo
    ///   events, the returned API still works and degenerates to a constant
    ///   120 BPM mapping anchored at bar 1.0 / tick 0.
    public static func build(from data: Data) -> BarNumberAPI {
        let ticksPerBar = 3840

        // No valid magic → degenerate default so callers still get a usable API.
        guard validateMagic(data) else {
            return BarNumberAPI(
                anchors: [BarAnchor(tick: 0, bar: 1.0, bpm: 120.0)],
                ticksPerBar: ticksPerBar,
                timelineTickOffset: 0
            )
        }

        let chunks = scanChunks(data: data)

        // Gather tempo events (both strategies) and marker events from EvSq.
        var rawTempos: [(tick: Int, bpm: Double)] = []
        var markerStartTicks: [Int] = []

        for chunk in chunks where chunk.id == "EvSq" {
            guard chunk.bodyLength >= 20,
                  chunk.bodyOffset >= 0,
                  chunk.bodyOffset + chunk.bodyLength <= data.count
            else { continue }
            let body = Data(data[chunk.bodyOffset..<(chunk.bodyOffset + chunk.bodyLength)])

            rawTempos.append(contentsOf: parseStandardTempos(body: body))
            rawTempos.append(contentsOf: parseType96Tempos(body: body))
            markerStartTicks.append(contentsOf: parseType18MarkerTicks(body: body))
        }

        let timelineTickOffset = computeTimelineTickOffset(
            markerStartTicks: markerStartTicks,
            ticksPerBar: ticksPerBar
        )

        // Normalize, sort, and dedupe tempos by normalized tick.
        var seenTicks = Set<Int>()
        var normalized: [(tick: Int, bpm: Double)] = []
        for t in rawTempos.sorted(by: { $0.tick < $1.tick }) {
            let nt = t.tick - timelineTickOffset
            guard nt >= 0 else { continue }
            if seenTicks.insert(nt).inserted {
                normalized.append((tick: nt, bpm: t.bpm))
            }
        }

        // Build anchors. Within each segment we assume 4/4, so
        // bar = tick / ticksPerBar + 1 for every anchor.
        var anchors: [BarAnchor] = normalized.map { entry in
            BarAnchor(
                tick: entry.tick,
                bar: Double(entry.tick) / Double(ticksPerBar) + 1.0,
                bpm: entry.bpm
            )
        }

        // Ensure we always have an anchor at tick 0 / bar 1.0.
        if anchors.first?.tick != 0 {
            let firstBPM = anchors.first?.bpm ?? 120.0
            anchors.insert(BarAnchor(tick: 0, bar: 1.0, bpm: firstBPM), at: 0)
        }

        return BarNumberAPI(
            anchors: anchors,
            ticksPerBar: ticksPerBar,
            timelineTickOffset: timelineTickOffset
        )
    }

    // MARK: Public conversion API

    /// Convert a (normalized) tick to a 1-based fractional bar number.
    ///
    /// Piecewise-linear interpolation between consecutive anchors assuming
    /// 4/4 inside each segment. Ticks at or below the first anchor clamp to
    /// `anchors.first!.bar`; ticks beyond the last anchor extrapolate linearly
    /// using the last segment's tick→bar slope (constant within 4/4).
    public func bar(forTick tick: Int) -> Double {
        guard let first = anchors.first else {
            return Double(tick) / Double(ticksPerBar) + 1.0
        }

        if tick <= first.tick {
            return first.bar
        }

        // Walk segments [i, i+1) to find the enclosing pair.
        if anchors.count >= 2 {
            for i in 0..<(anchors.count - 1) {
                let a = anchors[i]
                let b = anchors[i + 1]
                if tick >= a.tick && tick <= b.tick {
                    let span = Double(b.tick - a.tick)
                    if span <= 0 { return a.bar }
                    let frac = Double(tick - a.tick) / span
                    return a.bar + frac * (b.bar - a.bar)
                }
            }
        }

        // Extrapolate past the last anchor using 4/4 (1 bar per ticksPerBar).
        let last = anchors.last!
        let deltaTicks = Double(tick - last.tick)
        return last.bar + deltaTicks / Double(ticksPerBar)
    }

    /// Convert a 1-based fractional bar number to a (normalized) tick.
    /// Inverse of `bar(forTick:)`.
    public func tick(forBar bar: Double) -> Int {
        guard let first = anchors.first else {
            return Int(((bar - 1.0) * Double(ticksPerBar)).rounded())
        }

        if bar <= first.bar {
            return first.tick
        }

        if anchors.count >= 2 {
            for i in 0..<(anchors.count - 1) {
                let a = anchors[i]
                let b = anchors[i + 1]
                if bar >= a.bar && bar <= b.bar {
                    let span = b.bar - a.bar
                    if span <= 0 { return a.tick }
                    let frac = (bar - a.bar) / span
                    let tickDouble = Double(a.tick) + frac * Double(b.tick - a.tick)
                    return Int(tickDouble.rounded())
                }
            }
        }

        let last = anchors.last!
        let deltaBars = bar - last.bar
        return last.tick + Int((deltaBars * Double(ticksPerBar)).rounded())
    }

    // MARK: - Private: Magic validation

    private static func validateMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[data.startIndex] == 0x23
            && data[data.startIndex + 1] == 0x47
            && data[data.startIndex + 2] == 0xC0
            && data[data.startIndex + 3] == 0xAB
    }

    // MARK: - Private: Chunk scan

    private struct ChunkInfo {
        let id: String       // reversed 4-char id (e.g. "EvSq")
        let bodyOffset: Int
        let bodyLength: Int
    }

    private static let anchorOffset = 0x16
    private static let chunkHeaderSize = 36
    private static let lengthOffset = 0x1C

    /// Anchor-pattern chunk scanner, adapted from `ProjectDataParser.scanChunks`.
    private static func scanChunks(data: Data) -> [ChunkInfo] {
        var result: [ChunkInfo] = []
        let total = data.count
        var offset = 4 // skip global magic

        while offset + chunkHeaderSize <= total {
            guard data[offset + anchorOffset] == 0x02,
                  data[offset + anchorOffset + 1] == 0x00,
                  data[offset + anchorOffset + 2] == 0x00,
                  data[offset + anchorOffset + 3] == 0x00,
                  (data[offset + anchorOffset + 4] == 0x01
                    || data[offset + anchorOffset + 4] == 0x02),
                  data[offset + anchorOffset + 5] == 0x00
            else {
                offset += 1
                continue
            }

            let bodyLength = Int(readLE64(data, at: offset + lengthOffset))
            let bodyStart = offset + chunkHeaderSize

            guard bodyLength >= 0,
                  bodyStart + bodyLength <= total
            else {
                offset += 1
                continue
            }

            let rawID = Array(data[offset..<(offset + 4)])
            let id = reverseID(rawID)

            result.append(ChunkInfo(
                id: id,
                bodyOffset: bodyStart,
                bodyLength: bodyLength
            ))

            offset = bodyStart + bodyLength
        }
        return result
    }

    // MARK: - Private: Tempo strategies

    /// Standard `7F 00 00 01` tempo signature, mirrors `parseTempoEvents`.
    private static func parseStandardTempos(body: Data) -> [(tick: Int, bpm: Double)] {
        var entries: [(tick: Int, bpm: Double)] = []
        let bytes = Data(body) // rebase
        let total = bytes.count
        var offset = 0

        while offset + 20 <= total {
            guard bytes[offset] == 0x7F,
                  bytes[offset + 1] == 0x00,
                  bytes[offset + 2] == 0x00,
                  bytes[offset + 3] == 0x01
            else {
                offset += 1
                continue
            }

            let milliTempo = readLE32(bytes, at: offset + 4)
            guard milliTempo > 0 else { offset += 1; continue }

            let tickLow = readLE32(bytes, at: offset + 12)
            let tickHigh = readLE32(bytes, at: offset + 16)
            let tick = Int(tickLow) | (Int(tickHigh) << 32)

            let bpm = Double(milliTempo) / 10000.0
            guard bpm > 10.0 && bpm < 1000.0 else { offset += 4; continue }

            entries.append((tick: tick, bpm: bpm))
            offset += 20
        }
        return entries
    }

    /// Type-96 tempo bridge, mirrors `parseType96TempoEvents`.
    private static func parseType96Tempos(body: Data) -> [(tick: Int, bpm: Double)] {
        var entries: [(tick: Int, bpm: Double)] = []
        let bytes = Data(body)
        let count = bytes.count / 16
        guard count >= 2 else { return entries }

        var i = 0
        while i + 1 < count {
            let aOff = i * 16
            let bOff = (i + 1) * 16
            guard aOff + 16 <= bytes.count, bOff + 16 <= bytes.count else { break }

            let a0 = readLE32(bytes, at: aOff + 0)
            let a3 = readLE32(bytes, at: aOff + 12)
            guard a0 == 96,
                  (a3 == 0x0100007F || a3 == 0x8100007F)
            else {
                i += 1
                continue
            }

            let b0 = readLE32(bytes, at: bOff + 0)
            let b1 = readLE32(bytes, at: bOff + 4)
            let b2 = readLE32(bytes, at: bOff + 8)

            guard b1 == 0x88400000, b0 > 0 else {
                i += 1
                continue
            }

            let bpm = Double(b0) / 10000.0
            guard bpm > 10.0 && bpm < 1000.0 else {
                i += 1
                continue
            }

            entries.append((tick: Int(b2), bpm: bpm))
            i += 2
        }
        return entries
    }

    // MARK: - Private: Marker type-18 scan

    /// Return the `start_tick` of each type-18 triplet head, mirroring
    /// `parseType18Triplets`. We only need the head ticks here to compute the
    /// timeline offset.
    private static func parseType18MarkerTicks(body: Data) -> [Int] {
        var result: [Int] = []
        let bytes = Data(body)
        let count = bytes.count / 16
        guard count >= 3 else { return result }

        var i = 0
        while i + 2 < count {
            let headOffset = i * 16
            let markerOffset = (i + 1) * 16
            let tailOffset = (i + 2) * 16

            guard headOffset + 16 <= bytes.count,
                  markerOffset + 16 <= bytes.count,
                  tailOffset + 16 <= bytes.count
            else { break }

            let h0 = readLE32(bytes, at: headOffset + 0)
            let h1 = readLE32(bytes, at: headOffset + 4)
            let m1 = readLE32(bytes, at: markerOffset + 4)
            let t0 = readLE32(bytes, at: tailOffset + 0)
            let t1 = readLE32(bytes, at: tailOffset + 4)

            if h0 == 18
                && m1 == 0x88000000
                && t0 == 0
                && t1 == 0x88000000
            {
                result.append(Int(h1))
                i += 3
                continue
            }
            i += 1
        }
        return result
    }

    // MARK: - Private: Timeline offset

    /// Mirror of `ProjectDataParser.computeTimelineTickOffset`.
    ///
    /// If the smallest marker tick implies a bar > 200, assume it is a pre-roll
    /// offset and return it rounded down to the nearest bar boundary (keeping
    /// one bar of headroom before the first marker). Otherwise return 0.
    private static func computeTimelineTickOffset(
        markerStartTicks: [Int],
        ticksPerBar: Int
    ) -> Int {
        guard !markerStartTicks.isEmpty else { return 0 }
        let minTick = markerStartTicks.min() ?? 0
        guard minTick > 0 else { return 0 }

        let impliedBar = minTick / ticksPerBar + 1
        if impliedBar > 200 {
            let offsetBars = (minTick / ticksPerBar) - 1
            return max(0, offsetBars * ticksPerBar)
        }
        return 0
    }

    // MARK: - Private: Byte readers

    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private static func readLE64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[base + i]) << (i * 8)
        }
        return value
    }

    private static func reverseID(_ bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "????" }
        let reversed = bytes.reversed()
        let chars = reversed.compactMap { b -> Character? in
            let scalar = Unicode.Scalar(b)
            let ch = Character(scalar)
            return ch.isASCII && scalar.value >= 32 ? ch : nil
        }
        if chars.count < 4 { return "PluginData" }
        return String(chars)
    }
}

