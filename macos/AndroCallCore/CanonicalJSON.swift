import Foundation

/// A JSON value restricted to the shapes the androcall protocol carries.
public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Convenience accessors

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }
}

// MARK: - Canonical serialisation

public enum CanonicalJSON {

    /// Serialise a value using the canonical rules of PROTOCOL.md §4.0.
    ///
    /// * object keys are sorted lexicographically by their UTF-8 bytes
    /// * numbers are integers only
    /// * no insignificant whitespace
    /// * `/` is not escaped, control characters use the short escapes where
    ///   they exist and `\u00xx` (lower-case hex) otherwise
    public static func encode(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .string(let text):
            return encodeString(text)
        case .array(let elements):
            return "[" + elements.map(encode).joined(separator: ",") + "]"
        case .object(let members):
            let keys = members.keys.sorted { lhs, rhs in
                Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
            }
            let parts = keys.map { encodeString($0) + ":" + encode(members[$0]!) }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    /// Encode a value as UTF-8 bytes.
    public static func data(_ value: JSONValue) -> Data {
        Data(encode(value).utf8)
    }

    /// Encode an object whose members are emitted in the given order.
    ///
    /// The message envelope uses this so that the top-level field order is
    /// fixed (`v`, `type`, `id`, `ts`, `replyTo`, `body`) while the members of
    /// `body` are still sorted.
    public static func encodeOrderedObject(_ members: [(String, JSONValue)]) -> String {
        let parts = members.map { encodeString($0.0) + ":" + encode($0.1) }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func encodeString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - Parsing

    /// Parse JSON text into a `JSONValue`.
    public static func parse(_ text: String) throws -> JSONValue {
        guard let data = text.data(using: .utf8) else {
            throw JSONError.invalidUTF8
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try convert(object)
    }

    /// Parse JSON bytes into a `JSONValue`.
    public static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try convert(object)
    }

    private static func convert(_ object: Any) throws -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let value = number.int64Value
            // Reject fractional numbers: the protocol carries integers only.
            if number.doubleValue != Double(value) {
                throw JSONError.fractionalNumber
            }
            return .int(value)
        case let text as String:
            return .string(text)
        case let elements as [Any]:
            return .array(try elements.map(convert))
        case let members as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (key, value) in members {
                result[key] = try convert(value)
            }
            return .object(result)
        default:
            throw JSONError.unsupportedType
        }
    }
}

public enum JSONError: Error, LocalizedError {
    case invalidUTF8
    case fractionalNumber
    case unsupportedType

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "The JSON payload is not valid UTF-8."
        case .fractionalNumber: return "The protocol does not carry fractional numbers."
        case .unsupportedType: return "The JSON payload contains an unsupported value."
        }
    }
}
