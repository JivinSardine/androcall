import Foundation

/// One androcall frame (PROTOCOL.md §3).
///
/// A frame is the unit that travels in a single BLE write. Logical messages
/// larger than the negotiated ATT MTU are split across several frames that
/// share a `messageIdentifier`.
public struct Frame: Equatable {
    public var kind: ProtocolConstants.FrameKind
    public var flags: ProtocolConstants.FrameFlags
    public var sequence: UInt32
    public var messageIdentifier: UInt64
    public var fragmentIndex: UInt16
    public var fragmentCount: UInt16
    public var payload: Data
    /// AES-GCM tag; present only for encrypted frames.
    public var tag: Data?

    public init(
        kind: ProtocolConstants.FrameKind,
        flags: ProtocolConstants.FrameFlags,
        sequence: UInt32,
        messageIdentifier: UInt64,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        payload: Data,
        tag: Data? = nil
    ) {
        self.kind = kind
        self.flags = flags
        self.sequence = sequence
        self.messageIdentifier = messageIdentifier
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.payload = payload
        self.tag = tag
    }

    /// The 23-byte frame header. It is the additional authenticated data for
    /// encrypted frames, so the header cannot be modified in flight.
    ///
    /// All multi-byte integers are little-endian (PROTOCOL.md §3).
    public var header: Data {
        var out = Data()
        out.append(contentsOf: ProtocolConstants.magic)
        out.append(ProtocolConstants.frameVersion)
        out.append(kind.rawValue)
        out.append(flags.rawValue)
        out.append(Data.uint32LittleEndian(sequence))
        out.append(Data.uint64LittleEndian(messageIdentifier))
        out.append(Data.uint16LittleEndian(fragmentIndex))
        out.append(Data.uint16LittleEndian(fragmentCount))
        out.append(Data.uint16LittleEndian(UInt16(payload.count)))
        return out
    }

    /// The complete wire representation of the frame.
    public func encoded() -> Data {
        var out = header
        out.append(payload)
        if let tag = tag {
            out.append(tag)
        }
        return out
    }

    /// Parse a frame from its wire representation.
    public static func decode(_ data: Data) throws -> Frame {
        guard data.count >= ProtocolConstants.headerSize else {
            throw FrameError.tooShort
        }
        let bytes = [UInt8](data)
        guard bytes[0] == ProtocolConstants.magic[0], bytes[1] == ProtocolConstants.magic[1] else {
            throw FrameError.badMagic
        }
        guard bytes[2] == ProtocolConstants.frameVersion else {
            throw FrameError.unsupportedVersion
        }
        guard let kind = ProtocolConstants.FrameKind(rawValue: bytes[3]) else {
            throw FrameError.badKind
        }
        let flags = ProtocolConstants.FrameFlags(rawValue: bytes[4])
        let sequence = bytes.readUInt32(at: 5)
        let messageIdentifier = bytes.readUInt64(at: 9)
        let fragmentIndex = bytes.readUInt16(at: 17)
        let fragmentCount = bytes.readUInt16(at: 19)
        let length = Int(bytes.readUInt16(at: 21))

        guard data.count >= ProtocolConstants.headerSize + length else {
            throw FrameError.truncated
        }
        let payload = data.subdata(in: ProtocolConstants.headerSize..<(ProtocolConstants.headerSize + length))

        var tag: Data?
        if kind == .encrypted {
            guard data.count >= ProtocolConstants.headerSize + length + ProtocolConstants.tagSize else {
                throw FrameError.truncated
            }
            tag = data.subdata(
                in: (ProtocolConstants.headerSize + length)..<(ProtocolConstants.headerSize + length + ProtocolConstants.tagSize)
            )
        }

        return Frame(
            kind: kind,
            flags: flags,
            sequence: sequence,
            messageIdentifier: messageIdentifier,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payload: payload,
            tag: tag
        )
    }

    /// Seal this frame's payload with AES-256-GCM.
    ///
    /// The additional authenticated data is the header of the **sealed** frame,
    /// so the receiver authenticates exactly the bytes it received.
    public func encrypted(key: Data, direction: ProtocolConstants.Direction) throws -> Frame {
        var copy = self
        copy.kind = .encrypted
        let nonce = Self.nonce(direction: direction, sequence: sequence)
        let sealed = try AndroCallCrypto.seal(
            key: key,
            nonce: nonce,
            plaintext: payload,
            authenticating: copy.header
        )
        copy.payload = sealed.ciphertext
        copy.tag = sealed.tag
        return copy
    }

    /// Open the payload of an encrypted frame.
    public func decrypted(key: Data, direction: ProtocolConstants.Direction) throws -> Data {
        guard kind == .encrypted else { return payload }
        guard let tag = tag else { throw FrameError.missingTag }
        let nonce = Self.nonce(direction: direction, sequence: sequence)
        return try AndroCallCrypto.open(
            key: key,
            nonce: nonce,
            ciphertext: payload,
            tag: tag,
            authenticating: header
        )
    }

