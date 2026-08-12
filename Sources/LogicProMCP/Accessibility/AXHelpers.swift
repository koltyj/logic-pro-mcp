import ApplicationServices
import Foundation

/// Low-level wrappers around the macOS Accessibility (AX) API.
/// All functions are synchronous; they block briefly while the AX subsystem responds.
enum AXHelpers {
    /// Create an AXUIElement reference for a running application by PID.
    static func axApp(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// Get a typed attribute value from an AX element.
    /// Returns nil on any error (element gone, attribute missing, type mismatch).
    static func getAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }

    /// Set an attribute value on an AX element.
    /// Returns true on success, false on error.
    @discardableResult
    static func setAttribute(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        return result == .success
    }

    /// Get the children of an AX element.
    static func getChildren(_ element: AXUIElement) -> [AXUIElement] {
        guard let children: CFArray = getAttribute(element, kAXChildrenAttribute) else {
            return []
        }
        var result: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(children) {
            let ptr = CFArrayGetValueAtIndex(children, i)
            let child = unsafeBitCast(ptr, to: AXUIElement.self)
            result.append(child)
        }
        return result
    }

    /// Perform a named action on an AX element (e.g. kAXPressAction).
    /// Returns true on success.
    @discardableResult
    static func performAction(_ element: AXUIElement, _ action: String) -> Bool {
        let result = AXUIElementPerformAction(element, action as CFString)
        return result == .success
    }

    /// Get the role string of an element (e.g. "AXButton", "AXSlider").
    static func getRole(_ element: AXUIElement) -> String? {
        getAttribute(element, kAXRoleAttribute)
    }

    /// Get the title of an element.
    static func getTitle(_ element: AXUIElement) -> String? {
        getAttribute(element, kAXTitleAttribute)
    }

    /// Get the identifier of an element.
    static func getIdentifier(_ element: AXUIElement) -> String? {
        getAttribute(element, kAXIdentifierAttribute)
    }

    /// Find a child element matching optional criteria.
    /// Searches direct children only (not recursive) for performance.
    static func findChild(
        of element: AXUIElement,
        role: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        description: String? = nil
    ) -> AXUIElement? {
        let children = getChildren(element)
        for child in children {
            if let role, getRole(child) != role { continue }
            if let title, getTitle(child) != title { continue }
            if let identifier, getIdentifier(child) != identifier { continue }
            if let description, getDescription(child) != description { continue }
            return child
        }
        return nil
    }

    /// Recursive version of findChild. Searches the entire subtree via DFS.
    /// Use sparingly — deep trees can be slow.
    static func findDescendant(
        of element: AXUIElement,
        role: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        description: String? = nil,
        maxDepth: Int = 10
    ) -> AXUIElement? {
        guard maxDepth > 0 else { return nil }
        let children = getChildren(element)
        for child in children {
            let roleMatch = role == nil || getRole(child) == role
            let titleMatch = title == nil || getTitle(child) == title
            let idMatch = identifier == nil || getIdentifier(child) == identifier
            let descriptionMatch = description == nil || getDescription(child) == description
            if roleMatch && titleMatch && idMatch && descriptionMatch {
                return child
            }
            if let found = findDescendant(
                of: child, role: role, title: title, identifier: identifier, description: description,
                maxDepth: maxDepth - 1
            ) {
                return found
            }
        }
        return nil
    }

    /// Collect all descendants matching criteria. Useful for enumerating track headers, etc.
    static func findAllDescendants(
        of element: AXUIElement,
        role: String? = nil,
        maxDepth: Int = 5
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        collectDescendants(of: element, role: role, maxDepth: maxDepth, into: &results)
        return results
    }

    private static func collectDescendants(
        of element: AXUIElement,
        role: String?,
        maxDepth: Int,
        into results: inout [AXUIElement]
    ) {
        guard maxDepth > 0 else { return }
        let children = getChildren(element)
        for child in children {
            if role == nil || getRole(child) == role {
                results.append(child)
            }
            collectDescendants(of: child, role: role, maxDepth: maxDepth - 1, into: &results)
        }
    }

    /// Get the number of children without allocating the full array.
    static func getChildCount(_ element: AXUIElement) -> Int? {
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        guard result == .success else { return nil }
        return count
    }

    /// Get the value of an element (kAXValueAttribute).
    static func getValue(_ element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    /// Get the description of an element (kAXDescriptionAttribute).
    static func getDescription(_ element: AXUIElement) -> String? {
        getAttribute(element, kAXDescriptionAttribute)
    }
}
