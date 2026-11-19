import Foundation

/// A user-visible Accessibility string that Logic Pro localizes.
///
/// Logic Pro exposes most of its AX descriptions and titles in the UI language,
/// so a hard-coded English string only works on English systems. An `AXLabel`
/// carries every known spelling of one string; lookups accept any of them.
struct AXLabel: Sendable, Hashable, CustomStringConvertible {
    /// Stable key, used for overrides and log messages.
    let key: String
    /// All known spellings. The first is the English one.
    let variants: [String]

    var description: String { variants.first ?? key }

    /// Exact match against any variant, ignoring surrounding whitespace and case.
    func matches(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        return variants.contains {
            value.compare($0, options: [.caseInsensitive]) == .orderedSame
        }
    }

    /// True when `value` starts with any variant, e.g. "Mute (M)" for "Mute".
    func isPrefix(of value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return variants.contains {
            value.range(of: $0, options: [.caseInsensitive, .anchored]) != nil
        }
    }

    /// True when `value` contains any variant.
    func isContained(in value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return variants.contains { value.range(of: $0, options: .caseInsensitive) != nil }
    }
}

/// The localized strings the AX layer relies on.
///
/// To add a language, append its spellings to each entry below (collect them
/// with `swift Scripts/ax-dump.swift`). Users can also supply extra spellings
/// without rebuilding by pointing `LOGIC_PRO_MCP_AX_LABELS` at a JSON file of
/// the form `{"mute": ["Stumm"], "mixer": ["Mischpult"]}`.
enum AXLabels {
    // Spellings below were read from Logic Pro 12.4 (English and Traditional
    // Chinese). Only add strings you have seen in a real AX dump.

    // MARK: Main window regions
    static let controlBar = make("controlBar", ["Control Bar", "控制列"])
    static let tracksHeader = make("tracksHeader", ["Tracks header", "音軌 標題"])
    static let mixer = make("mixer", ["Mixer", "混音器"])

    // MARK: Channel strip controls
    // The stand-alone Mixer window (Cmd+2) uses the untranslated key "volumeFader".
    static let volumeFader = make("volumeFader", ["volume fader", "volumeFader", "音量推子"])
    static let pan = make("pan", ["pan", "聲像"])
    static let eq = make("eq", ["EQ", "等化器"])
    static let masterStrip = make("masterStrip", ["Master"])
    static let stereoOutStrip = make("stereoOutStrip", ["Stereo Out"])
    /// Checkbox inside each loaded plugin slot.
    static let bypass = make("bypass", ["Bypass", "略過"])
    /// AXValue of a channel-strip button that is switched on (e.g. EQ).
    static let onState = make("onState", ["on", "開啟"])

    // MARK: Track header controls
    static let mute = make("mute", ["Mute", "靜音"])
    static let solo = make("solo", ["Solo", "獨奏"])
    static let recordEnable = make("recordEnable", ["Record Enable"])
    static let record = make("record", ["Record", "錄音"])
    static let hasFocus = make("hasFocus", ["Has Focus", "包含焦點"])

    // MARK: Transport
    static let cycle = make("cycle", ["Cycle", "循環"])
    static let metronome = make("metronome", ["Metronome", "節拍器卡嗒聲"])
    static let tempo = make("tempo", ["tempo", "bpm", "拍速"])

    /// Map a legacy English control name to its label, so callers that still
    /// pass "Cycle"/"Mute"/... keep working in every language.
    static func label(forEnglishName name: String) -> AXLabel {
        let known: [AXLabel] = [
            controlBar, tracksHeader, mixer, volumeFader, pan, eq, masterStrip,
            stereoOutStrip, bypass, onState, mute, solo, recordEnable, record,
            hasFocus, cycle, metronome, tempo,
        ]
        return known.first { $0.variants.first?.caseInsensitiveCompare(name) == .orderedSame }
            ?? AXLabel(key: name, variants: [name])
    }

    // MARK: - Overrides

    static let overridesEnvironmentKey = "LOGIC_PRO_MCP_AX_LABELS"

    private static let overrides: [String: [String]] = loadOverrides(
        path: ProcessInfo.processInfo.environment[overridesEnvironmentKey]
    )

    static func loadOverrides(path: String?) -> [String: [String]] {
        guard let path, !path.isEmpty else { return [:] }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            Log.warn("Cannot read \(overridesEnvironmentKey) file at \(path)", subsystem: "ax")
            return [:]
        }
        return parseOverrides(data) ?? {
            Log.warn("Ignoring \(overridesEnvironmentKey): expected {\"key\": [\"label\", ...]}", subsystem: "ax")
            return [:]
        }()
    }

    static func parseOverrides(_ data: Data) -> [String: [String]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var result: [String: [String]] = [:]
        for (key, value) in object {
            if let list = value as? [String] {
                result[key] = list
            } else if let single = value as? String {
                result[key] = [single]
            }
        }
        return result
    }

    static func make(_ key: String, _ builtIn: [String]) -> AXLabel {
        merge(key: key, builtIn: builtIn, extra: overrides[key] ?? [])
    }

    static func merge(key: String, builtIn: [String], extra: [String]) -> AXLabel {
        var seen = Set<String>()
        let variants = (builtIn + extra).filter { seen.insert($0.lowercased()).inserted }
        return AXLabel(key: key, variants: variants)
    }
}
