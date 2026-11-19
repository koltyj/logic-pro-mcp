import ApplicationServices
import CoreGraphics
import Foundation

/// What to bounce and where. Parsed from channel params; pure so it can be tested.
struct BounceRequest: Equatable, Sendable {
    enum FileType: String, CaseIterable, Sendable {
        case wav, aiff, caf

        /// Title Logic Pro shows in the File Type popup. Not localized.
        var popupTitle: String {
            switch self {
            case .wav: "WAVE"
            case .aiff: "AIFF"
            case .caf: "CAF"
            }
        }

        var fileExtension: String {
            switch self {
            case .wav: "wav"
            case .aiff: "aif"
            case .caf: "caf"
            }
        }
    }

    static let bitDepths = [16, 24, 32]
    static let sampleRates = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    var directory: String
    /// File name without extension.
    var baseName: String
    var fileType: FileType = .wav
    var bitDepth: Int?
    var sampleRate: Int?
    var overwrite = false
    var timeoutSeconds: Double = 600

    /// Checks that depend on the file system. Run before opening the Bounce
    /// dialog, so a call that cannot succeed never leaves a dialog on screen.
    func preflight(fileManager fm: FileManager = .default) -> BounceError? {
        var isDir = ObjCBool(false)
        guard fm.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return BounceError("directory does not exist: \(directory)")
        }
        guard fm.isWritableFile(atPath: directory) else {
            return BounceError("directory is not writable: \(directory)")
        }
        if fm.fileExists(atPath: outputPath) && !overwrite {
            return BounceError("\(outputPath) already exists; pass overwrite: true to replace it")
        }
        return nil
    }

    var outputPath: String {
        (directory as NSString).appendingPathComponent("\(baseName).\(fileType.fileExtension)")
    }

    /// Parse and validate. Returns an error message on failure.
    static func parse(_ params: [String: String]) -> Result<BounceRequest, BounceError> {
        guard let rawDir = params["directory"], !rawDir.isEmpty else {
            return .failure(.init("'directory' is required"))
        }
        let directory = (rawDir as NSString).expandingTildeInPath
        guard directory.hasPrefix("/") else {
            return .failure(.init("'directory' must be an absolute path"))
        }

        var fileType = FileType.wav
        if let raw = params["file_type"]?.lowercased(), !raw.isEmpty {
            let normalized = raw == "wave" ? "wav" : (raw == "aif" ? "aiff" : raw)
            guard let parsed = FileType(rawValue: normalized) else {
                return .failure(.init("'file_type' must be one of: wav, aiff, caf"))
            }
            fileType = parsed
        }

        guard var name = params["filename"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return .failure(.init("'filename' is required"))
        }
        guard !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
            return .failure(.init("'filename' must be a plain file name, not a path"))
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["wav", "wave", "aif", "aiff", "caf"].contains(ext) {
            name = (name as NSString).deletingPathExtension
        }
        guard !name.isEmpty, name.count <= 200 else {
            return .failure(.init("'filename' must be 1–200 characters"))
        }

        var request = BounceRequest(directory: directory, baseName: name, fileType: fileType)

        if let raw = params["bit_depth"], !raw.isEmpty {
            guard let depth = Int(raw), bitDepths.contains(depth) else {
                return .failure(.init("'bit_depth' must be 16, 24 or 32 (32 = float)"))
            }
            request.bitDepth = depth
        }
        if let raw = params["sample_rate"], !raw.isEmpty {
            guard let rate = Int(raw), sampleRates.contains(rate) else {
                return .failure(.init("'sample_rate' must be one of \(sampleRates.map(String.init).joined(separator: ", "))"))
            }
            request.sampleRate = rate
        }
        if let raw = params["overwrite"], !raw.isEmpty {
            guard let flag = Bool(raw) else { return .failure(.init("'overwrite' must be true or false")) }
            request.overwrite = flag
        }
        if let raw = params["timeout_seconds"], !raw.isEmpty {
            guard let seconds = Double(raw), seconds >= 5, seconds <= 3_600 else {
                return .failure(.init("'timeout_seconds' must be between 5 and 3600"))
            }
            request.timeoutSeconds = seconds
        }
        return .success(request)
    }
}

struct BounceError: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Which setting a popup in the Bounce dialog controls, inferred from its
/// current value. The popups carry no AX description, and their neighbouring
/// labels are localized, but these values read the same in every language.
enum BouncePopupKind: Equatable {
    case fileType, bitDepth, sampleRate, other

