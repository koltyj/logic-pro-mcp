import Foundation
import MCP

struct SystemDispatcher {
    static let tool = Tool(
        name: "logic_system",
        description: """
            Diagnostics and help for the Logic Pro MCP server. \
            Commands: health, permissions, refresh_cache, help. \
            Params by command: \
            help -> { category: String } (returns full param docs for a dispatcher); \
            refresh_cache -> {} (force AX re-poll); \
            Others -> {}
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("System command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "health":
            let report = await router.healthReport()
            var entries: [[String: String]] = []
            for (id, health) in report.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                entries.append([
                    "channel": id.rawValue,
                    "available": String(health.available),
                    "latency_ms": health.latencyMs.map { String(format: "%.1f", $0) } ?? "N/A",
                    "detail": health.detail,
                ])
            }
            let snap = await cache.snapshot()
            let cacheInfo: [String: String] = [
                "poll_mode": snap.pollMode,
                "transport_age_sec": String(format: "%.1f", snap.transportAge),
                "track_count": String(snap.trackCount),
                "project": snap.projectName,
            ]
            // Manual JSON since mixed types
            let channelsJSON = encodeJSON(entries)
            let cacheJSON = encodeJSON(cacheInfo)
            let json = """
                {
                  "logic_pro_running": \(ProcessUtils.isLogicProRunning),
                  "channels": \(channelsJSON),
                  "cache": \(cacheJSON)
                }
                """
            return CallTool.Result(content: [.text(json)], isError: false)

        case "permissions":
            let status = PermissionChecker.check()
            return CallTool.Result(content: [.text(status.summary)], isError: false)

        case "refresh_cache":
            await cache.recordToolAccess()
            return CallTool.Result(
                content: [.text("State refresh triggered. Cache will be updated on next poll cycle.")],
                isError: false
            )

        case "help":
            let category = params["category"]?.stringValue ?? "all"
            let helpText = Self.helpText(for: category)
            return CallTool.Result(content: [.text(helpText)], isError: false)

        default:
            return CallTool.Result(
                content: [.text("Unknown system command: \(command). Available: health, permissions, refresh_cache, help")],
                isError: true
            )
        }
    }

    // MARK: - Help text

    private static func helpText(for category: String) -> String {
        switch category {
        case "transport":
            return """
                logic_transport commands:
                  play              -> {} — Start playback
                  stop              -> {} — Stop playback
                  record            -> {} — Start recording
                  pause             -> {} — Pause playback
                  rewind            -> {} — Rewind
                  fast_forward      -> {} — Fast forward
                  toggle_cycle      -> {} — Toggle cycle/loop mode
                  toggle_metronome  -> {} — Toggle metronome
                  toggle_count_in   -> {} — Toggle count-in
                  set_tempo         -> { tempo: Float } — Set BPM (20-999)
                  goto_position     -> { bar: Int } or { time: "HH:MM:SS:FF" }
                  set_cycle_range   -> { start: Int, end: Int } — Bar numbers

                Read state via resource: logic://transport/state
                """

        case "tracks":
            return """
                logic_tracks commands:
                  select            -> { index: Int } or { name: String }
                  create_audio      -> {} — New audio track
                  create_instrument -> {} — New software instrument track
                  create_drummer    -> {} — New Drummer track
                  create_external_midi -> {} — New external MIDI track
                  delete            -> { index: Int }
                  duplicate         -> { index: Int }
                  rename            -> { index: Int, name: String }
                  mute              -> { index: Int, enabled: Bool }
                  solo              -> { index: Int, enabled: Bool }
                  arm               -> { index: Int, enabled: Bool }
                  set_color         -> { index: Int, color: Int } (0-24)

                Read state via resources: logic://tracks, logic://tracks/{index}
                """

        case "mixer":
            return """
                logic_mixer commands:
                  set_volume        -> { track: Int, value: Float } (0.0-1.0)
                  set_pan           -> { track: Int, value: Float } (-1.0 to 1.0)
                  set_send          -> { track: Int, bus: Int, value: Float }
                  set_output        -> { track: Int, output: String }
                  set_input         -> { track: Int, input: String }
                  set_master_volume -> { value: Float }
                  toggle_eq         -> { track: Int }
                  reset_strip       -> { track: Int }
                  insert_plugin     -> { track: Int, slot: Int, name: String }
                  bypass_plugin     -> { track: Int, slot: Int, bypassed: Bool }

                Read state via resource: logic://mixer
                """

        case "midi":
            return """
                logic_midi commands:
                  send_note         -> { note: Int, velocity: Int, channel: Int, duration_ms: Int }
                  send_chord        -> { notes: [Int], velocity: Int, channel: Int, duration_ms: Int }
                  send_cc           -> { controller: Int, value: Int, channel: Int }
                  send_program_change -> { program: Int, channel: Int }
                  send_pitch_bend   -> { value: Int, channel: Int } (-8192 to 8191)
                  send_aftertouch   -> { value: Int, channel: Int }
                  send_sysex        -> { bytes: [Int] } or { data: String }
                  create_virtual_port -> { name: String }
                  mmc_play          -> {}
                  mmc_stop          -> {}
                  mmc_record        -> {}
                  mmc_locate        -> { time: "HH:MM:SS:FF" }

                Read ports via resource: logic://midi/ports
                """

        case "edit":
            return """
                logic_edit commands:
                  undo              -> {} — Undo last action
                  redo              -> {} — Redo last undone action
                  cut               -> {} — Cut selection
                  copy              -> {} — Copy selection
                  paste             -> {} — Paste at playhead
                  delete            -> {} — Delete selection
                  select_all        -> {} — Select all
                  split             -> {} — Split at playhead
                  join              -> {} — Join selected regions
                  quantize          -> { value: String } ("1/4", "1/8", "1/16")
                  bounce_in_place   -> {} — Bounce selection to audio
                  normalize         -> {} — Normalize audio
                  duplicate         -> {} — Duplicate selection
                """

        case "navigate":
            return """
                logic_navigate commands:
                  goto_bar          -> { bar: Int }
                  goto_marker       -> { index: Int } or { name: String }
                  create_marker     -> { name: String }
                  delete_marker     -> { index: Int }
                  rename_marker     -> { index: Int, name: String }
                  zoom_to_fit       -> {}
                  set_zoom          -> { level: String } ("in", "out", "fit")
                  toggle_view       -> { view: String } (mixer, piano_roll, score,
                                       step_editor, library, inspector, automation)
                """

        case "project":
            return """
                logic_project commands:
                  new               -> {} — Create new project
                  open              -> { path: String } — Open .logicx file
                  save              -> {} — Save current project
                  save_as           -> { path: String } — Save to new path
                  close             -> {} — Close project
                  bounce            -> {} — Open bounce dialog
                  launch            -> {} — Launch Logic Pro
                  quit              -> {} — Quit Logic Pro

                Read project info via resource: logic://project/info
                """

        case "system":
            return """
                logic_system commands:
                  health            -> {} — Channel status + cache info
                  permissions       -> {} — macOS permission status
                  refresh_cache     -> {} — Force AX re-poll
                  help              -> { category: String } — Param docs per category

                Categories: transport, tracks, mixer, midi, edit, navigate, project, system

                Read health via resource: logic://system/health
                """

        default:
            return """
                Logic Pro MCP — 8 dispatcher tools + 7 resources

                Tools (actions):
                  logic_transport  — Transport control (play, stop, record, tempo...)
                  logic_tracks     — Track management (create, mute, solo, arm...)
                  logic_mixer      — Mixer control (volume, pan, plugins...)
                  logic_midi       — MIDI operations (notes, CC, MMC...)
                  logic_edit       — Editing (undo, cut, quantize...)
                  logic_navigate   — Navigation + views (markers, zoom, toggle views...)
                  logic_project    — Project lifecycle (open, save, bounce...)
                  logic_system     — Diagnostics + help

                Resources (reads — zero tool cost):
                  logic://transport/state  — Transport state
                  logic://tracks           — All tracks
                  logic://tracks/{index}   — Single track detail
                  logic://mixer            — Mixer state
                  logic://project/info     — Project info
                  logic://midi/ports       — MIDI ports
                  logic://system/health    — System health

                Use: logic_system(command: "help", params: {category: "transport"})
                for detailed command docs per category.
                """
        }
    }
}
