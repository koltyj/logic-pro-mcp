import Foundation
import ApplicationServices
#if canImport(Darwin)
import Darwin
#endif

/// `LogicProMCP dump-tracks` — AX archaeology utility for the track-list bug.
/// Walks the Logic main window, enumerates every AXOutline / AXList / AXScrollArea,
/// prints (role, identifier, description, child count, first 5 row titles).
/// Use to find the real desktop-Logic-Pro track-list identifier vs the Region Inspector.
enum DumpTracksCommand {
    static func run() -> Int {
        setvbuf(stdout, nil, _IOLBF, 0)

        guard ProcessUtils.isLogicProRunning, let pid = ProcessUtils.logicProPID() else {
            print("Logic Pro is not running.")
            return 1
        }
        let app = AXHelpers.axApp(pid: pid)
        guard let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute), !windows.isEmpty else {
            print("No windows found on Logic Pro pid \(pid).")
            return 1
        }

        for (winIdx, window) in windows.enumerated() {
            let title = AXHelpers.getTitle(window) ?? "<no title>"
            let role = AXHelpers.getRole(window) ?? "<no role>"
            print("=== Window[\(winIdx)] role=\(role) title=\"\(title)\" ===")
            dumpContainers(window, depth: 0, maxDepth: 10)
            print("")
        }

        // Verification — call the actual koltyj helpers and print what they return.
        print("=== Verification: AXLogicProElements.getTrackHeaders() + allTrackHeaders() ===")
        if let container = AXLogicProElements.getTrackHeaders() {
            let containerDesc: String = AXHelpers.getAttribute(container, kAXDescriptionAttribute) ?? "<no desc>"
            let containerRole = AXHelpers.getRole(container) ?? "?"
            print("Container: [\(containerRole)] desc=\"\(containerDesc)\"")
        } else {
            print("Container: NIL")
        }
        let headers = AXLogicProElements.allTrackHeaders()
        print("Track headers found: \(headers.count)")
        for (i, h) in headers.enumerated() {
            let r = AXHelpers.getRole(h) ?? "?"
            let d: String = AXHelpers.getAttribute(h, kAXDescriptionAttribute) ?? ""
            print("  [\(i)] role=\(r) desc=\"\(d)\"")
        }
        print("")
        print("=== Verification: AXValueExtractors.extractTrackState() per track ===")
        for (i, h) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(from: h, index: i)
            print("  Track[\(i)] name=\"\(track.name)\" type=\(track.type) muted=\(track.isMuted) soloed=\(track.isSoloed) armed=\(track.isArmed) volume=\(track.volume) pan=\(track.pan)")
        }
        return 0
    }

    private static let containerRoles: Set<String> = [
        kAXOutlineRole as String,
        kAXListRole as String,
        kAXScrollAreaRole as String,
        kAXTableRole as String,
    ]

    private static func dumpContainers(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }
        let role = AXHelpers.getRole(element) ?? ""
        let desc: String = AXHelpers.getAttribute(element, kAXDescriptionAttribute) ?? ""
        // Any element with "Tracks header" / "Tracks contents" in description: deep dump
        if desc.contains("Tracks header") || desc.contains("Tracks contents") {
            print(">>> DEEP DUMP: [\(role)] desc=\"\(desc)\" <<<")
            dumpDeep(element, depth: 0, maxDepth: 15)
            print(">>> END DEEP DUMP <<<")
        }
        if containerRoles.contains(role) {
            let identifier: String = AXHelpers.getIdentifier(element) ?? "<no id>"
            let title = AXHelpers.getTitle(element) ?? "<no title>"
            let children = AXHelpers.getChildren(element)
            let indent = String(repeating: "  ", count: depth)
            print("\(indent)[\(role)] id=\(identifier) desc=\(desc.isEmpty ? "<no desc>" : desc) title=\(title) children=\(children.count)")
            for (i, row) in children.prefix(5).enumerated() {
                let rowRole = AXHelpers.getRole(row) ?? "?"
                let rowTitle = AXHelpers.getTitle(row) ?? "<no title>"
                let rowDesc: String = AXHelpers.getAttribute(row, kAXDescriptionAttribute) ?? "<no desc>"
                let rowVal: String = AXHelpers.getAttribute(row, kAXValueAttribute) ?? "<no val>"
                print("\(indent)  row[\(i)] role=\(rowRole) title=\"\(rowTitle)\" desc=\"\(rowDesc)\" val=\"\(rowVal)\"")
            }
        }
        for child in AXHelpers.getChildren(element) {
            dumpContainers(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    private static func dumpDeep(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }
        let role = AXHelpers.getRole(element) ?? "?"
        let title = AXHelpers.getTitle(element) ?? ""
        let desc: String = AXHelpers.getAttribute(element, kAXDescriptionAttribute) ?? ""
        let value: String = AXHelpers.getAttribute(element, kAXValueAttribute) ?? ""
        let id: String = AXHelpers.getIdentifier(element) ?? ""
        let indent = String(repeating: "  ", count: depth)
        let bits = [
            id.isEmpty ? nil : "id=\(id)",
            title.isEmpty ? nil : "title=\"\(title)\"",
            desc.isEmpty ? nil : "desc=\"\(desc)\"",
            value.isEmpty ? nil : "val=\"\(value)\""
        ].compactMap { $0 }.joined(separator: " ")
        print("\(indent)[\(role)] \(bits)")
        for child in AXHelpers.getChildren(element) {
            dumpDeep(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}