    static func classify(value: String?) -> BouncePopupKind {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return .other
        }
        if BounceRequest.FileType.allCases.contains(where: {
            $0.popupTitle.caseInsensitiveCompare(value) == .orderedSame
        }) {
            return .fileType
        }
        if value.range(of: "kHz", options: .caseInsensitive) != nil { return .sampleRate }
        if let number = leadingNumber(value), [8, 16, 20, 24, 32].contains(Int(number)) {
            return .bitDepth
        }
        return .other
    }

    /// Does a popup menu item title match the requested value for this kind?
    static func title(_ title: String, matches kind: BouncePopupKind, request: BounceRequest) -> Bool {
        switch kind {
        case .fileType:
            return title.caseInsensitiveCompare(request.fileType.popupTitle) == .orderedSame
        case .bitDepth:
            guard let depth = request.bitDepth, let number = leadingNumber(title) else { return false }
            return Int(number) == depth && number == number.rounded()
        case .sampleRate:
            guard let rate = request.sampleRate, let number = leadingNumber(title),
                  title.range(of: "kHz", options: .caseInsensitive) != nil else { return false }
            return abs(number * 1_000 - Double(rate)) < 1
        case .other:
            return false
        }
    }

    static func leadingNumber(_ text: String) -> Double? {
        let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }
}

/// Drives Logic Pro's Bounce dialog and the save panel that follows it.
///
/// Expects the Bounce dialog to have been opened already (Cmd+B). Every step
/// locates controls by role, AX identifier or value rather than by localized
/// text, so the flow works in any UI language.
enum AXBounce {
    static func run(params: [String: String]) async -> ChannelResult {
        let request: BounceRequest
        switch BounceRequest.parse(params) {
        case .success(let parsed): request = parsed
        case .failure(let error): return .error(error.message)
        }
        do {
            let path = try await run(request)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            let json: [String: Any] = ["path": path, "bytes": size]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
            return .success(String(decoding: data, as: UTF8.self))
        } catch let error as BounceError {
            return .error("Bounce failed: \(error.message)")
        } catch {
            return .error("Bounce failed: \(error)")
        }
    }

    static func run(_ request: BounceRequest) async throws -> String {
        let fm = FileManager.default
        let output = request.outputPath
        guard let pid = ProcessUtils.logicProPID() else { throw BounceError("Logic Pro is not running") }
        let app = AXHelpers.axApp(pid: pid)
        if let problem = request.preflight() {
            if let dialog = bounceDialog(app) { cancelDialog(dialog) }
            throw problem
        }

        // 1. Bounce dialog.
        guard let dialog = await AXHelpers.poll(seconds: 5, { bounceDialog(app) }) else {
            throw BounceError("the Bounce dialog did not appear (focused window: \(focusedTitle(app)))")
        }
        let okButton: AXUIElement
        do {
            try await configure(dialog: dialog, request: request)
            guard let button = defaultButton(of: dialog) else {
                throw BounceError("cannot find the Bounce dialog's OK button")
            }
            okButton = button
        } catch {
            cancelDialog(dialog)
            throw error
        }
        AXHelpers.performAction(okButton, kAXPressAction)

        // 2. Save panel.
        guard let panel = await AXHelpers.poll(seconds: 5, { savePanel(app) }) else {
            throw BounceError("the save panel did not appear")
        }
        do {
            try await choose(directory: request.directory, in: panel)
            guard let nameField = AXHelpers.findDescendant(
                of: panel, identifier: "saveAsNameTextField", maxDepth: 6
            ) else { throw BounceError("cannot find the file name field") }
            AXHelpers.setAttribute(nameField, kAXValueAttribute, request.baseName as CFString)
            guard let save = AXHelpers.findDescendant(of: panel, identifier: "OKButton", maxDepth: 6) else {
                throw BounceError("cannot find the save panel's Bounce button")
            }
            if request.overwrite, fm.fileExists(atPath: output) {
                try? fm.removeItem(atPath: output)
            }
            let started = Date()
            AXHelpers.performAction(save, kAXPressAction)

            // A "replace?" alert can still appear if Logic expects a different name.
            if let replace = await AXHelpers.poll(seconds: 1.5, { replaceButton(app) }) {
                guard request.overwrite else {
                    throw BounceError("Logic asked to replace an existing file; pass overwrite: true")
                }
                AXHelpers.performAction(replace, kAXPressAction)
            }

            // 3. Wait for the file to finish.
            return try await waitForOutput(request: request, since: started, app: app)
        } catch {
            cancel(panel)
            throw error
        }
    }

    // MARK: - Dialog

