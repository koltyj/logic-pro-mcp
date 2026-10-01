import ApplicationServices
import Foundation

/// Logic Pro-specific AX element finders.
/// Navigates from the app root to known UI regions using role/title/structure heuristics.
/// Logic Pro's AX tree structure may change between versions; these are best-effort.
enum AXLogicProElements {
    /// Get the root AX element for Logic Pro. Returns nil if not running.
    static func appRoot() -> AXUIElement? {
        guard let pid = ProcessUtils.logicProPID() else { return nil }
        return AXHelpers.axApp(pid: pid)
    }

    /// Get the main window element.
    /// The project's Tracks window, which holds the control bar and track list. Other windows
    /// (Marker List, Mixer) can become "main", so prefer the Tracks window, then main, then any standard one.
    static func mainWindow() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute) ?? []
        if let tracks = windows.first(where: { (AXHelpers.getTitle($0) ?? "").hasSuffix(" - Tracks") }) { return tracks }
        if let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute) { return main }
        return windows.first {
            (AXHelpers.getAttribute($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
        }
    }

    /// File URL of the project in the main window (AXDocument).
    static func openProjectURL() -> URL? {
        guard let window = mainWindow(),
              let document: String = AXHelpers.getAttribute(window, kAXDocumentAttribute) else { return nil }
        return URL(string: document)
    }

    /// File paths of the projects open in Logic's windows.
    static func openProjectPaths() -> [String] {
        guard let app = appRoot() else { return [] }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute) ?? []
        return windows.compactMap { window in
            let document: String? = AXHelpers.getAttribute(window, kAXDocumentAttribute)
            return document.flatMap(URL.init(string:))?.path
        }
    }

    static func markerListWindow() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute) ?? []
        return windows.first { (AXHelpers.getTitle($0) ?? "").hasSuffix("Marker List") }
    }

    /// The open Logic dialog window, if any.
    static func openDialog() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute) ?? []
        return windows.first { window in
            switch AXHelpers.getAttribute(window, kAXSubroleAttribute) as String? {
            case kAXDialogSubrole?:
                return true
            case kAXFloatingWindowSubrole?:
                // Logic shows some confirmations (e.g. Clean Up Project) as floating panels.
                return AXHelpers.getChildren(window).contains {
                    AXHelpers.getRole($0) == kAXButtonRole && ["OK", "Cancel"].contains(AXHelpers.getTitle($0) ?? "")
                }
            default:
                return false
            }
        }
    }

    /// Text and buttons of an open Logic dialog window, if any.
    static func openDialogSummary() -> String? {
        guard let dialog = openDialog() else { return nil }
        let text = AXHelpers.findAllDescendants(of: dialog, role: kAXStaticTextRole, maxDepth: 4)
            .compactMap { AXValueExtractors.extractTextValue($0) }
        let buttons = AXHelpers.findAllDescendants(of: dialog, role: kAXButtonRole, maxDepth: 4)
            .compactMap { AXHelpers.getTitle($0) }.filter { !$0.isEmpty }
        return "\(text.joined(separator: " ")) [buttons: \(buttons.joined(separator: ", "))]"
    }

    // MARK: - Transport

    /// Find the transport bar area (toolbar/group containing play, stop, record, etc.)
    static func getTransportBar() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        if let bar = AXHelpers.findChild(of: window, role: kAXGroupRole, description: "Control Bar") {
            return bar
        }
        // Legacy fallback: Logic Pro's transport is typically an AXToolbar near the top.
        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole) {
            return toolbar
        }
        // Legacy fallback: a group with the old identifier.
        return AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport")
    }

    /// Find a specific transport control by its title or description.
    static func findTransportButton(named name: String) -> AXUIElement? {
        guard let transport = getTransportBar() else { return nil }
        if let checkbox = AXHelpers.findDescendant(
            of: transport, role: kAXCheckBoxRole, description: name, maxDepth: 4
        ) {
            return checkbox
        }
        if let checkbox = AXHelpers.findDescendant(
            of: transport, role: kAXCheckBoxRole, title: name, maxDepth: 4
        ) {
            return checkbox
        }
        // Legacy fallback: AXButton.
        if let button = AXHelpers.findDescendant(of: transport, role: kAXButtonRole, title: name) {
            return button
        }
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            if AXHelpers.getDescription(button) == name {
                return button
            }
        }
        return nil
    }

    // MARK: - Tracks

    /// Find the track header area containing individual track rows.
    static func getTrackHeaders() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        if let area = AXHelpers.findDescendant(
            of: window, role: kAXGroupRole, description: "Tracks header"
        ) {
            return area
        }
        // Legacy fallbacks for older Logic Pro versions.
        if let area = AXHelpers.findDescendant(of: window, role: kAXListRole, identifier: "Track Headers") {
            return area
        }
        // Fallback: look for an AXScrollArea containing AXRow or AXGroup children
        if let area = AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Tracks") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXOutlineRole, maxDepth: 5)
    }

    /// Find a track header at a specific index (0-based).
    static func findTrackHeader(at index: Int) -> AXUIElement? {
        guard let headers = getTrackHeaders() else { return nil }
        let rows = AXHelpers.getChildren(headers)
        guard index >= 0 && index < rows.count else { return nil }
        return rows[index]
    }

    /// Enumerate all track header rows.
    static func allTrackHeaders() -> [AXUIElement] {
        guard let headers = getTrackHeaders() else { return [] }
        return AXHelpers.getChildren(headers)
    }

    // MARK: - Mixer

    /// Find the mixer area.
    static func getMixerArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // Logic Pro leaves AXIdentifier empty on these containers, so the mixer
        // has to be matched on AXDescription instead.
        //
        // Anchor on the window-level "Mixer" pane before descending: the
        // Inspector holds its own AXLayoutArea also described "Mixer" (the
        // single-channel strip), and a plain recursive search finds that one
        // first and reports one or two strips instead of the full desk.
        guard let pane = AXHelpers.findChild(
            of: window, role: kAXGroupRole, description: "Mixer"
        ) else { return nil }

        // The channel strips live in an AXLayoutArea inside that pane.
        if let area = AXHelpers.findDescendant(
            of: pane, role: "AXLayoutArea", description: "Mixer", maxDepth: 3
        ) {
            return area
        }
        return pane
    }

    /// AXDescription values Logic Pro uses for the controls inside a channel
    /// strip. Strips are matched on these rather than on child order, because
    /// aux, output and master strips expose different control sets — the master
    /// strip has no pan control at all, so an ordinal lookup silently returns
    /// some other slider.
    enum StripControl {
        static let volume = "volume fader"
        static let pan = "pan"
        static let eq = "EQ"
    }

    /// The channel strips, in mixer order.
    static func mixerStrips() -> [AXUIElement] {
        guard let mixer = getMixerArea() else { return [] }
        return AXHelpers.getChildren(mixer)
    }

    /// One channel strip by its position in the mixer.
    static func mixerStrip(at index: Int) -> AXUIElement? {
        let strips = mixerStrips()
        guard strips.indices.contains(index) else { return nil }
        return strips[index]
    }

    /// Find a control inside a channel strip by its AXDescription.
    /// Returns nil when the strip has no such control, which is a real and
    /// expected outcome — callers must not fall back to a positional guess.
    static func stripControl(
        _ strip: AXUIElement,
        role: String,
        description: String
    ) -> AXUIElement? {
        AXHelpers.findDescendant(of: strip, role: role, description: description, maxDepth: 4)
    }

    /// Find a volume fader for a specific strip index within the mixer.
    static func findFader(trackIndex: Int) -> AXUIElement? {
        guard let strip = mixerStrip(at: trackIndex) else { return nil }
        return stripControl(strip, role: kAXSliderRole, description: StripControl.volume)
    }

    /// Find the pan control for a strip in the mixer. Nil on strips that have none.
    static func findPanKnob(trackIndex: Int) -> AXUIElement? {
        guard let strip = mixerStrip(at: trackIndex) else { return nil }
        return stripControl(strip, role: kAXSliderRole, description: StripControl.pan)
    }

    /// Find the master strip's volume fader. Logic Pro normally labels it
    /// "Master"; "Stereo Out" is the output-strip fallback used by layouts
    /// that do not expose a separate master strip.
    static func findMasterFader() -> AXUIElement? {
        let strips = mixerStrips()
        let descriptions = strips.map { AXHelpers.getDescription($0) }
        for index in masterStripCandidateIndices(descriptions: descriptions) {
            if let fader = stripControl(
                strips[index], role: kAXSliderRole, description: StripControl.volume
            ) {
                return fader
            }
        }
        return nil
    }

    static func masterStripCandidateIndices(descriptions: [String?]) -> [Int] {
        func indices(matching expectedDescription: String) -> [Int] {
            descriptions.indices.filter {
                descriptions[$0]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(expectedDescription) == .orderedSame
            }
        }
        return indices(matching: "Master") + indices(matching: "Stereo Out")
    }

    // MARK: - Menu Bar

    /// Get the menu bar for Logic Pro.
    static func getMenuBar() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMenuBarAttribute)
    }

    /// Navigate menu: e.g. menuItem(path: ["File", "New..."]).
    static func menuItem(path: [String]) -> AXUIElement? {
        guard var current = getMenuBar() else { return nil }
        for title in path {
            let children = AXHelpers.getChildren(current)
            var found = false
            for child in children {
                // Menu bar items and menu items both use AXTitle
                if AXHelpers.getTitle(child) == title {
                    current = child
                    found = true
                    break
                }
                // Check child menu items inside a menu
                let subChildren = AXHelpers.getChildren(child)
                for sub in subChildren {
                    if AXHelpers.getTitle(sub) == title {
                        current = sub
                        found = true
                        break
                    }
                }
                if found { break }
            }
            if !found { return nil }
        }
        return current
    }

    // MARK: - Arrangement

    /// Find the main arrangement area (the timeline/tracks view).
    static func getArrangementArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        if let area = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Arrangement") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Arrangement")
    }

    // MARK: - Track Controls

    /// Find the mute control on a track header.
    static func findTrackMuteButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findToggleByDescription(in: header, description: "Mute")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "M")
    }

    /// Find the solo control on a track header.
    static func findTrackSoloButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findToggleByDescription(in: header, description: "Solo")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "S")
    }

    /// Find the record-arm control on a track header.
    static func findTrackArmButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findToggleByDescription(in: header, description: "Record Enable")
            ?? findToggleByDescription(in: header, description: "Record")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "R")
    }

    /// Find the track name text field on a header.
    static func findTrackInputMonitorButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findToggleByDescription(in: header, description: "Input Monitoring")
    }

    static func findTrackNameField(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4)
            ?? AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 4)
    }

    // MARK: - Helpers

    private static func findToggleByDescription(
        in element: AXUIElement, description: String
    ) -> AXUIElement? {
        if let checkbox = AXHelpers.findDescendant(
            of: element, role: kAXCheckBoxRole, description: description, maxDepth: 4
        ) {
            return checkbox
        }
        let buttons = AXHelpers.findAllDescendants(of: element, role: kAXButtonRole, maxDepth: 4)
        return buttons.first { button in
            guard let desc = AXHelpers.getDescription(button) else { return false }
            return desc.hasPrefix(description)
        }
    }
}
