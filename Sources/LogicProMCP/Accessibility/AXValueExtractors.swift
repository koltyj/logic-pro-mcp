import ApplicationServices
import Foundation

/// Extract typed values from AX elements.
/// These handle the various ways Logic Pro represents values in its AX tree.
enum AXValueExtractors {
    /// Extract a numeric value from a slider (volume fader, pan knob, etc.)
    /// Returns the AXValue as a Double, or nil if unavailable.
    static func extractSliderValue(_ element: AXUIElement) -> Double? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // AXSlider values can come as NSNumber or CFNumber
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        // Try string-based value and parse
        if let str = value as? String, let parsed = Double(str) {
            return parsed
        }
        return nil
    }

    /// Extract a text value from a static text or text field element.
    /// Used for tempo display, position readout, track names, etc.
    static func extractTextValue(_ element: AXUIElement) -> String? {
        // Try kAXValueAttribute first (text fields, static text)
        if let value = AXHelpers.getValue(element) as? String {
            return value
        }
        // Fallback to kAXTitleAttribute
        return AXHelpers.getTitle(element)
    }

    /// Extract a boolean state from a button or checkbox element.
    /// For toggle buttons (mute, solo, arm, cycle, metronome), the value
    /// indicates pressed/active state.
    static func extractButtonState(_ element: AXUIElement) -> Bool? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // Toggle buttons typically report 0/1 as NSNumber
        if let number = value as? NSNumber {
            return number.boolValue
        }
        // Some buttons use string "1"/"0"
        if let str = value as? String {
            return str == "1" || str.lowercased() == "true"
        }
        return nil
    }

    /// Extract checkbox state (a variant of button state, but checks kAXValueAttribute specifically).
    static func extractCheckboxState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXValueAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        return nil
    }

    /// Extract the selected state of an element.
    static func extractSelectedState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXSelectedAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    /// Extract slider range (min/max) for interpreting fader values.
    struct SliderRange {
        let min: Double
        let max: Double
    }

    static func extractSliderRange(_ element: AXUIElement) -> SliderRange? {
        guard let minVal: AnyObject = AXHelpers.getAttribute(element, kAXMinValueAttribute),
              let maxVal: AnyObject = AXHelpers.getAttribute(element, kAXMaxValueAttribute),
              let min = (minVal as? NSNumber)?.doubleValue,
              let max = (maxVal as? NSNumber)?.doubleValue else {
            return nil
        }
        return SliderRange(min: min, max: max)
    }

    /// Read a track header and extract its basic state.
    /// Logic Pro 12 track headers are AXLayoutItem elements containing:
    ///   AXRadioButton desc="Has Focus" (selected state)
    ///   AXCheckBox desc="Mute"/"Solo"/"Record Enable"/"Input Monitoring"
    ///   AXButton desc="Track N \"name\"" (icon/click target)
    ///   AXTextField desc="name" value=0 (name in desc, not value)
    static func extractTrackState(from header: AXUIElement, index: Int) -> TrackState {
        let name = extractTrackName(from: header)
        let muted = extractToggleState(from: header, description: "Mute") ?? false
        let soloed = extractToggleState(from: header, description: "Solo") ?? false
        let armed = extractToggleState(from: header, description: "Record Enable")
            ?? extractToggleState(from: header, description: "Record")
            ?? false
        let selected = extractHasFocus(from: header) ?? false
        let trackType = inferTrackType(from: header)

        return TrackState(
            id: index,
            name: name,
            type: trackType,
            isMuted: muted,
            isSoloed: soloed,
            isArmed: armed,
            isSelected: selected,
            volume: 0.0,
            pan: 0.0,
            color: extractTrackColor(from: header)
        )
    }

    /// Read transport bar elements and build a TransportState.
    /// Logic Pro 12 transport uses AXCheckBox for Play/Record/Cycle/Metronome (not AXButton),
    /// AXSlider for Tempo/bar/beat/division/tick (not AXStaticText).
    static func extractTransportState(from transport: AXUIElement) -> TransportState {
        var state = TransportState()

        // Logic Pro 12: transport toggles are AXCheckBox with value 0/1.
        // Track which controls the checkbox pass resolved, so the legacy
        // button fallback fills in only the gaps -- mixed AX trees exist
        // (checkbox Play alongside button Record/Cycle/Metronome), and a
        // button must never overwrite a checkbox-resolved state.
        var resolvedPlay = false
        var resolvedRecord = false
        var resolvedCycle = false
        var resolvedMetronome = false

        let checkboxes = AXHelpers.findAllDescendants(of: transport, role: kAXCheckBoxRole, maxDepth: 4)
        for cb in checkboxes {
            let desc = AXHelpers.getDescription(cb) ?? AXHelpers.getTitle(cb) ?? ""
            let pressed = extractCheckboxState(cb) ?? false
            let descLower = desc.lowercased()

            if descLower == "play" {
                state.isPlaying = pressed
                resolvedPlay = true
            } else if descLower == "record" {
                state.isRecording = pressed
                resolvedRecord = true
            } else if descLower == "cycle" {
                state.isCycleEnabled = pressed
                resolvedCycle = true
            } else if descLower.contains("metronome") || descLower.contains("click") {
                state.isMetronomeEnabled = pressed
                resolvedMetronome = true
            }
        }

        // Legacy fallback: some versions use AXButton. Consult buttons only
        // for controls the checkbox pass left unresolved.
        if !(resolvedPlay && resolvedRecord && resolvedCycle && resolvedMetronome) {
            let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
            for button in buttons {
                let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
                let pressed = extractButtonState(button) ?? false
                let descLower = desc.lowercased()

                if !resolvedPlay, descLower.contains("play") { state.isPlaying = pressed }
                else if !resolvedRecord, descLower.contains("record") && !descLower.contains("arm") { state.isRecording = pressed }
                else if !resolvedCycle, descLower.contains("cycle") || descLower.contains("loop") { state.isCycleEnabled = pressed }
                else if !resolvedMetronome, descLower.contains("metronome") || descLower.contains("click") { state.isMetronomeEnabled = pressed }
            }
        }

        // Logic Pro 12: tempo and position are AXSlider elements
        let sliders = AXHelpers.findAllDescendants(of: transport, role: kAXSliderRole, maxDepth: 4)
        var bar: Int?, beat: Int?, division: Int?, tick: Int?
        for slider in sliders {
            let desc = AXHelpers.getDescription(slider)?.lowercased() ?? ""
            if let value = extractSliderValue(slider) {
                switch desc {
                case "tempo":
                    state.tempo = value
                case "bar":
                    bar = Int(value)
                case "beat":
                    beat = Int(value)
                case "division":
                    division = Int(value)
                case "tick":
                    tick = Int(value)
                default:
                    break
                }
            }
        }

        // Build position string from slider components
        if let b = bar, let bt = beat, let d = division, let t = tick {
            state.position = "\(b).\(bt).\(d).\(t)"
        }

        // Legacy fallback: text-based position/tempo
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXStaticTextRole, maxDepth: 4)
        for text in texts {
            guard let value = extractTextValue(text) else { continue }
            let desc = AXHelpers.getDescription(text) ?? ""
            let descLower = desc.lowercased()

            if state.tempo == 0, descLower.contains("tempo") || descLower.contains("bpm") {
                if let tempo = Double(value.replacingOccurrences(of: " BPM", with: "")) {
                    state.tempo = tempo
                }
            } else if state.position == "1.1.1.1", value.filter({ $0 == "." }).count >= 2 {
                state.position = value
            } else if value.contains(":") {
                state.timePosition = value
            }
        }

        state.lastUpdated = Date()
        return state
    }

    // MARK: - Private helpers

    private static func extractTrackName(from header: AXUIElement) -> String {
        // Logic Pro 12: AXTextField has the track name in its AXDescription attribute,
        // NOT in AXValue (which is 0). Try desc first.
        if let field = AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 3) {
            if let desc = AXHelpers.getDescription(field), !desc.isEmpty {
                return desc
            }
            if let name = extractTextValue(field), !name.isEmpty, name != "0" {
                return name
            }
        }
        // Try static text
        if let text = AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 3),
           let name = extractTextValue(text), !name.isEmpty {
            return name
        }
        // Fallback: parse name from the header's own description (e.g. "Track 1 \"Audio 1\"")
        if let desc = AXHelpers.getDescription(header) {
            if let start = desc.firstIndex(of: "\u{201C}") ?? desc.firstIndex(of: "\""),
               let end = desc.lastIndex(of: "\u{201D}") ?? desc.lastIndex(of: "\""),
               start < end {
                let nameStart = desc.index(after: start)
                return String(desc[nameStart..<end])
            }
        }
        return AXHelpers.getTitle(header) ?? "Untitled"
    }

    /// Extract toggle state from an AXCheckBox (Logic Pro 12) or AXButton by exact description.
    private static func extractToggleState(from header: AXUIElement, description: String) -> Bool? {
        // Logic Pro 12: track controls are AXCheckBox with exact desc match
        if let cb = AXHelpers.findDescendant(of: header, role: kAXCheckBoxRole, description: description, maxDepth: 4) {
            return extractCheckboxState(cb) ?? extractButtonState(cb)
        }
        // Legacy fallback: AXButton with description prefix
        let buttons = AXHelpers.findAllDescendants(of: header, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            if desc.hasPrefix(description) || desc.lowercased().contains(description.lowercased()) {
                return extractButtonState(button)
            }
        }
        return nil
    }

    /// Extract "Has Focus" (selected) state from an AXRadioButton in the track header.
    /// Logic Pro 12 uses AXRadioButton desc="Has Focus" with value 0/1 instead of kAXSelectedAttribute.
    private static func extractHasFocus(from header: AXUIElement) -> Bool? {
        if let radio = AXHelpers.findDescendant(of: header, role: kAXRadioButtonRole, description: "Has Focus", maxDepth: 4) {
            if let value = AXHelpers.getValue(radio) as? NSNumber {
                return value.intValue != 0
            }
        }
        // Legacy fallback
        return extractSelectedState(header)
    }

    private static func inferTrackType(from header: AXUIElement) -> TrackType {
        // Attempt to infer type from icon description or element identifiers
        let desc = AXHelpers.getDescription(header)?.lowercased() ?? ""
        let title = AXHelpers.getTitle(header)?.lowercased() ?? ""
        let combined = desc + " " + title

        if combined.contains("audio") { return .audio }
        if combined.contains("instrument") || combined.contains("software") { return .softwareInstrument }
        if combined.contains("drummer") { return .drummer }
        if combined.contains("external") || combined.contains("midi") { return .externalMIDI }
        if combined.contains("aux") { return .aux }
        if combined.contains("bus") { return .bus }
        if combined.contains("master") || combined.contains("stereo out") { return .master }
        return .unknown
    }

    private static func extractTrackColor(from header: AXUIElement) -> String? {
        // Logic Pro may expose color via a custom attribute or the element's description
        let desc = AXHelpers.getDescription(header) ?? ""
        if desc.lowercased().contains("color") {
            return desc
        }
        return nil
    }
}
