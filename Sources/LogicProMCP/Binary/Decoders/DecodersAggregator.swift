import Foundation

// MARK: - Aggregated Decoder Result

/// Aggregated output of all 17 isolated decoders, produced in a single pass
/// over the ProjectData binary. Intended for callers that want the full
/// reverse-engineered picture without wiring decoders individually.
struct DecodedProjectData: Sendable {
    var auCOTypes: [AuCOTypeRecord]
    var auCOExtended: [AuCO204Decoder.AuCO204Record]
    var auCnRoutingEntries: [AuCnRoutingEntry]
    var auCnEnableTable: AuCnEnableTable?
    var auCUSends: [AuCUSendRecord]
    var txStStyles: [TxStRecord]
    var stylStyles: [StylRecord]
    var corMPorts: [CorMDecoder.CorMRecord]
    var hyprCatalogs: [HyprRecord]
    var scoreSets: [ScoreSet]
    var scoreSetRoots: [InstRecord]
    var trnsGlobals: [TrnsGlobals]
    var clipHeaders: [ClipVideDecoder.ClipRecord]
    var videHeaders: [ClipVideDecoder.VideRecord]
    var songGraphNodes: [SongNode]
    var songGraphAnchors: [MarkerBarAnchor]
    var pluginComponents: [PluginComponentDecoder.PluginComponent]
    var genMMarkerTitles: [ArrangementMarkerTitle]
    var sngORecords: [SngORecord]
    var txSqMarkers: [TxSqMarker]
}

// MARK: - Aggregator

enum DecodersAggregator {

    /// Run every decoder against the given `ProjectData` bytes.
    static func decodeAll(data: Data) -> DecodedProjectData {
        let (auCnEntries, auCnTable) = AuCnDecoder.decode(data: data)
        let (scoreSets, scoreSetRoots) = ScoreSetDecoder.decode(data: data)
        let (clips, vides) = ClipVideDecoder.decode(data: data)
        let (songNodes, songAnchors) = SongGraphDecoder.decode(data: data)

        return DecodedProjectData(
            auCOTypes:          AuCOTypeDecoder.decode(data: data),
            auCOExtended:       AuCO204Decoder.decode(data: data),
            auCnRoutingEntries: auCnEntries,
            auCnEnableTable:    auCnTable,
            auCUSends:          AuCUSendDecoder.decode(data: data),
            txStStyles:         TxStDecoder.decode(data: data),
            stylStyles:         StylDecoder.decode(data: data),
            corMPorts:          CorMDecoder.decode(data: data),
            hyprCatalogs:       HyprDecoder.decode(data: data),
            scoreSets:          scoreSets,
            scoreSetRoots:      scoreSetRoots,
            trnsGlobals:        TrnsDecoder.decode(data: data),
            clipHeaders:        clips,
            videHeaders:        vides,
            songGraphNodes:     songNodes,
            songGraphAnchors:   songAnchors,
            pluginComponents:   PluginComponentDecoder.decode(data: data),
            genMMarkerTitles:   GenMDecoder.decode(data: data),
            sngORecords:        SngODecoder.decode(data: data),
            txSqMarkers:        TxSqMarkerDecoder.decode(data: data)
        )
    }

    /// Build the unified bar-number API alongside the aggregated decode.
    static func decodeAllWithBarAPI(data: Data) -> (DecodedProjectData, BarNumberAPI) {
        return (decodeAll(data: data), BarNumberAPI.build(from: data))
    }
}