    /// The focused window when it is the Bounce dialog: the one with a table of
    /// destination checkboxes identified "enable".
    static func bounceDialog(_ app: AXUIElement) -> AXUIElement? {
        guard let window: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute) else { return nil }
        let hasDestinations = AXHelpers.findDescendant(
            of: window, role: kAXCheckBoxRole, identifier: "enable", maxDepth: 6
        ) != nil
        return hasDestinations ? window : nil
    }

    static func configure(dialog: AXUIElement, request: BounceRequest) async throws {
        // Destinations: row 0 is PCM; turn it on and every other destination off,
        // so exactly one file is written.
        guard let table = AXHelpers.findDescendant(of: dialog, role: kAXTableRole, maxDepth: 3) else {
            throw BounceError("cannot find the destination list")
        }
        let rows = AXHelpers.getChildren(table).filter { AXHelpers.getRole($0) == kAXRowRole }
        guard !rows.isEmpty else { throw BounceError("the destination list is empty") }
        for (index, row) in rows.enumerated() {
            guard let box = AXHelpers.findDescendant(
                of: row, role: kAXCheckBoxRole, identifier: "enable", maxDepth: 3
            ) else { continue }
            let want = index == 0
            if AXValueExtractors.extractCheckboxState(box) != want {
                AXHelpers.performAction(box, kAXPressAction)
                let settled = await AXHelpers.poll(seconds: 2) {
                    AXValueExtractors.extractCheckboxState(box) == want ? true : nil
                }
                guard settled != nil else {
                    throw BounceError("could not turn destination \(index) \(want ? "on" : "off")")
                }
            }
        }
        // Show the PCM settings.
        AXHelpers.setAttribute(rows[0], kAXSelectedAttribute, kCFBooleanTrue)

        let popups = AXHelpers.findAllDescendants(of: dialog, role: kAXPopUpButtonRole, maxDepth: 4)
        func popup(_ kind: BouncePopupKind) -> AXUIElement? {
            popups.first { BouncePopupKind.classify(value: AXHelpers.getValue($0) as? String) == kind }
        }

        try await select(.fileType, on: popup(.fileType), request: request)
        if request.bitDepth != nil { try await select(.bitDepth, on: popup(.bitDepth), request: request) }
        if request.sampleRate != nil { try await select(.sampleRate, on: popup(.sampleRate), request: request) }
    }

    static func select(_ kind: BouncePopupKind, on popup: AXUIElement?, request: BounceRequest) async throws {
        guard let popup else { throw BounceError("cannot find the \(kind) popup") }
        let current = AXHelpers.getValue(popup) as? String ?? ""
        if BouncePopupKind.title(current, matches: kind, request: request) { return }

        AXHelpers.performAction(popup, kAXPressAction)
        // The menu is built after the press returns; wait for its items.
        let items = await AXHelpers.poll(seconds: 2) { () -> [AXUIElement]? in
            let found = AXHelpers.findAllDescendants(of: popup, role: kAXMenuItemRole, maxDepth: 3)
            return found.isEmpty ? nil : found
        } ?? []
        guard let item = items.first(where: {
            BouncePopupKind.title(AXHelpers.getTitle($0) ?? "", matches: kind, request: request)
        }) else {
            AXHelpers.performAction(popup, kAXCancelAction)
            let titles = items.compactMap { AXHelpers.getTitle($0) }.filter { !$0.isEmpty }
            throw BounceError("no \(kind) option matches the request (options: \(titles.joined(separator: ", ")))")
        }
        AXHelpers.performAction(item, kAXPressAction)
        // The popup's AXValue updates asynchronously after the menu closes.
        let settled = await AXHelpers.poll(seconds: 2) { () -> Bool? in
            let value = AXHelpers.getValue(popup) as? String ?? ""
            return BouncePopupKind.title(value, matches: kind, request: request) ? true : nil
        }
        guard settled != nil else {
            let after = AXHelpers.getValue(popup) as? String ?? ""
            throw BounceError("\(kind) is \"\(after)\" after selecting it")
        }
    }

    static func cancelDialog(_ window: AXUIElement) {
        if let button: AXUIElement = AXHelpers.getAttribute(window, kAXCancelButtonAttribute) {
            AXHelpers.performAction(button, kAXPressAction)
        }
    }

    static func defaultButton(of window: AXUIElement) -> AXUIElement? {
        if let button: AXUIElement = AXHelpers.getAttribute(window, kAXDefaultButtonAttribute) {
            return button
        }
        return AXHelpers.findDescendant(of: window, role: kAXButtonRole, title: AXLabels.ok, maxDepth: 2)
    }

    // MARK: - Save panel

    static func savePanel(_ app: AXUIElement) -> AXUIElement? {
        guard let window: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute) else { return nil }
        if AXHelpers.getIdentifier(window) == "save-panel" { return window }
        return AXHelpers.findDescendant(of: window, identifier: "saveAsNameTextField", maxDepth: 6) != nil
            ? window : nil
    }

    /// Point the save panel at `directory` with the standard Go To Folder sheet (Cmd+Shift+G).
    static func choose(directory: String, in panel: AXUIElement) async throws {
        guard ProcessUtils.isLogicProFrontmost || ProcessUtils.activateLogicPro() else {
            throw BounceError("cannot bring Logic Pro to the front")
        }
        try await Task.sleep(for: .milliseconds(150))
        try postKeyToFrontmost(5, flags: [.maskCommand, .maskShift]) // G
        guard let field = await AXHelpers.poll(seconds: 3, {
            AXHelpers.findDescendant(of: panel, identifier: "PathTextField", maxDepth: 4)
        }) else {
            throw BounceError("the Go To Folder sheet did not open")
        }
        AXHelpers.setAttribute(field, kAXValueAttribute, directory as CFString)
        try await Task.sleep(for: .milliseconds(300))
        try postKeyToFrontmost(36, flags: []) // Return
        let closed = await AXHelpers.poll(seconds: 3) {
            AXHelpers.findDescendant(of: panel, identifier: "GoToWindow", maxDepth: 2) == nil ? true : nil
        }
        guard closed != nil else { throw BounceError("the Go To Folder sheet did not close") }

        // Confirm the panel landed in the folder: the "Where" popup shows its display name.
        if let whereButton = AXHelpers.findDescendant(of: panel, identifier: "where popup", maxDepth: 4),
           let shown = AXHelpers.getValue(whereButton) as? String {
            let expected = FileManager.default.displayName(atPath: directory)
            let plain = (directory as NSString).lastPathComponent
            // displayName is localized for this process, which may differ from
            // Logic's UI language, so a mismatch is only logged. A wrong folder
            // still surfaces as a timeout, because the file is looked for in
            // `directory` only.
            if shown != expected && shown != plain {
                Log.warn("Save panel shows \"\(shown)\"; expected \(directory)", subsystem: "ax")
            }
        }
    }

    static func replaceButton(_ app: AXUIElement) -> AXUIElement? {
        guard let window: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute) else { return nil }
        return AXHelpers.findDescendant(of: window, role: kAXButtonRole, title: AXLabels.replace, maxDepth: 4)
    }

    static func cancel(_ panel: AXUIElement) {
        if let button = AXHelpers.findDescendant(of: panel, identifier: "CancelButton", maxDepth: 6) {
            AXHelpers.performAction(button, kAXPressAction)
        }
    }

    // MARK: - Completion

    /// Wait until the bounced file exists, has stopped growing, and Logic's
    /// progress window is gone (the main window has focus again).
    static func waitForOutput(request: BounceRequest, since start: Date, app: AXUIElement) async throws -> String {
        let deadline = Date().addingTimeInterval(request.timeoutSeconds)
        var lastSize: Int64 = -1
        var stableSince: Date?
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            guard let path = newestOutput(request: request, since: start) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 0, size == lastSize {
                stableSince = stableSince ?? Date()
            } else {
                stableSince = nil
            }
            lastSize = size
            if let stableSince, Date().timeIntervalSince(stableSince) >= 1.5, mainWindowFocused(app) {
                return path
            }
        }
        throw BounceError("timed out after \(Int(request.timeoutSeconds))s waiting for \(request.outputPath)")
    }

    /// Logic may append the extension itself, so accept "name.wav" and any
    /// "name*.wav" written after the bounce started.
    static func newestOutput(request: BounceRequest, since start: Date) -> String? {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: request.outputPath),
           let modified = attrs[.modificationDate] as? Date, modified >= start.addingTimeInterval(-1) {
            return request.outputPath
        }
        guard let names = try? fm.contentsOfDirectory(atPath: request.directory) else { return nil }
        let ext = request.fileType.fileExtension
        return names
            .filter { $0.hasPrefix(request.baseName) && ($0 as NSString).pathExtension.lowercased() == ext }
            .map { (request.directory as NSString).appendingPathComponent($0) }
            .compactMap { path -> (String, Date)? in
                guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      date >= start.addingTimeInterval(-1) else { return nil }
                return (path, date)
            }
            .max { $0.1 < $1.1 }?.0
    }

    static func mainWindowFocused(_ app: AXUIElement) -> Bool {
        guard let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute),
              let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute) else { return false }
        return CFEqual(focused, main)
    }

    static func focusedTitle(_ app: AXUIElement) -> String {
        guard let window: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute) else { return "none" }
        return AXHelpers.getTitle(window) ?? AXHelpers.getDescription(window) ?? "untitled"
    }

    // MARK: - Utilities

    /// Post a keystroke through the HID event tap.
    ///
    /// The save panel is drawn by a separate system process
    /// (openAndSavePanelService), so events posted to Logic Pro's PID never
    /// reach it. A HID-level event goes to whatever is frontmost, so this
    /// refuses to post unless Logic Pro is the active app.
    static func postKeyToFrontmost(_ keyCode: CGKeyCode, flags: CGEventFlags) throws {
        guard ProcessUtils.isLogicProFrontmost else {
            throw BounceError("Logic Pro is no longer the front app; not sending keystrokes elsewhere")
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw BounceError("cannot create keyboard events")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
