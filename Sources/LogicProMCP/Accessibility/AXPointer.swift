import ApplicationServices
import CoreGraphics
import Foundation

/// Synthetic mouse input for Logic controls that ignore AXPress.
/// Logic 12's track header controls (Mute, Solo, Input Monitoring, name field)
/// report AXPress as handled but never act on it; a real click does.
enum AXPointer {
    /// Clicks the center of `element` `count` times, then restores the cursor.
    /// Returns false without clicking when another element is on top at that point.
    static func click(_ element: AXUIElement, count: Int = 1) -> Bool {
        scrollIntoView(element)
        guard let point = center(of: element), isTopmost(element, at: point) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location
        post(.mouseMoved, at: point, clickState: 0, source: source)
        usleep(120_000)
        // Logic ignores mouse events whose click state is 0, so every press carries its click count.
        for clickState in 1...max(count, 1) {
            post(.leftMouseDown, at: point, clickState: Int64(clickState), source: source)
            usleep(40_000)
            post(.leftMouseUp, at: point, clickState: Int64(clickState), source: source)
            usleep(60_000)
        }
        if let original {
            post(.mouseMoved, at: original, clickState: 0, source: source)
        }
        return true
    }
}

extension AXPointer {
    /// Posts a key press to the HID stream; the caller must have made Logic frontmost.
    static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }
}

private extension AXPointer {
    /// Pages the nearest enclosing scroll area until `element` is fully inside its visible frame.
    /// Off-screen track rows still report positions, but those points show other controls.
    static func scrollIntoView(_ element: AXUIElement) {
        guard let scrollArea = enclosingScrollArea(of: element) else { return }
        for _ in 0..<30 {
            guard let visible = frame(of: scrollArea), let target = frame(of: element) else { return }
            if target.minY >= visible.minY && target.maxY <= visible.maxY { return }
            let action = target.minY < visible.minY ? "AXScrollUpByPage" : "AXScrollDownByPage"
            // Logic scrolls but reports kAXErrorActionUnsupported, so judge by movement, not the return code.
            AXHelpers.performAction(scrollArea, action)
            usleep(80_000)
            if frame(of: element)?.minY == target.minY { return }
        }
    }

    static func enclosingScrollArea(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = AXHelpers.getAttribute(element, kAXParentAttribute)
        while let candidate = current {
            if AXHelpers.getRole(candidate) == kAXScrollAreaRole { return candidate }
            current = AXHelpers.getAttribute(candidate, kAXParentAttribute)
        }
        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = AXHelpers.getAttribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = AXHelpers.getAttribute(element, kAXSizeAttribute) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    static func center(of element: AXUIElement) -> CGPoint? {
        frame(of: element).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// True when hit-testing `point` lands on `element`, so a click can't hit another window.
    static func isTopmost(_ element: AXUIElement, at point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit
        ) == .success, let hit else {
            // Some custom-drawn controls (Marker List name cells) don't support AX hit-testing.
            // Fall back to the window server: the front-most window at the point must be Logic's.
            var owner: pid_t = 0
            AXUIElementGetPid(element, &owner)
            return frontWindowOwner(at: point) == owner
        }
        // The point may land on a child (e.g. the text inside a table cell): accept the target's descendants.
        var candidate: AXUIElement? = hit
        for _ in 0..<6 {
            guard let current = candidate else { break }
            if CFEqual(current, element) { return true }
            candidate = AXHelpers.getAttribute(current, kAXParentAttribute)
        }
        var hitPID: pid_t = 0
        var elementPID: pid_t = 0
        AXUIElementGetPid(hit, &hitPID)
        AXUIElementGetPid(element, &elementPID)
        return hitPID == elementPID
            && AXHelpers.getRole(hit) == AXHelpers.getRole(element)
            && AXHelpers.getDescription(hit) == AXHelpers.getDescription(element)
    }

    /// PID owning the front-most normal window containing `point` (window-server coordinates).
    static func frontWindowOwner(at point: CGPoint) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        }
        return nil
    }

    static func post(_ type: CGEventType, at point: CGPoint, clickState: Int64, source: CGEventSource?) {
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left
        ) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
    }
}
