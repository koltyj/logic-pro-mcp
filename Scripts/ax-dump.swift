#!/usr/bin/env swift
// Dump Logic Pro's Accessibility tree so localized AX labels can be collected.
//
// Usage:
//   swift Scripts/ax-dump.swift [maxDepth] [--menus] [--focused]
//
//   maxDepth   how deep to walk (default 6)
//   --menus    dump the menu bar instead of the main window
//   --focused  dump the focused window (e.g. an open Bounce dialog)
//   --attrs=X  print every attribute of elements whose description is X
//
// Each line: indent, role, then any non-empty description/title/identifier/value.
// The process that runs this needs Accessibility permission.

import ApplicationServices
import AppKit

let args = CommandLine.arguments.dropFirst()
let maxDepth = args.compactMap { Int($0) }.first ?? 6
let dumpMenus = args.contains("--menus")
let dumpFocused = args.contains("--focused")
let attrsFor = args.first { $0.hasPrefix("--attrs=") }.map { String($0.dropFirst(8)) }

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("Accessibility permission is required.\n".data(using: .utf8)!)
    exit(2)
}

let bundleIDs = ["com.apple.logic10", "com.apple.mainstage3"]
guard let app = NSWorkspace.shared.runningApplications.first(where: {
    bundleIDs.contains($0.bundleIdentifier ?? "")
}) else {
    FileHandle.standardError.write("Logic Pro is not running.\n".data(using: .utf8)!)
    exit(1)
}

let root = AXUIElementCreateApplication(app.processIdentifier)

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
    return value
}

func str(_ el: AXUIElement, _ name: String) -> String? {
    guard let s = attr(el, name) as? String, !s.isEmpty else { return nil }
    return s.replacingOccurrences(of: "\n", with: "⏎")
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func walk(_ el: AXUIElement, depth: Int) {
    var parts = [String(repeating: "  ", count: depth) + (str(el, kAXRoleAttribute) ?? "?")]
    if let d = str(el, kAXDescriptionAttribute) { parts.append("desc=\"\(d)\"") }
    if let t = str(el, kAXTitleAttribute) { parts.append("title=\"\(t)\"") }
    if let i = str(el, kAXIdentifierAttribute) { parts.append("id=\"\(i)\"") }
    if let v = attr(el, kAXValueAttribute) {
        let s = "\(v)".replacingOccurrences(of: "\n", with: "⏎")
        if !s.isEmpty && s.count < 60 { parts.append("value=\"\(s)\"") }
    }
    print(parts.joined(separator: " "))
    if let attrsFor, str(el, kAXDescriptionAttribute) == attrsFor {
        var names: CFArray?
        if AXUIElementCopyAttributeNames(el, &names) == .success, let names = names as? [String] {
            for name in names where name != kAXChildrenAttribute {
                let v = attr(el, name).map { "\($0)" } ?? "nil"
                print(String(repeating: "  ", count: depth + 2) + "@\(name) = \(v.prefix(120))")
            }
        }
    }
    guard depth < maxDepth else { return }
    for child in children(el) { walk(child, depth: depth + 1) }
}

let start: AXUIElement?
if dumpMenus {
    start = attr(root, kAXMenuBarAttribute).map { $0 as! AXUIElement }
} else if dumpFocused {
    start = attr(root, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
} else {
    start = attr(root, kAXMainWindowAttribute).map { $0 as! AXUIElement }
}

guard let start else {
    FileHandle.standardError.write("Could not find the requested element.\n".data(using: .utf8)!)
    exit(1)
}
walk(start, depth: 0)
