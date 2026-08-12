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
        if let string = value as? String {
            return string == "1" || string.lowercased() == "true"
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
    static func extractTrackState(from header: AXUIElement, index: Int) -> TrackState {
        let name = extractTrackName(from: header)
        let muted = extractToggleState(from: header, description: "Mute") ?? false
        let soloed = extractToggleState(from: header, description: "Solo") ?? false
        let armed = extractToggleState(from: header, description: "Record Enable")
            ?? extractToggleState(from: header, description: "Record")
            ?? false
        let selected = isTrackSelected(header)
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
    static func extractTransportState(from transport: AXUIElement) -> TransportState {
        var state = TransportState()

        var resolvedPlay = false
        var resolvedRecord = false
        var resolvedCycle = false
        var resolvedMetronome = false

        let checkboxes = AXHelpers.findAllDescendants(of: transport, role: kAXCheckBoxRole, maxDepth: 4)
        for checkbox in checkboxes {
            let desc = AXHelpers.getDescription(checkbox) ?? AXHelpers.getTitle(checkbox) ?? ""
            let pressed = extractCheckboxState(checkbox) ?? extractButtonState(checkbox) ?? false
            let descLower = desc.lowercased()

            if !resolvedPlay && descLower == "play" {
                state.isPlaying = pressed
                resolvedPlay = true
            } else if !resolvedRecord && descLower == "record" {
                state.isRecording = pressed
                resolvedRecord = true
            } else if !resolvedCycle && descLower == "cycle" {
                state.isCycleEnabled = pressed
                resolvedCycle = true
            } else if !resolvedMetronome && (descLower.contains("metronome") || descLower.contains("click")) {
                state.isMetronomeEnabled = pressed
                resolvedMetronome = true
            }
        }

        // Legacy fallback: resolve only controls absent from the Logic Pro 12 checkbox tree.
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            let pressed = extractButtonState(button) ?? false
            let descLower = desc.lowercased()

            if !resolvedPlay && descLower.contains("play") {
                state.isPlaying = pressed
                resolvedPlay = true
            } else if !resolvedRecord && descLower.contains("record") && !descLower.contains("arm") {
                state.isRecording = pressed
                resolvedRecord = true
            } else if !resolvedCycle && (descLower.contains("cycle") || descLower.contains("loop")) {
                state.isCycleEnabled = pressed
                resolvedCycle = true
            } else if !resolvedMetronome && (descLower.contains("metronome") || descLower.contains("click")) {
                state.isMetronomeEnabled = pressed
                resolvedMetronome = true
            }
        }

        let sliders = AXHelpers.findAllDescendants(of: transport, role: kAXSliderRole, maxDepth: 4)
        var resolvedTempo = false
        var resolvedPosition = false
        var bar: Int?
        var beat: Int?
        var division: Int?
        var tick: Int?
        for slider in sliders {
            guard let value = extractSliderValue(slider) else { continue }
            switch AXHelpers.getDescription(slider)?.lowercased() {
            case "tempo":
                state.tempo = value
                resolvedTempo = true
            case "bar": bar = Int(value)
            case "beat": beat = Int(value)
            case "division": division = Int(value)
            case "tick": tick = Int(value)
            default: break
            }
        }
        if let bar, let beat, let division, let tick {
            state.position = "\(bar).\(beat).\(division).\(tick)"
            resolvedPosition = true
        }

        // Legacy fallback: text-based tempo and position.
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXStaticTextRole, maxDepth: 4)
        for text in texts {
            guard let value = extractTextValue(text) else { continue }
            let desc = AXHelpers.getDescription(text) ?? ""
            let descLower = desc.lowercased()

            if !resolvedTempo, descLower.contains("tempo") || descLower.contains("bpm") {
                if let tempo = Double(value.replacingOccurrences(of: " BPM", with: "")) {
                    state.tempo = tempo
                    resolvedTempo = true
                }
            } else if !resolvedPosition, value.filter({ $0 == "." }).count >= 2 {
                state.position = value
                resolvedPosition = true
            } else if value.contains(":") {
                // Time format HH:MM:SS
                state.timePosition = value
            }
        }

        state.lastUpdated = Date()
        return state
    }

    // MARK: - Private helpers

    static func isTrackSelected(_ header: AXUIElement) -> Bool {
        extractHasFocus(from: header) ?? extractSelectedState(header) ?? false
    }

    private static func extractTrackName(from header: AXUIElement) -> String {
        if let field = AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 3) {
            if let description = AXHelpers.getDescription(field), !description.isEmpty {
                return description
            }
            if let name = extractTextValue(field), !name.isEmpty, name != "0" {
                return name
            }
        }
        // Legacy fallback: static text.
        if let text = AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 3),
           let name = extractTextValue(text), !name.isEmpty {
            return name
        }
        if let description = AXHelpers.getDescription(header),
           let start = description.firstIndex(of: "\"") ?? description.firstIndex(of: "\u{201C}"),
           let end = description.lastIndex(of: "\"") ?? description.lastIndex(of: "\u{201D}"),
           start < end {
            return String(description[description.index(after: start)..<end])
        }
        return AXHelpers.getTitle(header) ?? "Untitled"
    }

    private static func extractToggleState(from header: AXUIElement, description: String) -> Bool? {
        if let checkbox = AXHelpers.findDescendant(
            of: header, role: kAXCheckBoxRole, description: description, maxDepth: 4
        ) {
            return extractCheckboxState(checkbox) ?? extractButtonState(checkbox)
        }
        let buttons = AXHelpers.findAllDescendants(of: header, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            if desc.hasPrefix(description) || desc.lowercased().contains(description.lowercased()) {
                return extractButtonState(button)
            }
        }
        return nil
    }

    private static func extractHasFocus(from header: AXUIElement) -> Bool? {
        guard let focus = AXHelpers.findDescendant(
            of: header, role: kAXRadioButtonRole, description: "Has Focus", maxDepth: 4
        ) else {
            return nil
        }
        return extractSelectedState(focus) ?? extractButtonState(focus)
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
