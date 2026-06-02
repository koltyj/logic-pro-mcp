import Foundation
import MCP

enum Validation<Success> {
    case success(Success)
    case failure(String)
}

enum InputValidation {
    static func int(
        _ params: [String: Value],
        keys: [String],
        default defaultValue: Int? = nil,
        range: ClosedRange<Int>,
        label: String
    ) -> Validation<Int> {
        for key in keys {
            if let value = params[key]?.intValue {
                return validate(value, range: range, label: label)
            }
            if let string = params[key]?.stringValue, let value = Int(string) {
                return validate(value, range: range, label: label)
            }
        }
        if let defaultValue {
            return validate(defaultValue, range: range, label: label)
        }
        return .failure("\(label) is required")
    }

    static func double(
        _ params: [String: Value],
        keys: [String],
        default defaultValue: Double? = nil,
        range: ClosedRange<Double>,
        label: String
    ) -> Validation<Double> {
        for key in keys {
            if let value = params[key]?.doubleValue {
                return validate(value, range: range, label: label)
            }
            if let string = params[key]?.stringValue, let value = Double(string) {
                return validate(value, range: range, label: label)
            }
        }
        if let defaultValue {
            return validate(defaultValue, range: range, label: label)
        }
        return .failure("\(label) is required")
    }

    static func string(
        _ params: [String: Value],
        keys: [String],
        default defaultValue: String? = nil,
        maxLength: Int,
        allowEmpty: Bool = false,
        label: String
    ) -> Validation<String> {
        for key in keys {
            if let value = params[key]?.stringValue {
                return validate(value, maxLength: maxLength, allowEmpty: allowEmpty, label: label)
            }
        }
        if let defaultValue {
            return validate(defaultValue, maxLength: maxLength, allowEmpty: allowEmpty, label: label)
        }
        return .failure("\(label) is required")
    }

    static func midiChannel(_ params: [String: Value]) -> Validation<Int> {
        switch int(params, keys: ["channel"], default: 1, range: 1...16, label: "channel") {
        case .success(let channel):
            return .success(channel - 1)
        case .failure(let message):
            return .failure(message)
        }
    }

    static func logicProjectPath(
        _ params: [String: Value],
        mustExist: Bool,
        label: String = "path"
    ) -> Validation<String> {
        switch string(params, keys: ["path"], maxLength: 4096, label: label) {
        case .failure(let message):
            return .failure(message)
        case .success(let rawPath):
            let expanded = (rawPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            guard url.pathExtension.lowercased() == "logicx" else {
                return .failure("\(label) must point to a .logicx project")
            }

            var isDirectory = ObjCBool(false)
            if mustExist {
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
                    return .failure("\(label) does not exist: \(expanded)")
                }
            } else {
                let parent = url.deletingLastPathComponent().path
                guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    return .failure("\(label) parent directory does not exist: \(parent)")
                }
            }
            return .success(expanded)
        }
    }

    private static func validate(_ value: Int, range: ClosedRange<Int>, label: String) -> Validation<Int> {
        guard range.contains(value) else {
            return .failure("\(label) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return .success(value)
    }

    private static func validate(_ value: Double, range: ClosedRange<Double>, label: String) -> Validation<Double> {
        guard value.isFinite, range.contains(value) else {
            return .failure("\(label) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return .success(value)
    }

    private static func validate(
        _ value: String,
        maxLength: Int,
        allowEmpty: Bool,
        label: String
    ) -> Validation<String> {
        guard allowEmpty || !value.isEmpty else {
            return .failure("\(label) must not be empty")
        }
        guard value.count <= maxLength else {
            return .failure("\(label) must be \(maxLength) characters or fewer")
        }
        return .success(value)
    }
}
