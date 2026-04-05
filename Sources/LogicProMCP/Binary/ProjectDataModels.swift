import Foundation

// MARK: - Top-level result

/// Full parsed result from a Logic Pro ProjectData binary file.
struct ProjectDataInfo: Sendable, Codable {
    /// Arrangement markers with names and bar positions.
    var markers: [ParsedMarker] = []
    /// Tempo map entries (may have multiple for tempo changes).
    var tempoMap: [TempoEntry] = []
    /// Track names extracted from MSeq chunks, enriched with optional mixer data.
    /// Includes all named tracks plus stack container tracks (even "Untitled" ones with children).
    var tracks: [ParsedTrack] = []
    /// All MSeq tracks including internal/automation tracks. For debugging and hierarchy building.
    var allTracks: [ParsedTrack] = []
    /// Audio regions parsed from AuRg chunks.
    var regions: [ParsedRegion] = []
    /// Audio file references parsed from AuFl chunks.
    var audioFiles: [ParsedAudioFile] = []
    /// Plugin names discovered in PluginData (null-ID) chunks.
    var plugins: [String] = []
    /// Detailed plugin records with type and manufacturer info.
    var parsedPlugins: [ParsedPlugin] = []
    /// Time signature string (e.g. "4/4"), sourced from plists in the package.
    var timeSignature: String = "4/4"
    /// Sample rate from project plist (0 if unavailable).
    var sampleRate: Int = 0
    /// Project name derived from the .logicx directory name.
    var projectName: String = ""

    // MARK: Extended hierarchy fields

    /// All AuCO channel strips extracted from the project (every guitar, vocal, synth, etc.).
    /// These are the definitive sub-track enumeration — Logic shows 449 strips vs 13 MSeq tracks.
    var channelStrips: [ChannelStrip] = []
    /// Arrangement tracks from Trak chunks, each linked to an MSeq OID.
    var trakEntries: [TrakEntry] = []
    /// Environment object names from Envi chunks (stack grouping labels like
    /// "Backing Track", "Click Track", "Release Track", "Midi Triggers").
    var environmentLabels: [String] = []
    /// Full sub-track hierarchy grouped by function group / environment label.
    /// Each entry is a top-level stack with its channel strip children.
    var subTrackHierarchy: [SubTrackStack] = []

    /// Per-song lengths derived from the reference track regions (or marker boundaries as fallback).
    var songLengths: [SongLength] = []
}

// MARK: - Channel Strip

/// An AuCO channel strip — the definitive representation of an individual track in Logic Pro.
/// Logic's mixer has one channel strip per real track (guitar DI, vocal take, synth layer, etc.)
/// whereas MSeq only stores the top-level arrangement containers.
struct ChannelStrip: Sendable, Codable {
    /// Channel strip name (null-terminated ASCII at AuCO body offset 0x3C).
    /// Examples: "Gtr Clean DI", "Lead Vox", "Rhodes", "Audio 47".
    var name: String
    /// Object identifier from the AuCO chunk header.
    var oid: Int
    /// Volume in dBFS (40 * log10(raw / 1509949440)). Nil when not decodable.
    var volume: Double?
    /// Pan position: -1.0 = hard left, 0.0 = center, +1.0 = hard right. Nil when not decodable.
    var pan: Double?
    /// Output routing label (e.g. "Bus 3", "Output 1-2", "Stereo Out").
    var outputRouting: String?
    /// Inferred function group (e.g. "Guitars", "Vocals", "Drums", "Keys/Synths").
    var functionGroup: String?
    /// True when the name is a generic placeholder (e.g. "Audio 47", "Inst 3").
    var isGeneric: Bool = false
    /// OID of the associated Trak chunk (when found by OID proximity matching).
    var trakOid: Int?
    /// OID of the MSeq sequence this strip links to (via Trak → MSeq chain).
    var mseqOid: Int?
}

// MARK: - Trak Entry

/// An arrangement track from a Trak chunk. Links to an MSeq sequence via mseqOid.
struct TrakEntry: Sendable, Codable {
    /// Object identifier from the Trak chunk header.
    var oid: Int
    /// OID of the MSeq sequence this track references (at body offset 0x08).
    var mseqOid: Int
    /// UUID bytes formatted as standard UUID string (body offset 0x18, 16 bytes).
    var uuid: String?
    /// Flags raw value (body offset 0x28, 4 bytes).
    var flagsRaw: UInt32
}

// MARK: - Sub-track Hierarchy

/// A top-level stack grouping channel strips by function group / environment label.
struct SubTrackStack: Sendable, Codable {
    /// Stack name (e.g. "Guitars", "Vocals", "Backing Track", "Click Track").
    var name: String
    /// Source of this grouping: "environment_label", "function_group", or "inferred".
    var source: String
    /// Channel strips assigned to this stack.
    var strips: [ChannelStrip]
}

