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
    static func extractTrackState(from header: AXUIElement, index: Int) -> TrackState {
        let name = extractTrackName(from: header)
        let muted = extractTrackButtonState(from: header, prefix: "Mute") ?? false
        let soloed = extractTrackButtonState(from: header, prefix: "Solo") ?? false
        let armed = extractTrackButtonState(from: header, prefix: "Record") ?? false
        let selected = extractSelectedState(header) ?? false
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

        // Find and read transport button states (both AXButton and AXCheckBox —
        // Creator Studio renders Play/Record/Cycle/Metronome as AXCheckBox, not AXButton)
        var controls: [AXUIElement] = []
        for role in [kAXButtonRole, kAXCheckBoxRole] {
            controls.append(contentsOf: AXHelpers.findAllDescendants(of: transport, role: role, maxDepth: 4))
        }
        for button in controls {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            let pressed = extractButtonState(button) ?? false
            let descLower = desc.lowercased()

            if descLower.contains("play") {
                state.isPlaying = pressed
            } else if descLower.contains("record") && !descLower.contains("arm") {
                state.isRecording = pressed
            } else if descLower.contains("cycle") || descLower.contains("loop") {
                state.isCycleEnabled = pressed
            } else if descLower.contains("metronome") || descLower.contains("click") {
                state.isMetronomeEnabled = pressed
            }
        }

        // Find text fields for tempo, position
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXStaticTextRole, maxDepth: 4)
        for text in texts {
            guard let value = extractTextValue(text) else { continue }
            let desc = AXHelpers.getDescription(text) ?? ""
            let descLower = desc.lowercased()

            if descLower.contains("tempo") || descLower.contains("bpm") {
                if let tempo = Double(value.replacingOccurrences(of: " BPM", with: "")) {
                    state.tempo = tempo
                }
            } else if descLower.contains("position") || value.contains(".") && value.contains(":") == false {
                // Bar.Beat.Division.Tick format
                if value.filter({ $0 == "." }).count >= 2 {
                    state.position = value
                }
            } else if value.contains(":") {
                // Time format HH:MM:SS
                state.timePosition = value
            }
        }

        state.lastUpdated = Date()
        return state
    }

    // MARK: - Private helpers

    private static func extractTrackName(from header: AXUIElement) -> String {
        // Desktop Logic Pro 12.2: each AXLayoutItem track row has AXDescription
        // of the form `Track N "<name>"` (smart quotes \u{201C}/\u{201D}). Parse it.
        if let headerDesc: String = AXHelpers.getAttribute(header, kAXDescriptionAttribute),
           let name = parseQuotedTrackName(headerDesc) {
            return name
        }
        // Fallback: the AXTextField inside the row holds the name in its AXDescription
        // (its VALUE is empty unless actively being edited).
        if let field = AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 3) {
            if let fieldDesc: String = AXHelpers.getAttribute(field, kAXDescriptionAttribute), !fieldDesc.isEmpty {
                return fieldDesc
            }
            if let name = extractTextValue(field), !name.isEmpty {
                return name
            }
        }
        if let text = AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 3),
           let name = extractTextValue(text), !name.isEmpty {
            return name
        }
        return AXHelpers.getTitle(header) ?? "Untitled"
    }

    /// Parse a Logic Pro track row description of the form `Track 1 "Deluxe Classic"`.
    /// Logic uses smart quotes (\u{201C} / \u{201D}); accept straight quotes too as a safety net.
    private static func parseQuotedTrackName(_ desc: String) -> String? {
        let openQuotes: [Character] = ["\u{201C}", "\""]
        let closeQuotes: [Character] = ["\u{201D}", "\""]
        guard let openIdx = desc.firstIndex(where: { openQuotes.contains($0) }) else { return nil }
        let afterOpen = desc.index(after: openIdx)
        guard let closeIdx = desc[afterOpen...].firstIndex(where: { closeQuotes.contains($0) }) else { return nil }
        let name = String(desc[afterOpen..<closeIdx])
        return name.isEmpty ? nil : name
    }

    private static func extractTrackButtonState(from header: AXUIElement, prefix: String) -> Bool? {
        // Desktop Logic Pro 12.2 renders Mute/Solo/Record/Input as AXCheckBox; older
        // Logic versions and Creator Studio may use AXButton. Iterate both roles.
        let buttons = AXHelpers.findAllDescendants(of: header, role: kAXButtonRole, maxDepth: 4)
                    + AXHelpers.findAllDescendants(of: header, role: kAXCheckBoxRole, maxDepth: 4)
        for button in buttons {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            if desc.hasPrefix(prefix) || desc.lowercased().contains(prefix.lowercased()) {
                return extractButtonState(button)
            }
        }
        return nil
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