    /// The 12-byte GCM nonce: a 4-byte direction constant plus the 8-byte
    /// big-endian sequence number.
    public static func nonce(direction: ProtocolConstants.Direction, sequence: UInt32) -> Data {
        var out = Data()
        out.append(Data.uint32BigEndian(direction.rawValue))
        out.append(Data.uint64BigEndian(UInt64(sequence)))
        return out
    }
}

public enum FrameError: Error, LocalizedError {
    case tooShort
    case badMagic
    case unsupportedVersion
    case badKind
    case truncated
    case missingTag

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "The frame is shorter than the 23-byte header."
        case .badMagic: return "The frame does not start with the androcall magic bytes."
        case .unsupportedVersion: return "The frame uses an unsupported frame version."
        case .badKind: return "The frame declares an unknown frame kind."
        case .truncated: return "The frame payload or tag is truncated."
        case .missingTag: return "The encrypted frame carries no authentication tag."
        }
    }
}

/// Splits a logical message into frames that fit within `maximumPayload` bytes.
public enum Fragmenter {
    public static func frames(
        message: Data,
        messageIdentifier: UInt64,
        startingSequence: UInt32,
        maximumPayload: Int
    ) -> [Frame] {
        precondition(maximumPayload > 0, "maximumPayload must be positive")
        let chunks: [Data]
        if message.isEmpty {
            chunks = [Data()]
        } else {
            var result: [Data] = []
            var offset = 0
            while offset < message.count {
                let end = min(offset + maximumPayload, message.count)
                result.append(message.subdata(in: offset..<end))
                offset = end
            }
            chunks = result
        }

        return chunks.enumerated().map { index, chunk in
            var flags: ProtocolConstants.FrameFlags = []
            if index == 0 { flags.insert(.first) }
            if index != chunks.count - 1 { flags.insert(.more) }
            return Frame(
                kind: .plaintext,
                flags: flags,
                sequence: startingSequence &+ UInt32(index),
                messageIdentifier: messageIdentifier,
                fragmentIndex: UInt16(index),
                fragmentCount: UInt16(chunks.count),
                payload: chunk
            )
        }
    }
}

/// Reassembles frames into logical messages.
public final class MessageReassembler {
    public init() {}

    private struct Buffer {
        var fragmentCount: Int
        var kind: ProtocolConstants.FrameKind
        var parts: [Int: Data]
        var totalBytes: Int
    }

    private var buffers: [UInt64: Buffer] = [:]

    /// Feed a frame. Returns the complete message when the last fragment arrives.
    public func accept(_ frame: Frame) throws -> Data? {
        guard frame.fragmentCount >= 1 else { throw FrameError.badKind }
        let total = Int(frame.fragmentCount)
        guard total <= ProtocolConstants.maxFragmentsPerMessage else {
            throw ReassemblyError.tooManyFragments
        }
        let index = Int(frame.fragmentIndex)
        guard index < total else { throw ReassemblyError.badFragmentIndex }

        var buffer = buffers[frame.messageIdentifier] ?? Buffer(
            fragmentCount: total,
            kind: frame.kind,
            parts: [:],
            totalBytes: 0
        )
        guard buffer.fragmentCount == total else { throw ReassemblyError.inconsistentCount }

        if buffer.parts[index] == nil {
            buffer.totalBytes += frame.payload.count
            guard buffer.totalBytes <= ProtocolConstants.maxMessageBytes else {
                buffers.removeValue(forKey: frame.messageIdentifier)
                throw ReassemblyError.tooLarge
            }
        }
        buffer.parts[index] = frame.payload

        guard buffer.parts.count == total else {
            buffers[frame.messageIdentifier] = buffer
            return nil
        }

        buffers.removeValue(forKey: frame.messageIdentifier)
        var out = Data()
        out.reserveCapacity(buffer.totalBytes)
        for i in 0..<total {
            guard let part = buffer.parts[i] else { throw ReassemblyError.missingFragment }
            out.append(part)
        }
        return out
    }

    /// Drop any partially received message.
    public func reset() {
        buffers.removeAll()
    }
}

public enum ReassemblyError: Error, LocalizedError {
    case tooManyFragments
    case tooLarge
    case badFragmentIndex
    case inconsistentCount
    case missingFragment

    public var errorDescription: String? {
        switch self {
        case .tooManyFragments: return "The message has more fragments than the protocol allows."
        case .tooLarge: return "The message exceeds the maximum message size."
        case .badFragmentIndex: return "The fragment index is outside the fragment count."
        case .inconsistentCount: return "The fragments disagree about the fragment count."
        case .missingFragment: return "A fragment of the message is missing."
        }
    }
}

extension Array where Element == UInt8 {
    /// Read a little-endian 16-bit value (the wire format is little-endian).
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    /// Read a little-endian 32-bit value.
    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    /// Read a little-endian 64-bit value.
    func readUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(self[offset + index])
        }
        return value
    }
}