// MARK: - Arrangement Markers

/// An arrangement marker parsed from TxSq (name) and EvSq type-18 (position).
struct ParsedMarker: Sendable, Codable {
    /// Human-readable marker name (RTF-stripped).
    var name: String
    /// Bar number (1-based). Computed from tick / 3840 + 1 in 4/4.
    var bar: Int
    /// Absolute tick position.
    var tick: Int
    /// Duration in ticks (from the type-18 row).
    var durationTicks: Int
    /// Duration in bars (durationTicks / 3840, rounded).
    var durationBars: Int
    /// Object identifier from the TxSq chunk header.
    var oid: Int
}

// MARK: - Tempo Map

/// A single tempo entry from an EvSq chunk.
struct TempoEntry: Sendable, Codable {
    /// Beats per minute.
    var bpm: Double
    /// Absolute tick position of this tempo event.
    var tick: Int
    /// Bar number (1-based), computed from tick / 3840 + 1.
    var bar: Int
}

// MARK: - Tracks

/// A track name parsed from an MSeq chunk, optionally enriched with mixer data,
/// hierarchy information, and function group classification.
struct ParsedTrack: Sendable, Codable {
    /// Track name (ASCII).
    var name: String
    /// Object identifier from the MSeq chunk header.
    var oid: Int
    /// Output routing label extracted from a nearby AuCO chunk (e.g. "Output 1-2", "Bus 1").
    var outputRouting: String?
    /// Volume in dBFS. Nil when AuCO is unavailable for this track.
    var volume: Double?
    /// Pan position in the range -1.0 (hard left) to +1.0 (hard right). Nil when unavailable.
    var pan: Double?
    /// Regions assigned to this track (populated by track-to-region mapping pass).
    var regions: [ParsedRegion] = []

    // MARK: Hierarchy fields

    /// OID of this track's parent stack (nil = top-level track).
    var parentOid: Int?
    /// OIDs of direct child tracks in this stack.
    var childOids: [Int] = []
    /// Depth in the track hierarchy (0 = root level, 1 = direct child of stack, etc.).
    var stackDepth: Int = 0
    /// Stack classification: "summing", "folder", or nil for regular tracks.
    var stackType: String?
    /// True when this track is a summing stack (routes to a bus and has children).
    var isSummingStack: Bool = false

    // MARK: Function group fields

    /// Inferred function group label (e.g. "Guitars", "Vocals", "Drums").
    /// Nil for tracks that could not be classified.
    var functionGroup: String?
}

// MARK: - Regions

/// An audio region parsed from an AuRg chunk.
struct ParsedRegion: Sendable, Codable {
    /// Region name (ASCII, e.g. "Rec#03.31").
    var name: String
    /// Object identifier from the AuRg chunk header.
    var oid: Int
    /// Absolute start position in ticks (derived from bar-field or legacy mode).
    var startTick: Int
    /// Start position in bars (1-based, fractional).
    var startBar: Double
    /// Duration in ticks.
    var lengthTicks: Int
    /// Duration in bars (fractional).
    var lengthBars: Double
    /// OID of the corresponding AuFl (audio file) chunk.
    var audioFileOid: Int
    /// Track OID that owns this region (populated by track-to-region mapping pass).
    var trackOid: Int?
}

// MARK: - Audio File References

/// An audio file reference parsed from an AuFl chunk.
struct ParsedAudioFile: Sendable, Codable {
    /// Absolute path to the audio file (UTF-16LE decoded from chunk body).
    var path: String
    /// Object identifier from the AuFl chunk header.
    var oid: Int
}

// MARK: - Song Lengths

/// Per-song length record derived from reference track regions or marker boundaries.
struct SongLength: Sendable, Codable {
    /// Song / arrangement marker name (e.g. "Dead and Buried").
    var songName: String
    /// Start bar (1-based, inclusive).
    var startBar: Int
    /// End bar (1-based, exclusive — first bar of the next song).
    var endBar: Int
    /// Length in whole bars (endBar - startBar).
    var lengthBars: Int
    /// How this length was determined:
    ///   "reference_region"  — taken from a matching reference track region
    ///   "marker_boundary"   — marker-to-next-marker fallback
    var source: String
}

// MARK: - Plugins

/// A plugin discovered in the project binary.
struct ParsedPlugin: Sendable, Codable {
    /// Plugin name (e.g. "Channel EQ", "Serum", "FabFilter Pro-Q 3").
    var name: String
    /// Plugin type: "au_builtin", "au_thirdparty", "au_component", or "unknown".
    var type: String
    /// Manufacturer name when available (e.g. "Apple", "FabFilter", "Xfer Records").
    var manufacturer: String?
    /// AU component 4-char codes when found: (type, subtype, manufacturer).
    var auComponentCode: String?
}
