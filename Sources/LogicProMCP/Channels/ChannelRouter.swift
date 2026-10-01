import Foundation

/// Routes tool operations to the appropriate channel with fallback chains.
///
/// Each tool operation has a primary channel and optional fallbacks.
/// If the primary channel fails or is unavailable, the router tries
/// each fallback in order.
actor ChannelRouter {
    private var channels: [ChannelID: any Channel] = [:]
    private var dialogProbe: (@Sendable () async -> String?)?

    /// Installs the check run before every state-changing operation.
    func setDialogProbe(_ probe: @escaping @Sendable () async -> String?) {
        dialogProbe = probe
    }

    /// Static routing table: operation → ordered list of channels to try.
    /// Operations are prefixed by category (e.g., "transport.play", "track.mute").
    private static let routingTable: [String: [ChannelID]] = [
        // Transport — MMC via CoreMIDI, fallback to keyboard, then AppleScript
        "transport.play":             [.accessibility, .cgEvent],
        "transport.stop":             [.accessibility, .cgEvent],
        "transport.record":           [.accessibility, .cgEvent],
        "transport.pause":            [.coreMIDI, .cgEvent, .appleScript],
        "transport.rewind":           [.coreMIDI, .cgEvent],
        "transport.fast_forward":     [.coreMIDI, .cgEvent],
        "transport.toggle_cycle":     [.accessibility, .cgEvent],
        "transport.toggle_metronome": [.accessibility, .cgEvent],
        "transport.toggle_count_in":  [.accessibility],
        "transport.set_tempo":        [.accessibility, .osc],
        "transport.get_state":        [.accessibility],
        "transport.goto_position":    [.accessibility, .cgEvent],
        "transport.set_cycle_range":  [.accessibility],

        // Track state reading
        "track.get_tracks":           [.accessibility],
        "track.get_selected":         [.accessibility],

        // Track mutation — AX click, fallback to keyboard
        "track.select":               [.accessibility, .cgEvent],
        "track.create_audio":         [.accessibility, .cgEvent],
        "track.create_instrument":    [.accessibility, .cgEvent],
        "track.create_drummer":       [.cgEvent, .accessibility],
        "track.create_external_midi": [.accessibility, .cgEvent],
        "track.set_input_monitoring": [.accessibility],
        "track.delete":               [.accessibility, .cgEvent],
        "track.rename":               [.accessibility],
        "track.set_mute":             [.accessibility, .cgEvent],
        "track.set_solo":             [.accessibility, .cgEvent],
        "track.set_arm":              [.accessibility, .cgEvent],
        "track.duplicate":            [.cgEvent],
        "track.set_color":            [.accessibility],

        // Mixer — OSC primary for continuous, AX fallback
        "mixer.get_state":            [.accessibility],
        "mixer.set_volume":           [.osc, .accessibility],
        "mixer.set_pan":              [.osc, .accessibility],
        "mixer.set_send":             [.osc, .accessibility],
        "mixer.set_output":           [.accessibility],
        "mixer.set_input":            [.accessibility],
        "mixer.get_channel_strip":    [.accessibility],
        "mixer.set_master_volume":    [.accessibility],
        "mixer.set_output_volume":    [.osc, .accessibility],
        "mixer.get_bus_routing":      [.accessibility],
        "mixer.toggle_eq":            [.accessibility],
        "mixer.reset_strip":          [.accessibility],

        // MIDI — CoreMIDI only
        "midi.send_note":             [.coreMIDI],
        "midi.send_chord":            [.coreMIDI],
        "midi.send_cc":               [.coreMIDI],
        "midi.send_program_change":   [.coreMIDI],
        "midi.send_pitch_bend":       [.coreMIDI],
        "midi.send_aftertouch":       [.coreMIDI],
        "midi.send_sysex":            [.coreMIDI],
        "midi.list_ports":            [.coreMIDI],
        "midi.create_virtual_port":   [.coreMIDI],

        // MMC
        "mmc.play":                   [.coreMIDI],
        "mmc.stop":                   [.coreMIDI],
        "mmc.record_strobe":          [.coreMIDI],
        "mmc.record_exit":            [.coreMIDI],
        "mmc.locate":                 [.coreMIDI],
        "mmc.pause":                  [.coreMIDI],

        // Navigation — keyboard primary, AX menu fallback
        "nav.goto_bar":               [.cgEvent, .accessibility],
        "nav.goto_marker":            [.cgEvent, .accessibility],
        "nav.create_marker":          [.cgEvent],
        "nav.delete_marker":          [.cgEvent, .accessibility],
        "nav.rename_marker":          [.accessibility],
        "nav.get_markers":            [.accessibility],
        "nav.zoom_to_fit":            [.cgEvent],
        "nav.set_zoom_level":         [.cgEvent],

        // Editing — keyboard primary
        "edit.undo":                  [.accessibility],
        "edit.redo":                  [.accessibility],
        "edit.cut":                   [.cgEvent],
        "edit.copy":                  [.cgEvent],
        "edit.paste":                 [.cgEvent],
        "edit.delete":                [.accessibility],
        "edit.select_all":            [.accessibility],
        "edit.split":                 [.cgEvent],
        "edit.join":                  [.cgEvent, .accessibility],
        "edit.quantize":              [.cgEvent, .accessibility],
        "edit.bounce_in_place":       [.cgEvent, .accessibility],
        "edit.normalize":             [.cgEvent, .accessibility],

        // Project — AppleScript for lifecycle, keyboard for save/bounce
        "project.new":                [.appleScript],
        "project.open":               [.accessibility],
        "project.save":               [.accessibility, .cgEvent, .appleScript],
        "project.save_as":            [.appleScript],
        "project.close":              [.accessibility],
        "project.get_info":           [.accessibility],
        "project.bounce":             [.cgEvent, .accessibility],
        "project.is_running":         [],  // No channel needed — pure process check

        // Views — keyboard toggle
        "view.toggle_mixer":          [.cgEvent, .accessibility],
        "view.toggle_piano_roll":     [.cgEvent, .accessibility],
        "view.toggle_score_editor":   [.cgEvent, .accessibility],
        "view.toggle_step_editor":    [.cgEvent, .accessibility],
        "view.toggle_library":        [.cgEvent, .accessibility],
        "view.toggle_inspector":      [.cgEvent, .accessibility],

        // Regions
        "region.clear_all":           [.accessibility],
        "region.get_regions":         [.accessibility],
        "region.select":              [.accessibility],
        "region.loop":                [.accessibility, .cgEvent],
        "region.set_name":            [.accessibility],
        "region.move":                [.accessibility],
        "region.resize":              [.accessibility],

        // Plugins
        "plugin.list":                [.accessibility],
        "plugin.insert":              [.accessibility],
        "plugin.bypass":              [.accessibility],
        "plugin.remove":              [.accessibility],

        // Automation
        "automation.get_mode":        [.accessibility],
        "automation.set_mode":        [.accessibility, .cgEvent],
        "automation.toggle_view":     [.cgEvent, .accessibility],
        "automation.get_parameter":   [.accessibility],

        // System — no channel needed
        "dialog.state":               [.accessibility],
        "dialog.respond":             [.accessibility],

        "system.health":              [],
        "system.cache_state":         [],
        "system.refresh":             [],
        "system.permissions":         [],
    ]

    // MARK: - Lifecycle

    func register(_ channel: any Channel) {
        channels[channel.id] = channel
    }

    func startAll() async {
        for (id, channel) in channels {
            do {
                try await channel.start()
                Log.info("Channel \(id.rawValue) started", subsystem: "router")
            } catch {
                Log.warn("Channel \(id.rawValue) failed to start: \(error)", subsystem: "router")
            }
        }
    }

    func stopAll() async {
        for (_, channel) in channels {
            await channel.stop()
        }
    }

    // MARK: - Routing

    /// Route an operation through its fallback chain.
    /// Returns the result from the first channel that succeeds.
    func route(operation: String, params: [String: String] = [:]) async -> ChannelResult {
        guard let chain = Self.routingTable[operation] else {
            return .error("Unknown operation: \(operation)")
        }

        // Logic ignores (or queues) input behind a modal dialog, so fail fast with what it's asking.
        let isRead = operation.contains(".get_") || operation.hasPrefix("dialog.")
        if !isRead, !chain.isEmpty, let dialogProbe, let dialog = await dialogProbe() {
            return .error("Blocked by Logic dialog: \(dialog). Answer it with logic_system dialog_respond {button}.")
        }

        // Operations with empty chain don't need a channel
        if chain.isEmpty {
            return .success("No channel required for \(operation)")
        }

        var errors: [String] = []

        for channelID in chain {
            guard let channel = channels[channelID] else {
                Log.debug("Channel \(channelID.rawValue) not registered, skipping", subsystem: "router")
                continue
            }

            let health = await channel.healthCheck()
            guard health.available else {
                Log.debug("Channel \(channelID.rawValue) unhealthy: \(health.detail), trying next", subsystem: "router")
                errors.append("\(channelID.rawValue): \(health.detail)")
                continue
            }

            let result = await channel.execute(operation: operation, params: params)
            switch result {
            case .success:
                Log.debug("\(operation) succeeded via \(channelID.rawValue)", subsystem: "router")
                return result
            case .unverified:
                Log.debug("\(operation) was sent via \(channelID.rawValue) without Logic readback", subsystem: "router")
                return result
            case .failedAfterActing(let msg):
                Log.debug("\(operation) acted via \(channelID.rawValue) but was not confirmed: \(msg)", subsystem: "router")
                return result
            case .error(let msg):
                Log.debug("\(operation) failed via \(channelID.rawValue): \(msg), trying next", subsystem: "router")
                errors.append("\(channelID.rawValue): \(msg)")
            }
        }

        let detail = errors.isEmpty ? "No channels available" : errors.joined(separator: " | ")
        return .error("All channels exhausted for \(operation). \(detail)")
    }

    /// Get health status for all registered channels.
    func healthReport() async -> [ChannelID: ChannelHealth] {
        var report: [ChannelID: ChannelHealth] = [:]
        for (id, channel) in channels {
            report[id] = await channel.healthCheck()
        }
        return report
    }
}
