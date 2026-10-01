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
        // Logic 12 has no Stop button: Play toggles, so stop = Play off.
        case "transport.play":
            return setTransportButton("Play", to: true)
        case "transport.stop":
            return await stopTransport()
        case "transport.record":
            return setTransportButton("Record", to: true, timeout: 60)
        case "transport.toggle_cycle":
            return toggleTransportButton(named: "Cycle")
        case "transport.toggle_metronome":
            return toggleTransportButton(named: "Metronome Click")
        case "transport.toggle_count_in":
            return toggleTransportButton(named: "Count In")
        case "transport.set_tempo":
            return setTempo(params: params)
        case "transport.goto_position":
            return gotoBar(params: params)
        case "transport.set_cycle_range":
            return setCycleRange(params: params)

        // MARK: - Track reads
        case "track.get_tracks":
            return getTracks()
        case "track.get_selected":
            return getSelectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return await selectTrack(params: params)
        case "track.set_mute":
            return await setTrackToggle(params: params, button: "Mute")
        case "track.set_solo":
            return await setTrackToggle(params: params, button: "Solo")
        case "track.set_arm":
            return await setTrackToggle(params: params, button: "Record")
        case "track.rename":
            return await renameTrack(params: params)
        case "track.delete":
            return deleteSelectedTrack()
        case "track.set_input_monitoring":
            return await setTrackToggle(params: params, button: "Input Monitoring")
        case "track.create_audio":
            return createTrack(menuItem: "New Audio Track")
        case "track.create_instrument":
            return createTrack(menuItem: "New Software Instrument Track")
        case "track.create_external_midi":
            return createTrack(menuItem: "New External MIDI Track")
        case "edit.undo":
            return pressEditMenuItem(prefix: "Undo")
        case "edit.redo":
            return pressEditMenuItem(prefix: "Redo")
        case "region.clear_all":
            return clearAllRegions()
        case "edit.select_all":
            return pressMenuItem(["Edit", "Select All"])
        case "edit.delete":
            return pressMenuItem(["Edit", "Delete"], expectUndo: true)
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
        case "dialog.state":
            return .success(AXLogicProElements.openDialogSummary() ?? "{\"open\":false}")
        case "dialog.respond":
            return respondToDialog(params: params)
        case "project.save":
            return saveProject()
        case "project.open":
            return openProject(params: params)
        case "project.close":
            return closeProject()
        case "project.get_info":
            return getProjectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return .error("Region reading not yet implemented via AX")
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        case "plugin.list", "plugin.insert", "plugin.bypass", "plugin.remove":
            return .error("Plugin operations not yet implemented via AX")

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
        guard let button = AXLogicProElements.findTransportButton(named: name),
              let current = AXValueExtractors.extractCheckboxState(button) else {
            return .error("Cannot find transport button: \(name)")
        }
        return setTransportButton(name, to: !current)
    }

    /// Presses a control bar toggle only if it isn't already in `desired`, then confirms it.
    /// Control bar buttons honor AXPress (unlike track header controls).
    private func setTransportButton(_ name: String, to desired: Bool, timeout attempts: Int = 20) -> ChannelResult {
        guard let button = AXLogicProElements.findTransportButton(named: name) else {
            return .error("Cannot find transport button: \(name)")
        }
        if AXValueExtractors.extractCheckboxState(button) == desired {
            return .success("{\"\(name)\":\(desired),\"already\":true}")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            // A press that opens a modal dialog reports failure even though Logic acted.
            if let dialog = AXHelpers.poll(attempts: 5, interval: 100_000, AXLogicProElements.openDialogSummary) {
                return .failedAfterActing("Pressed \(name); Logic answered with a dialog: \(dialog)")
            }
            return .error("Failed to press transport button: \(name)")
        }
        // Record can stay off until a count-in finishes, hence the longer allowance.
        let outcome = AXHelpers.poll(attempts: attempts) { () -> String? in
            if AXValueExtractors.extractCheckboxState(button) == desired { return "" }
            return AXLogicProElements.openDialogSummary()
        }
        if let dialog = outcome, !dialog.isEmpty {
            return .failedAfterActing("Pressed \(name); Logic answered with a dialog: \(dialog)")
        }
        guard outcome != nil else {
            return .failedAfterActing("Pressed \(name) but Logic still shows it \(desired ? "off" : "on")")
        }
        return .success("{\"\(name)\":\(desired)}")
    }

    private func setTempo(params: [String: String]) -> ChannelResult {
        guard let tempo = (params["bpm"] ?? params["tempo"]).flatMap(Double.init) else {
            return .error("Missing or invalid 'tempo' parameter")
        }
        guard let transport = AXLogicProElements.getTransportBar(),
              let slider = AXHelpers.findDescendant(of: transport, role: kAXSliderRole, description: "Tempo", maxDepth: 4) else {
            return .error("Cannot find the control bar Tempo slider")
        }
        guard Self.step(slider, to: tempo.rounded()) else {
            return .failedAfterActing("Set tempo \(tempo) but Logic shows \(AXValueExtractors.extractSliderValue(slider) ?? -1)")
        }
        return .success("{\"tempo\":\(tempo.rounded())}")
    }

    /// Logic moves its control bar sliders one unit per AX value set, toward the requested value,
    /// so keep setting until the readback matches. Fails as soon as a set makes no progress.
    private static func step(_ slider: AXUIElement, to target: Double, maxSteps: Int = 2_000) -> Bool {
        var previous = AXValueExtractors.extractSliderValue(slider)
        for _ in 0..<maxSteps {
            guard let current = previous else { return false }
            if abs(current - target) < 0.5 { return true }
            AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: target))
            let next = AXHelpers.poll(attempts: 10, interval: 10_000) { () -> Double? in
                guard let value = AXValueExtractors.extractSliderValue(slider), value != current else { return nil }
                return value
            }
            guard let next else { return false }
            previous = next
        }
        return false
    }

    /// Logic 12 has no Stop button and pressing Play doesn't stop playback, so send Space and confirm.
    private func stopTransport() async -> ChannelResult {
        guard let play = AXLogicProElements.findTransportButton(named: "Play") else {
            return .error("Cannot find transport button: Play")
        }
        if AXValueExtractors.extractCheckboxState(play) == false {
            return .success("{\"Play\":false,\"already\":true}")
        }
        guard await bringLogicForward() else {
            return .error("Could not bring Logic Pro to the front to stop")
        }
        AXPointer.pressKey(49)  // Space
        let stopped = AXHelpers.poll { AXValueExtractors.extractCheckboxState(play) == false ? true : nil }
        guard stopped != nil else { return .failedAfterActing("Sent Space but Logic is still playing") }
        return .success("{\"Play\":false}")
    }

    /// Moves the playhead by setting the control bar's bar slider ("Playhead Position" › "bar").
    private func gotoBar(params: [String: String]) -> ChannelResult {
        guard let bar = (params["bar"] ?? params["position"]?.split(separator: ".").first.map(String.init)).flatMap(Int.init) else {
            return .error("goto_position via AX needs a bar number")
        }
        guard let transport = AXLogicProElements.getTransportBar(),
              let playhead = AXHelpers.findDescendant(of: transport, role: kAXGroupRole, description: "Playhead Position", maxDepth: 4),
              let slider = AXHelpers.findDescendant(of: playhead, role: kAXSliderRole, description: "bar", maxDepth: 2) else {
            return .error("Cannot find the playhead bar slider")
        }
        // Bar start: bring the beat back to 1 as well (the bar slider keeps the current beat).
        let beat = AXHelpers.findDescendant(of: playhead, role: kAXSliderRole, description: "beat", maxDepth: 2)
        guard Self.step(slider, to: Double(bar)), beat.map({ Self.step($0, to: 1) }) ?? true else {
            return .failedAfterActing("Set playhead to bar \(bar) but Logic shows bar \(Int(AXValueExtractors.extractSliderValue(slider) ?? -1))")
        }
        return .success("{\"bar\":\(bar)}")
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

    // Logic 12 track header controls report AXPress as handled but never act on it,
    // so track selection, toggles and rename use a real click (see AXPointer).

    private func selectTrack(params: [String: String]) async -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index),
              let field = AXLogicProElements.findTrackNameField(trackIndex: index) else {
            return .error("Track at index \(index) not found")
        }
        if AXValueExtractors.isTrackSelected(header) {
            return .success("{\"selected\":\(index),\"already\":true}")
        }
        guard await bringLogicForward() else {
            return .error("Could not bring Logic Pro to the front; nothing was clicked")
        }
        // A single click on the name selects the track; a double-click would rename it.
        guard AXPointer.click(field) else {
            return .error("Track \(index) is covered by another window or off screen; nothing was clicked")
        }
        let selected = AXHelpers.poll {
            AXLogicProElements.findTrackHeader(at: index).flatMap { AXValueExtractors.isTrackSelected($0) ? true : nil }
        }
        guard selected != nil else {
            return .failedAfterActing("Clicked track \(index) but Logic does not show it selected")
        }
        return .success("{\"selected\":\(index)}")
    }

    private func setTrackToggle(params: [String: String], button buttonName: String) async -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": AXLogicProElements.findTrackMuteButton
        case "Solo": AXLogicProElements.findTrackSoloButton
        case "Record": AXLogicProElements.findTrackArmButton
        case "Input Monitoring": AXLogicProElements.findTrackInputMonitorButton
        default: { _ in nil }
        }
        let desired = params["enabled"].map { $0 == "true" } ?? true
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index); the track may not exist, be scrolled out of view, or the header may not show that button")
        }
        if AXValueExtractors.extractCheckboxState(button) == desired {
            return .success("{\"track\":\(index),\"\(buttonName)\":\(desired),\"already\":true}")
        }
        guard await bringLogicForward() else {
            return .error("Could not bring Logic Pro to the front; nothing was clicked")
        }
        guard AXPointer.click(button) else {
            return .error("\(buttonName) on track \(index) is covered by another window or off screen; nothing was clicked")
        }
        // Re-read the element we hold; only search again if Logic replaced it.
        let confirmed = AXHelpers.poll { () -> Bool? in
            let state = AXValueExtractors.extractCheckboxState(button)
                ?? finder(index).flatMap(AXValueExtractors.extractCheckboxState)
            return state == desired ? true : nil
        }
        guard confirmed != nil else {
            return .failedAfterActing("Clicked \(buttonName) on track \(index) but Logic still shows it \(desired ? "off" : "on")")
        }
        return .success("{\"track\":\(index),\"\(buttonName)\":\(desired)}")
    }

    private func renameTrack(params: [String: String]) async -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index),
              let field = AXLogicProElements.findTrackNameField(trackIndex: index) else {
            return .error("Cannot find name field for track \(index)")
        }
        if AXValueExtractors.extractTrackState(from: header, index: index).name == name {
            return .success("{\"track\":\(index),\"name\":\"\(name)\",\"already\":true}")
        }
        guard await bringLogicForward() else {
            return .error("Could not bring Logic Pro to the front; nothing was clicked")
        }
        // The header name field isn't settable; double-clicking opens an editable field editor.
        // A double-click right after scrolling is sometimes lost, so try twice.
        var editor: AXUIElement?
        for _ in 0..<2 where editor == nil {
            guard let target = AXLogicProElements.findTrackNameField(trackIndex: index) ?? Optional(field),
                  AXPointer.click(target, count: 2) else {
                return .error("Name of track \(index) is covered by another window or off screen; nothing was clicked")
            }
            // Never set anything unless an editable text field actually has focus.
            editor = AXHelpers.poll(focusedEditableTextField)
        }
        guard let editor else {
            return .error("Rename editor did not open on track \(index); nothing was changed")
        }
        guard AXHelpers.setAttribute(editor, kAXValueAttribute, name as CFTypeRef) else {
            return .failedAfterActing("Rename editor on track \(index) rejected the new name")
        }
        AXHelpers.performAction(editor, kAXConfirmAction)
        let confirmed = AXHelpers.poll { () -> Bool? in
            guard let header = AXLogicProElements.findTrackHeader(at: index) else { return nil }
            return AXValueExtractors.extractTrackState(from: header, index: index).name == name ? true : nil
        }
        guard confirmed != nil else {
            return .failedAfterActing("Set track \(index) name to '\(name)' but Logic does not show it")
        }
        return .success("{\"track\":\(index),\"name\":\"\(name)\"}")
    }

    /// Presses File › Save and confirms the project's ProjectData file was rewritten.
    private func saveProject() -> ChannelResult {
        guard let project = AXLogicProElements.openProjectURL() else {
            return .error("Cannot determine the open project's file")
        }
        let before = Self.lastProjectWrite(project)
        guard let item = AXLogicProElements.menuItem(path: ["File", "Save"]),
              AXHelpers.performAction(item, kAXPressAction) else {
            return .error("Cannot press File › Save")
        }
        let saved = AXHelpers.poll(attempts: 50, interval: 100_000) { () -> Bool? in
            guard let after = Self.lastProjectWrite(project), after != before else { return nil }
            return true
        }
        guard saved != nil else {
            return .failedAfterActing("Pressed File › Save but \(project.lastPathComponent) was not written; a dialog may be open")
        }
        return .success("{\"saved\":\"\(project.path)\"}")
    }

    private func respondToDialog(params: [String: String]) -> ChannelResult {
        guard let title = params["button"] else { return .error("Missing 'button' parameter") }
        guard let dialog = AXLogicProElements.openDialog() else { return .error("No Logic dialog is open") }
        let buttons = AXHelpers.findAllDescendants(of: dialog, role: kAXButtonRole, maxDepth: 4)
        guard let button = buttons.first(where: { AXHelpers.getTitle($0) == title }) else {
            let titles = buttons.compactMap { AXHelpers.getTitle($0) }.filter { !$0.isEmpty }
            return .error("No button '\(title)'. Buttons: \(titles.joined(separator: ", "))")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else { return .error("Failed to press '\(title)'") }
        let next = AXHelpers.poll(attempts: 10, interval: 100_000) { () -> String? in
            guard let open = AXLogicProElements.openDialog() else { return "" }
            return CFEqual(open, dialog) ? nil : (AXLogicProElements.openDialogSummary() ?? "")
        }
        switch next {
        case .none: return .failedAfterActing("Pressed '\(title)' but the dialog is still open")
        case .some(""): return .success("{\"pressed\":\"\(title)\"}")
        case .some(let following): return .success("Pressed '\(title)'. Logic now asks: \(following)")
        }
    }

    private func openProject(params: [String: String]) -> ChannelResult {
        guard let path = params["path"] else { return .error("Missing 'path' parameter") }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        if AXLogicProElements.openProjectPaths().contains(target) {
            return .success("{\"opened\":\"\(target)\",\"already\":true}")
        }
        // `open` returns immediately; AppleScript's open blocks while Logic shows a dialog.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-a", "Logic Pro", target]
        do {
            try launcher.run()
            launcher.waitUntilExit()
        } catch {
            return .error("Failed to open \(target): \(error.localizedDescription)")
        }
        // Stop waiting as soon as Logic asks something (missing files, MIDI ports, ...).
        let outcome = AXHelpers.poll(attempts: 150, interval: 100_000) { () -> String? in
            if AXLogicProElements.openProjectPaths().contains(target) { return "" }
            return AXLogicProElements.openDialogSummary()
        }
        guard let outcome else {
            return .failedAfterActing("\(target) did not open within 15s")
        }
        guard outcome.isEmpty else {
            return .failedAfterActing("Opening \(target) is waiting on a Logic dialog: \(outcome)")
        }
        return .success("{\"opened\":\"\(target)\"}")
    }

    private func closeProject() -> ChannelResult {
        guard let project = AXLogicProElements.openProjectURL()?.path else {
            return .error("No project is open")
        }
        guard let item = AXLogicProElements.menuItem(path: ["File", "Close Project"]),
              AXHelpers.performAction(item, kAXPressAction) else {
            return .error("Cannot press File › Close Project")
        }
        let outcome = AXHelpers.poll(attempts: 30, interval: 100_000) { () -> String? in
            if !AXLogicProElements.openProjectPaths().contains(project) { return "" }
            return AXLogicProElements.openDialogSummary()
        }
        guard let outcome else {
            return .failedAfterActing("\(project) is still open after 3s")
        }
        guard outcome.isEmpty else {
            return .failedAfterActing("Closing \(project) is waiting on a Logic dialog: \(outcome)")
        }
        return .success("{\"closed\":\"\(project)\"}")
    }

    /// Newest modification date among the project's ProjectData files.
    private static func lastProjectWrite(_ project: URL) -> Date? {
        let alternatives = project.appendingPathComponent("Alternatives")
        let folders = (try? FileManager.default.contentsOfDirectory(at: alternatives, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap {
            try? $0.appendingPathComponent("ProjectData").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }

    /// Presses a Track › New … Track item and confirms one track was added.
    private func createTrack(menuItem title: String) -> ChannelResult {
        let before = AXLogicProElements.allTrackHeaders().count
        guard let item = AXLogicProElements.menuItem(path: ["Track", title]),
              AXHelpers.performAction(item, kAXPressAction) else {
            return .error("Cannot press Track › \(title)")
        }
        let added = AXHelpers.poll { AXLogicProElements.allTrackHeaders().count == before + 1 ? true : nil }
        guard added != nil else {
            return .failedAfterActing("Pressed Track › \(title) but the track count is still \(before)")
        }
        return .success("{\"created\":\"\(title)\",\"track_count\":\(before + 1)}")
    }

    /// Presses a menu item. With `expectUndo`, confirms Logic recorded an undoable edit.
    private func pressMenuItem(_ path: [String], expectUndo: Bool = false) -> ChannelResult {
        let undoBefore = expectUndo ? undoTitle() : nil
        guard let item = AXLogicProElements.menuItem(path: path) else {
            return .error("Cannot find \(path.joined(separator: " › "))")
        }
        // AXEnabled can be stale (menus refresh only when opened); a disabled item fails the press.
        guard AXHelpers.performAction(item, kAXPressAction) else {
            return .error("\(path.joined(separator: " › ")) is unavailable (nothing selected?)")
        }
        guard expectUndo else { return .success("{\"pressed\":\"\(path.joined(separator: " › "))\"}") }
        let undo = AXHelpers.poll { () -> String? in
            guard let title = undoTitle(), title != undoBefore else { return nil }
            return title
        }
        guard let undo else {
            return .failedAfterActing("Pressed \(path.joined(separator: " › ")) but Logic recorded no edit")
        }
        // Edit › Delete removes whatever has focus. Deleting tracks this way is never intended
        // (track deletion is logic_tracks delete), so take it straight back.
        if undo.hasSuffix("Tracks") || undo.hasSuffix("Track") {
            _ = pressEditMenuItem(prefix: "Undo")
            return .failedAfterActing("\(path.joined(separator: " › ")) would have deleted tracks (\(undo)); undone. Select regions first.")
        }
        return .success("{\"pressed\":\"\(path.joined(separator: " › "))\",\"undo\":\"\(undo)\"}")
    }

    /// Deletes every region via the Tracks area's local Edit menu, which acts on regions
    /// regardless of keyboard focus. Refuses (and undoes) if Logic deleted tracks instead.
    private func clearAllRegions() -> ChannelResult {
        let undoBefore = undoTitle()
        guard pressTracksAreaMenu(["Edit", "Select", "All"]) else {
            return .error("Cannot press the Tracks area's Edit › Select › All")
        }
        usleep(200_000)
        guard pressTracksAreaMenu(["Edit", "Delete"]) else {
            return .error("Cannot press the Tracks area's Edit › Delete (no regions selected?)")
        }
        let undo = AXHelpers.poll { () -> String? in
            guard let title = undoTitle(), title != undoBefore else { return nil }
            return title
        }
        guard let undo else { return .success("{\"cleared\":0,\"note\":\"no regions to delete\"}") }
        if undo.hasSuffix("Tracks") || undo.hasSuffix("Track") {
            _ = pressEditMenuItem(prefix: "Undo")
            return .failedAfterActing("Clearing regions would have deleted tracks (\(undo)); undone")
        }
        return .success("{\"cleared\":true,\"undo\":\"\(undo)\"}")
    }

    /// Opens a menu button in the main window's Tracks area (e.g. its local "Edit") and presses the item at `path`.
    private func pressTracksAreaMenu(_ path: [String]) -> Bool {
        guard let window = AXLogicProElements.mainWindow(),
              let tracks = AXHelpers.findDescendant(of: window, role: kAXGroupRole, description: "Tracks", maxDepth: 6),
              let button = AXHelpers.findDescendant(of: tracks, role: kAXMenuButtonRole, description: path[0], maxDepth: 4),
              AXHelpers.performAction(button, kAXPressAction) else { return false }
        usleep(300_000)
        var menu: AXUIElement? = AXHelpers.findDescendant(of: button, role: kAXMenuRole, maxDepth: 2)
        var item: AXUIElement?
        for title in path.dropFirst() {
            guard let current = menu,
                  let next = AXHelpers.getChildren(current).first(where: { AXHelpers.getTitle($0) == title }) else {
                if let menu { AXHelpers.performAction(menu, kAXCancelAction) }
                return false
            }
            item = next
            menu = AXHelpers.getChildren(next).first
        }
        guard let item, (AXHelpers.getAttribute(item, kAXEnabledAttribute) as Bool?) ?? true else { return false }
        return AXHelpers.performAction(item, kAXPressAction)
    }

    private func undoTitle() -> String? {
        guard let edit = AXLogicProElements.menuItem(path: ["Edit"]),
              let menu = AXHelpers.getChildren(edit).first else { return nil }
        return AXHelpers.getChildren(menu).compactMap { AXHelpers.getTitle($0) }.first { $0.hasPrefix("Undo") }
    }

    /// Presses Edit › Undo… / Redo… and reports which action it was ("Undo Rename Track").
    /// Logic refreshes menu titles and enabled states only when a menu opens, and silently
    /// ignores presses on stale items, so open the Edit menu first. (Titles can't confirm the
    /// result: undoing two identical edits leaves them unchanged.)
    private func pressEditMenuItem(prefix: String) -> ChannelResult {
        guard let edit = AXLogicProElements.menuItem(path: ["Edit"]) else {
            return .error("Cannot find the Edit menu")
        }
        AXHelpers.performAction(edit, kAXPressAction)
        usleep(150_000)
        guard let menu = AXHelpers.getChildren(edit).first else { return .error("Cannot open the Edit menu") }
        guard let item = AXHelpers.getChildren(menu).first(where: {
            let title = AXHelpers.getTitle($0) ?? ""
            return title.hasPrefix(prefix) && !title.hasPrefix("\(prefix) History")
        }) else {
            AXHelpers.performAction(menu, kAXCancelAction)
            return .error("Cannot find Edit › \(prefix)")
        }
        let title = AXHelpers.getTitle(item) ?? prefix
        guard (AXHelpers.getAttribute(item, kAXEnabledAttribute) as Bool?) ?? true,
              AXHelpers.performAction(item, kAXPressAction) else {
            AXHelpers.performAction(menu, kAXCancelAction)
            return .error("Nothing to \(prefix.lowercased())")
        }
        return .success("{\"pressed\":\"\(title)\"}")
    }

    private func deleteSelectedTrack() -> ChannelResult {
        let before = AXLogicProElements.allTrackHeaders().count
        guard let item = AXLogicProElements.menuItem(path: ["Track", "Delete Track"]),
              AXHelpers.performAction(item, kAXPressAction) else {
            return .error("Cannot press Track › Delete Track")
        }
        let deleted = AXHelpers.poll { AXLogicProElements.allTrackHeaders().count == before - 1 ? true : nil }
        guard deleted != nil else {
            return .failedAfterActing("Pressed Track › Delete Track but the track count is still \(before)")
        }
        return .success("{\"deleted\":true,\"track_count\":\(before - 1)}")
    }

    /// Makes Logic frontmost and raises its main window; synthetic clicks only land on the active app.
    private func bringLogicForward() async -> Bool {
        guard await ProcessUtils.ensureLogicProFrontmost() else { return false }
        if let window = AXLogicProElements.mainWindow() {
            AXHelpers.performAction(window, kAXRaiseAction)
        }
        return true
    }

    /// Logic's focused element, if it is an editable text field.
    private func focusedEditableTextField() -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(),
              let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute),
              AXHelpers.getRole(focused) == kAXTextFieldRole else { return nil }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        return settable.boolValue ? focused : nil
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
            eqEnabled: eqButton.flatMap { AXHelpers.getAttribute($0, kAXValueAttribute) } == "on"
        )
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
