import Foundation
import Security

/// A protocol message (PROTOCOL.md §4).
public struct Message: Equatable {
    public var type: String
    public var id: String
    public var timestamp: Int64
    public var replyTo: String?
    public var body: [String: JSONValue]
    public var version: Int

    public init(
        type: String,
        id: String = Message.newIdentifier(),
        timestamp: Int64 = Message.nowMilliseconds(),
        replyTo: String? = nil,
        body: [String: JSONValue] = [:],
        version: Int = ProtocolConstants.version
    ) {
        self.type = type
        self.id = id
        self.timestamp = timestamp
        self.replyTo = replyTo
        self.body = body
        self.version = version
    }

    /// The canonical JSON representation.
    ///
    /// The envelope uses a fixed field order; the members of `body` are sorted.
    public var jsonData: Data {
        let members: [(String, JSONValue)] = [
            ("v", .int(Int64(version))),
            ("type", .string(type)),
            ("id", .string(id)),
            ("ts", .int(timestamp)),
            ("replyTo", replyTo.map { JSONValue.string($0) } ?? .null),
            ("body", .object(body)),
        ]
        return Data(CanonicalJSON.encodeOrderedObject(members).utf8)
    }

    /// Parse a message from its canonical JSON bytes.
    public static func parse(_ data: Data) throws -> Message {
        let value = try CanonicalJSON.parse(data)
        guard case .object(let members) = value else {
            throw MessageError.notAnObject
        }
        guard let version = members["v"]?.intValue else { throw MessageError.missingField("v") }
        guard version == Int64(ProtocolConstants.version) else {
            throw MessageError.unsupportedVersion(Int(version))
        }
        guard let type = members["type"]?.stringValue else { throw MessageError.missingField("type") }
        guard let id = members["id"]?.stringValue else { throw MessageError.missingField("id") }
        guard let timestamp = members["ts"]?.intValue else { throw MessageError.missingField("ts") }
        guard let replyToValue = members["replyTo"] else { throw MessageError.missingField("replyTo") }

        var replyTo: String?
        if replyToValue.isNull {
            replyTo = nil
        } else if let text = replyToValue.stringValue {
            replyTo = text
        } else {
            throw MessageError.missingField("replyTo")
        }

        var body: [String: JSONValue] = [:]
        if let bodyValue = members["body"] {
            if bodyValue.isNull {
                body = [:]
            } else if let object = bodyValue.objectValue {
                body = object
            } else {
                throw MessageError.missingField("body")
            }
        }

        return Message(
            type: type,
            id: id,
            timestamp: timestamp,
            replyTo: replyTo,
            body: body,
            version: Int(version)
        )
    }

    /// Convenience accessors for body members.
    public func string(_ key: String) -> String? { body[key]?.stringValue }
    public func int(_ key: String) -> Int64? { body[key]?.intValue }
    public func bool(_ key: String) -> Bool? { body[key]?.boolValue }
    public func array(_ key: String) -> [JSONValue]? { body[key]?.arrayValue }
    public func object(_ key: String) -> [String: JSONValue]? { body[key]?.objectValue }

    /// Generate a 26-character base32 identifier (ULID-style, lexicographically sortable).
    public static func newIdentifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }
        if status != errSecSuccess {
            // SecRandomCopyBytes practically never fails; fall back to the clock so
            // that a message can still be produced.
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            for index in 0..<8 {
                bytes[index] = UInt8((now >> (8 * UInt64(index))) & 0xFF)
            }
        }
        return encodeULID(bytes)
    }

    /// Encode 16 bytes as a 26-character base32 (Crockford) string.
    public static func encodeULID(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var value = (UInt64(bytes[0]) << 56) | (UInt64(bytes[1]) << 48)
            | (UInt64(bytes[2]) << 40) | (UInt64(bytes[3]) << 32)
            | (UInt64(bytes[4]) << 24) | (UInt64(bytes[5]) << 16)
            | (UInt64(bytes[6]) << 8) | UInt64(bytes[7])
        var out = [Character](repeating: "0", count: 26)
        var index = 25
        while index >= 10 {
            out[index] = alphabet[Int(value & 0x1F)]
            value >>= 5
            index -= 1
        }
        var remainder = value
        var position = index
        while position >= 0 {
            out[position] = alphabet[Int(remainder & 0x1F)]
            remainder >>= 5
            position -= 1
        }
        return String(out)
    }

    /// Current Unix time in milliseconds.
    public static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

public enum MessageError: Error, LocalizedError {
    case notAnObject
    case missingField(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .notAnObject:
            return "The message is not a JSON object."
        case .missingField(let field):
            return "The message is missing the '\(field)' field."
        case .unsupportedVersion(let version):
            return "The peer uses protocol version \(version); this app speaks version \(ProtocolConstants.version)."
        }
    }
}
