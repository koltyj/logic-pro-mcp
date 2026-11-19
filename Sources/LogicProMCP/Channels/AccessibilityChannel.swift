import ApplicationServices
import Foundation

/// Channel that reads and mutates Logic Pro state via the macOS Accessibility API.
/// Primary channel for state queries (transport, tracks, mixer) and UI mutations
/// (clicking mute/solo buttons, reading fader values, etc.)
actor AccessibilityChannel: Channel {
    let id: ChannelID = .accessibility

    func start() async throws {
        // Verify AX trust. If not trusted, the process needs to be added to
        // System Preferences > Privacy & Security > Accessibility.
        let trusted = PermissionChecker.checkAccessibility()
        guard trusted else {
            throw AccessibilityError.notTrusted
        }
        guard ProcessUtils.isLogicProRunning else {
            Log.warn("Logic Pro not running at AX channel start", subsystem: "ax")
            return
        }
        Log.info("Accessibility channel started", subsystem: "ax")
    }

    func stop() async {
        Log.info("Accessibility channel stopped", subsystem: "ax")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard ProcessUtils.isLogicProRunning else {
            return .error("Logic Pro is not running")
        }

        switch operation {
        // MARK: - Transport reads
        case "transport.get_state":
            return getTransportState()

        // MARK: - Transport mutations
        case "transport.toggle_cycle":
            return toggleTransportButton(named: "Cycle")
        case "transport.toggle_metronome":
            return toggleTransportButton(named: "Metronome")
        case "transport.set_tempo":
            return setTempo(params: params)
        case "transport.set_cycle_range":
            return setCycleRange(params: params)

        // MARK: - Track reads
        case "track.get_tracks":
            return getTracks()
        case "track.get_selected":
            return getSelectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return selectTrack(params: params)
        case "track.set_mute":
            return setTrackToggle(params: params, button: "Mute")
        case "track.set_solo":
            return setTrackToggle(params: params, button: "Solo")
        case "track.set_arm":
            return setTrackToggle(params: params, button: "Record")
        case "track.rename":
            return renameTrack(params: params)
        case "track.set_color":
            return .error("Track color setting not supported via AX")

        // MARK: - Mixer reads
        case "mixer.get_state":
            return getMixerState()
        case "mixer.get_channel_strip":
            return getChannelStrip(params: params)

        // MARK: - Mixer mutations
        case "mixer.set_volume":
            return setMixerValue(params: params, target: .volume)
        case "mixer.set_pan":
            return setMixerValue(params: params, target: .pan)
        case "mixer.set_master_volume":
            return setMasterVolume(params: params)
        case "mixer.set_send":
            return .error("Send adjustment not yet implemented via AX")
        case "mixer.set_input", "mixer.set_output":
            return .error("I/O routing not yet implemented via AX")
        case "mixer.toggle_eq":
            return .error("EQ toggle not yet implemented via AX")
        case "mixer.reset_strip":
            return .error("Strip reset not yet implemented via AX")

        // MARK: - Navigation
        case "nav.get_markers":
            return .error("Marker reading not yet implemented via AX")
        case "nav.rename_marker":
            return .error("Marker renaming not yet implemented via AX")

        // MARK: - Project
        case "project.get_info":
            return getProjectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return .error("Region reading not yet implemented via AX")
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        case "plugin.list":
            return listPlugins(params: params)
        case "plugin.bypass":
            return await setPluginBypass(params: params)
        case "plugin.insert", "plugin.remove":
            return .error("Plugin insert/remove are not implemented via AX")

        // MARK: - Bounce
        case "project.bounce_export":
            return await AXBounce.run(params: params)

        // MARK: - Automation
        case "automation.get_mode":
            return .error("Automation mode reading not yet implemented via AX")
        case "automation.set_mode":
            return .error("Automation mode setting not yet implemented via AX")

        default:
            return .error("Unsupported AX operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard PermissionChecker.checkAccessibility() else {
            return .unavailable("Accessibility not trusted — add this process in System Preferences")
        }
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        // Quick smoke test: can we reach the app root?
        guard AXLogicProElements.appRoot() != nil else {
            return .unavailable("Cannot access Logic Pro AX element")
        }
        return .healthy(detail: "AX connected to Logic Pro")
    }

    // MARK: - Transport

    private func getTransportState() -> ChannelResult {
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        let state = AXValueExtractors.extractTransportState(from: transport)
        return encodeResult(state)
    }

    private func toggleTransportButton(named name: String) -> ChannelResult {
        guard let button = AXLogicProElements.findTransportButton(named: name) else {
            return .error("Cannot find transport button: \(name)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to press transport button: \(name)")
        }
        return .success("{\"toggled\":\"\(name)\"}")
    }

    private func setTempo(params: [String: String]) -> ChannelResult {
        guard let tempoStr = params["tempo"], let _ = Double(tempoStr) else {
            return .error("Missing or invalid 'tempo' parameter")
        }
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        // Find the tempo text field and set its value
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXTextFieldRole, maxDepth: 4)
        for field in texts {
            if AXLabels.tempo.isContained(in: AXHelpers.getDescription(field)) {
                AXHelpers.setAttribute(field, kAXValueAttribute, tempoStr as CFTypeRef)
                AXHelpers.performAction(field, kAXConfirmAction)
                return .success("{\"tempo\":\(tempoStr)}")
            }
        }
        return .error("Cannot locate tempo field")
    }

    private func setCycleRange(params: [String: String]) -> ChannelResult {
        // Cycle range setting via AX is fragile — requires locating the cycle locators
        guard let _ = params["start"], let _ = params["end"] else {
            return .error("Missing 'start' and/or 'end' parameters")
        }
        return .error("Cycle range setting not yet fully implemented via AX")
    }

    // MARK: - Tracks

    private func getTracks() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        if headers.isEmpty {
            return .error("No track headers found — is a project open?")
        }
        var tracks: [TrackState] = []
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(from: header, index: index)
            tracks.append(track)
        }
        return encodeResult(tracks)
    }

    private func getSelectedTrack() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        for (index, header) in headers.enumerated() {
            if AXValueExtractors.isTrackSelected(header) {
                let track = AXValueExtractors.extractTrackState(from: header, index: index)
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    private func selectTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index) else {
            return .error("Track at index \(index) not found")
        }
        guard AXHelpers.performAction(header, kAXPressAction) else {
            return .error("Failed to select track \(index)")
        }
        return .success("{\"selected\":\(index)}")
    }

    private func setTrackToggle(params: [String: String], button buttonName: String) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": AXLogicProElements.findTrackMuteButton
        case "Solo": AXLogicProElements.findTrackSoloButton
        case "Record": AXLogicProElements.findTrackArmButton
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to click \(buttonName) on track \(index)")
        }
        return .success("{\"track\":\(index),\"toggled\":\"\(buttonName)\"}")
    }

    private func renameTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }
        guard let field = AXLogicProElements.findTrackNameField(trackIndex: index) else {
            return .error("Cannot find name field for track \(index)")
        }
        // Double-click to enter edit mode, then set value
        AXHelpers.performAction(field, kAXPressAction)
        AXHelpers.setAttribute(field, kAXValueAttribute, name as CFTypeRef)
        AXHelpers.performAction(field, kAXConfirmAction)
        return .success("{\"track\":\(index),\"name\":\"\(name)\"}")
    }

    // MARK: - Mixer

    private enum MixerTarget {
        case volume
        case pan
    }

    private func getMixerState() -> ChannelResult {
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        let channelStrips = strips.enumerated().map { index, strip in
            Self.channelStripState(for: strip, index: index)
        }
        return encodeResult(channelStrips)
    }

    private func getChannelStrip(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        guard index >= 0 && index < strips.count else {
            return .error("Channel strip index \(index) out of range")
        }
        return encodeResult(Self.channelStripState(for: strips[index], index: index))
    }

    /// Read one channel strip. Shared by mixer.get_state and
    /// mixer.get_channel_strip so both resolve controls the same way.
    private static func channelStripState(for strip: AXUIElement, index: Int) -> ChannelStripState {
        let fader = AXLogicProElements.stripControl(
            strip, role: kAXSliderRole, description: AXLogicProElements.StripControl.volume
        )
        let panKnob = AXLogicProElements.stripControl(
            strip, role: kAXSliderRole, description: AXLogicProElements.StripControl.pan
        )
        let eqButton = AXLogicProElements.stripControl(
            strip, role: kAXButtonRole, description: AXLogicProElements.StripControl.eq
        )
        return ChannelStripState(
            trackIndex: index,
            name: AXHelpers.getDescription(strip),
            volume: fader.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0,
            pan: panKnob.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0,
            eqEnabled: AXLabels.onState.matches(
                eqButton.flatMap { AXHelpers.getAttribute($0, kAXValueAttribute) }
            ),
            plugins: AXLogicProElements.pluginSlots(in: strip).slots.map(Self.pluginState)
        )
    }

    private static func pluginState(_ slot: AXLogicProElements.PluginSlot) -> PluginSlotState {
        PluginSlotState(
            index: slot.index,
            name: slot.name,
            isBypassed: AXValueExtractors.extractCheckboxState(slot.bypassCheckbox) ?? false
        )
    }

    // MARK: - Plugins

    private func listPlugins(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["track_index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'track_index' parameter")
        }
        guard AXLogicProElements.getMixerArea() != nil else {
            return .error("Cannot locate mixer — open the Mixer window (X) first")
        }
        guard let strip = AXLogicProElements.mixerStrip(at: index) else {
            return .error("Channel strip index \(index) out of range")
        }
        let found = AXLogicProElements.pluginSlots(in: strip)
        if found.slots.isEmpty && found.hiddenCount > 0 {
            return .error(Self.hiddenSlotsMessage(index: index, count: found.hiddenCount))
        }
        return encodeResult(found.slots.map(Self.pluginState))
    }

    private static func hiddenSlotsMessage(index: Int, count: Int) -> String {
        "Strip \(index) has \(count) plugin slot(s), but the insert area is collapsed so Logic " +
            "does not expose their names or bypass state. Enlarge the Mixer (e.g. open it as a " +
            "window with Cmd+2) so the inserts are visible."
    }

    private func setPluginBypass(params: [String: String]) async -> ChannelResult {
        guard let indexStr = params["track_index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'track_index' parameter")
        }
        guard let slotStr = params["slot"], let slotIndex = Int(slotStr) else {
            return .error("Missing or invalid 'slot' parameter")
        }
        guard let desired = params["bypassed"].flatMap(Bool.init) else {
            return .error("Missing or invalid 'bypassed' parameter")
        }
        guard AXLogicProElements.getMixerArea() != nil else {
            return .error("Cannot locate mixer — open the Mixer window (X) first")
        }
        guard let strip = AXLogicProElements.mixerStrip(at: index) else {
            return .error("Channel strip index \(index) out of range")
        }
        let found = AXLogicProElements.pluginSlots(in: strip)
        if found.slots.isEmpty && found.hiddenCount > 0 {
            return .error(Self.hiddenSlotsMessage(index: index, count: found.hiddenCount))
        }
        let slots = found.slots
        guard slots.indices.contains(slotIndex) else {
            return .error("Strip \(index) has \(slots.count) loaded plugin(s); slot \(slotIndex) does not exist")
        }
        let slot = slots[slotIndex]
        guard let current = AXValueExtractors.extractCheckboxState(slot.bypassCheckbox) else {
            return .error("Cannot read bypass state of \(slot.name); not toggling blind")
        }
        if current != desired {
            guard AXHelpers.performAction(slot.bypassCheckbox, kAXPressAction) else {
                return .error("Failed to press bypass on \(slot.name)")
            }
        }
        // Logic updates the checkbox's AXValue asynchronously after a press;
        // reading it straight away returns the old state.
        let settled = await AXHelpers.poll(seconds: 2) {
            AXValueExtractors.extractCheckboxState(slot.bypassCheckbox) == desired ? true : nil
        }
        guard settled != nil else {
            return .error("Bypass on \(slot.name) did not change to \(desired)")
        }
        return encodeResult(PluginSlotState(index: slot.index, name: slot.name, isBypassed: desired))
    }

    private func setMixerValue(params: [String: String], target: MixerTarget) -> ChannelResult {
        guard let indexStr = params["track"], let index = Int(indexStr),
              let valueStr = params["value"], let value = Double(valueStr) else {
            return .error("Missing 'track' or 'value' parameter")
        }
        let element: AXUIElement?
        switch target {
        case .volume:
            element = AXLogicProElements.findFader(trackIndex: index)
        case .pan:
            element = AXLogicProElements.findPanKnob(trackIndex: index)
        }
        guard let slider = element else {
            return .error("Cannot find \(target) control for track \(index)")
        }
        AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: value))
        let label = target == .volume ? "volume" : "pan"
        return .success("{\"\(label)\":\(value),\"track\":\(index)}")
    }

    private func setMasterVolume(params: [String: String]) -> ChannelResult {
        guard let valueStr = params["value"], let value = Double(valueStr) else {
            return .error("Missing or invalid 'value' parameter")
        }
        guard let slider = AXLogicProElements.findMasterFader() else {
            return .error("Cannot find master volume control")
        }
        guard AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: value)) else {
            return .error("Failed to set master volume control")
        }
        return .success("{\"master_volume\":\(value)}")
    }

    // MARK: - Project

    private func getProjectInfo() -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow() else {
            return .error("Cannot locate Logic Pro main window")
        }
        let title = AXHelpers.getTitle(window) ?? "Unknown"
        var info = ProjectInfo()
        info.name = title
        info.lastUpdated = Date()
        return encodeResult(info)
    }

    // MARK: - JSON encoding

    private func encodeResult<T: Encodable>(_ value: T) -> ChannelResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode result to UTF-8")
            }
            return .success(json)
        } catch {
            return .error("JSON encoding failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum AccessibilityError: Error, CustomStringConvertible {
    case notTrusted

    var description: String {
        switch self {
        case .notTrusted:
            return "Process is not trusted for Accessibility. Add it in System Preferences > Privacy & Security > Accessibility."
        }
    }
}
