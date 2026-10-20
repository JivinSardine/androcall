import CoreBluetooth
import Foundation

/// Fixed constants of the androcall wire protocol v1.
///
/// See `protocol/PROTOCOL.md` for the normative description.
public enum ProtocolConstants {
    /// Protocol version carried in every message.
    public static let version: Int = 1

    /// Frame layer.
    public static let magic: [UInt8] = [0x41, 0x43] // "AC"
    public static let frameVersion: UInt8 = 0x01
    public static let headerSize = 23
    public static let tagSize = 16

    public enum FrameKind: UInt8 {
        case plaintext = 0x01
        case encrypted = 0x02
    }

    public struct FrameFlags: OptionSet {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Another fragment of the same logical message follows.
        public static let more = FrameFlags(rawValue: 0x01)
        /// This is the first fragment of the logical message.
        public static let first = FrameFlags(rawValue: 0x02)
    }

    /// GCM nonce direction constants (PROTOCOL.md §6.3).
    public enum Direction: UInt32 {
        case clientToServer = 0x0000_0001
        case serverToClient = 0x0000_0002
    }

    /// PBKDF2 iteration count used by the session key schedule.
    public static let pbkdf2Iterations = 210_000

    /// Reassembly limits (PROTOCOL.md §3.1).
    public static let maxFragmentsPerMessage = 64
    public static let maxMessageBytes = 1 << 20

    /// Request timeouts.
    public static let requestTimeoutSeconds: TimeInterval = 10

    /// Window of unacknowledged bulk frames the sender may have in flight.
    public static let bulkWindow = 8

    // MARK: - Key schedule labels

    static let sessionSaltPrefix = "androcall-v1"
    static let sessionInfo = "androcall-session-v1"
    static let clientToServerInfo = "androcall-c2s-v1"
    static let serverToClientInfo = "androcall-s2c-v1"
    static let proofPrefix = "androcall-proof-v1"
    static let verifyPrefix = "androcall-verify-v1"
}

/// BLE GATT identifiers used by androcall.
public enum GATTIdentifiers {
    public static let service = CBUUID(string: "A9D00001-1C3E-4B7A-9F21-6D2C5B8E4A10")
    public static let control = CBUUID(string: "A9D00002-1C3E-4B7A-9F21-6D2C5B8E4A10")
    public static let event = CBUUID(string: "A9D00003-1C3E-4B7A-9F21-6D2C5B8E4A10")
    public static let bulk = CBUUID(string: "A9D00004-1C3E-4B7A-9F21-6D2C5B8E4A10")
}

/// Capabilities a peer may advertise.
public struct Capabilities: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let contacts = Capabilities(rawValue: 1 << 0)
    public static let recents = Capabilities(rawValue: 1 << 1)
    public static let callPlace = Capabilities(rawValue: 1 << 2)
    public static let callState = Capabilities(rawValue: 1 << 3)
    public static let callAnswer = Capabilities(rawValue: 1 << 4)
    public static let callDecline = Capabilities(rawValue: 1 << 5)
    public static let callEnd = Capabilities(rawValue: 1 << 6)
    public static let callMute = Capabilities(rawValue: 1 << 7)
    public static let deviceInfo = Capabilities(rawValue: 1 << 8)
    public static let favorites = Capabilities(rawValue: 1 << 9)

    /// Parse the wire representation (a list of capability names).
    public static func parse(_ names: [String]) -> Capabilities {
        var result = Capabilities()
        for name in names {
            switch name {
            case "contacts": result.insert(.contacts)
            case "recents": result.insert(.recents)
            case "call.place": result.insert(.callPlace)
            case "call.state": result.insert(.callState)
            case "call.answer": result.insert(.callAnswer)
            case "call.decline": result.insert(.callDecline)
            case "call.end": result.insert(.callEnd)
            case "call.mute": result.insert(.callMute)
            case "device.info": result.insert(.deviceInfo)
            case "contacts.favorite": result.insert(.favorites)
            default: break
            }
        }
        return result
    }

    /// The wire representation (a list of capability names).
    public var names: [String] {
        var out: [String] = []
        if contains(.contacts) { out.append("contacts") }
        if contains(.recents) { out.append("recents") }
        if contains(.callPlace) { out.append("call.place") }
        if contains(.callState) { out.append("call.state") }
        if contains(.callAnswer) { out.append("call.answer") }
        if contains(.callDecline) { out.append("call.decline") }
        if contains(.callEnd) { out.append("call.end") }
        if contains(.callMute) { out.append("call.mute") }
        if contains(.deviceInfo) { out.append("device.info") }
        if contains(.favorites) { out.append("contacts.favorite") }
        return out
    }
}
