import Foundation
import Security

/// The lifecycle of a client session (PROTOCOL.md §7.1).
public enum SessionState: Equatable {
    case idle
    case connecting
    case handshaking
    case authenticating
    case ready
    case disconnected(reason: String?)
    case failed(reason: String)

    public var isReady: Bool { self == .ready }
}

/// Events the phone pushes to the Mac.
public enum SessionEvent {
    case deviceInfo(DeviceInfo)
    case callCapabilities(CallCapabilities)
    case callState(callId: String, state: CallState, number: String?, displayName: String?, startedAt: Int64?, durationMs: Int64?)
    case callEnded(callId: String, reason: String, durationMs: Int64?)
    case contactsBatch(requestId: String, index: Int, total: Int, contacts: [Contact], hasMore: Bool)
    case contactsComplete(requestId: String, total: Int)
    case contactsError(requestId: String, code: String, message: String)
    case recentsBatch(requestId: String, index: Int, total: Int, calls: [RecentCall])
    case recentsComplete(requestId: String, total: Int)
    case recentsError(requestId: String, code: String, message: String)
    case favoriteResult(contactId: String, favorite: Bool, updated: Bool, reason: String?)
    case logBatch(requestId: String, lines: [String])
    case error(code: String, message: String, fatal: Bool)
    case sessionError(code: String, message: String)
}

/// A pending request waiting for its reply.
private struct PendingRequest {
    let id: String
    let type: String
    let created: Date
    var continuation: CheckedContinuation<Message, Error>?
}

/// Raised when the peer answers with an error message.
public struct ProtocolError: Error, LocalizedError {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The Mac-side protocol client.
///
/// It owns the handshake, the frame codec, the request/response correlation
/// and the replay protection. It is deliberately free of any Bluetooth or UI
/// dependency so that it can be tested against a loopback transport.
public final class Session {

    // MARK: - Public state

    public private(set) var state: SessionState = .idle {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }

    /// Called whenever the session state changes.
    public var onStateChange: ((SessionState) -> Void)?

    /// Called for every event pushed by the phone.
    public var onEvent: ((SessionEvent) -> Void)?

    /// The capabilities the phone advertised during the handshake.
    public private(set) var peerCapabilities: Capabilities = []

    /// The device information the phone reported.
    public private(set) var deviceInfo: DeviceInfo?

    /// The call capabilities the phone reported.
    public private(set) var callCapabilities: CallCapabilities?

    /// The verification code the user must compare on both screens.
    public private(set) var verificationCode: String?

    /// The name this client offers to the phone.
    public var clientName: String = "Mac"

    /// Capabilities this client offers to the phone.
    public var clientCapabilities: Capabilities = [.contacts, .callPlace, .callState, .deviceInfo]

    // MARK: - Internals

    private let transport: Transport
    private let queue = DispatchQueue(label: "dev.androcall.session")
    private var reassembler = MessageReassembler()
    private var keys: SessionKeys?
    private var outgoingSequence: UInt32 = 0
    private var highestIncomingSequence: UInt32 = 0
    private var highestIncomingSequenceSet = false
    private var pending: [String: PendingRequest] = [:]
    private var timer: DispatchSourceTimer?
    private var messageCounter: UInt64 = 1
    private var handshake: HandshakeState?

    /// Records the frames exchanged, for the diagnostics screen.
    public private(set) var log: [String] = []

    private struct HandshakeState {
        let clientKeyPair: AndroCallCrypto.EphemeralKeyPair
        let clientNonce: Data
        var serverNonce: Data?
        var salt: Data?
        var iterations: Int = ProtocolConstants.pbkdf2Iterations
        var serverPublicKey: Data?
    }

    // MARK: - Life cycle

    public init(transport: Transport) {
        self.transport = transport
        transport.onFrame = { [weak self] data in
            self?.handleFrameData(data)
        }
        transport.onStateChange = { [weak self] state in
            self?.handleTransportState(state)
        }
    }

    deinit {
        timer?.cancel()
    }

    /// Begin the handshake. The transport must already be connected.
    ///
    /// - Parameter pin: the 6-digit PIN the user typed. It is held in memory
    ///   only and is cleared as soon as the handshake completes.
    public func start(pin: String) throws {
        try queue.sync {
            guard state == .idle || isResumable else {
                throw ProtocolError(code: "invalid_state", message: "The session is already running.")
            }
            keys = nil
            reassembler.reset()
            pending.removeAll()
            outgoingSequence = 0
            highestIncomingSequenceSet = false
            handshake = nil
            pendingPIN = pin
            state = .handshaking

            let keyPair = AndroCallCrypto.EphemeralKeyPair()
            let nonce = randomBytes(count: 16)
            handshake = HandshakeState(clientKeyPair: keyPair, clientNonce: nonce)

            let hello = Message(
                type: "session.hello",
                body: [
                    "protocolVersion": .int(Int64(ProtocolConstants.version)),
                    "clientName": .string(clientName),
                    "clientNonce": .string(nonce.base64EncodedString()),
                    "capabilities": .array(clientCapabilities.names.map { JSONValue.string($0) }),
                ]
            )
            try sendMessage(hello, encrypted: false)
        }
    }

    private var isResumable: Bool {
        if case .disconnected = state { return true }
        if case .failed = state { return true }
        return false
    }

    /// Tear the session down.
    public func stop(reason: String? = nil) {
        queue.sync {
            failPendingRequests(with: ProtocolError(code: "disconnected", message: reason ?? "The phone disconnected."))
            keys = nil
            handshake = nil
            state = .disconnected(reason: reason)
        }
    }

    // MARK: - Outgoing requests

    /// Send a request and wait for the peer's reply.
    public func request(
        _ type: String,
        body: [String: JSONValue] = [:],
        timeout: TimeInterval = ProtocolConstants.requestTimeoutSeconds
    ) async throws -> Message {
        let message = Message(type: type, body: body)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.state.isReady else {
                    continuation.resume(throwing: ProtocolError(
                        code: "not_ready",
                        message: "The phone is not connected."
                    ))
                    return
                }
                let identifier = message.id
                self.pending[identifier] = PendingRequest(
                    id: identifier,
                    type: type,
                    created: Date(),
                    continuation: continuation
                )
                do {
                    try self.sendMessage(message, encrypted: true)
                } catch {
                    self.pending.removeValue(forKey: identifier)
                    continuation.resume(throwing: error)
                    return
                }
                self.scheduleTimeout(for: identifier, after: timeout)
            }
        }
    }

    /// Send a fire-and-forget message.
    public func notify(_ type: String, body: [String: JSONValue] = [:]) throws {
        try queue.sync {
            guard state.isReady else {
                throw ProtocolError(code: "not_ready", message: "The phone is not connected.")
            }
            try sendMessage(Message(type: type, body: body), encrypted: true)
        }
    }

    // MARK: - Frame handling

    private func handleFrameData(_ data: Data) {
        queue.async {
            do {
                let frame = try Frame.decode(data)
                try self.handle(frame)
            } catch {
                self.appendLog("dropped malformed frame: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ frame: Frame) throws {
        // Replay protection: sequence numbers must strictly increase.
        if highestIncomingSequenceSet && frame.sequence <= highestIncomingSequence {
            appendLog("dropped replayed frame seq=\(frame.sequence)")
            return
        }
        highestIncomingSequence = frame.sequence
        highestIncomingSequenceSet = true

        // Each frame is sealed independently, so decrypt before reassembling.
        var plainFrame = frame
        if frame.kind == .encrypted {
            guard let keys = keys else {
                throw ProtocolError(code: "invalid_state", message: "Received an encrypted frame before the handshake completed.")
            }
            plainFrame.payload = try frame.decrypted(key: keys.serverToClient, direction: .serverToClient)
            plainFrame.kind = .plaintext
            plainFrame.tag = nil
        }

        guard let messageData = try reassembler.accept(plainFrame) else { return }
        let message = try Message.parse(messageData)

        switch message.type {
        case "session.challenge":
            try handleChallenge(message)
        case "session.ready":
            try handleSessionReady(message)
        case "session.error":
            let code = message.string("code") ?? "unknown"
            let text = message.string("message") ?? "The phone refused the session."
            onEvent?(.sessionError(code: code, message: text))
            failPendingRequests(with: ProtocolError(code: code, message: text))
            state = .failed(reason: text)
        default:
            if let replyTo = message.replyTo {
                completePending(id: replyTo, with: message)
            } else {
                dispatch(event: message)
            }
        }
    }

    private func handleChallenge(_ message: Message) throws {
        guard var handshake = handshake else {
            throw ProtocolError(code: "invalid_state", message: "Received a challenge without starting a handshake.")
        }
        guard
            let saltBase64 = message.string("salt"),
            let salt = Data(base64Encoded: saltBase64),
            let serverNonceBase64 = message.string("serverNonce"),
            let serverNonce = Data(base64Encoded: serverNonceBase64),
            let serverPublicKeyBase64 = message.string("serverPubKey"),
            let serverPublicKey = Data(base64Encoded: serverPublicKeyBase64)
        else {
            throw ProtocolError(code: "invalid_message", message: "The challenge is missing required fields.")
        }

        let iterations = Int(message.int("iterations") ?? Int64(ProtocolConstants.pbkdf2Iterations))
        handshake.serverNonce = serverNonce
        handshake.salt = salt
        handshake.iterations = iterations
        handshake.serverPublicKey = serverPublicKey
        self.handshake = handshake

        state = .authenticating

        let shared = try SessionKeySchedule.sharedSecret(
            privateKey: handshake.clientKeyPair,
            peerPublicKey: serverPublicKey
        )
        let derived = SessionKeySchedule.derive(
            pin: pendingPIN,
            salt: salt,
            iterations: iterations,
            serverNonce: serverNonce,
            clientNonce: handshake.clientNonce,
            serverPublicKey: serverPublicKey,
            clientPublicKey: handshake.clientKeyPair.publicKeyX963,
            ecdhShared: shared
        )
        verificationCode = derived.verifyCode

        let response = Message(
            type: "session.response",
            body: [
                "clientPubKey": .string(handshake.clientKeyPair.publicKeyX963.base64EncodedString()),
                "proof": .string(derived.proof.base64EncodedString()),
            ]
        )
        try sendMessage(response, encrypted: false)
    }

    private func handleSessionReady(_ message: Message) throws {
        guard let handshake = handshake else {
            throw ProtocolError(code: "invalid_state", message: "Received session.ready without a handshake.")
        }
        guard
            let salt = handshake.salt,
            let serverNonce = handshake.serverNonce,
            let serverPublicKey = handshake.serverPublicKey
        else {
            throw ProtocolError(code: "invalid_state", message: "The handshake is incomplete.")
        }
        let shared = try SessionKeySchedule.sharedSecret(
            privateKey: handshake.clientKeyPair,
            peerPublicKey: serverPublicKey
        )
        let derived = SessionKeySchedule.derive(
            pin: pendingPIN,
            salt: salt,
            iterations: handshake.iterations,
            serverNonce: serverNonce,
            clientNonce: handshake.clientNonce,
            serverPublicKey: serverPublicKey,
            clientPublicKey: handshake.clientKeyPair.publicKeyX963,
            ecdhShared: shared
        )

        // The phone proves possession of the PIN with the same proof value.
        if let proofBase64 = message.string("proof"), let proof = Data(base64Encoded: proofBase64) {
            guard AndroCallCrypto.constantTimeEquals(proof, derived.proof) else {
                let text = "The phone could not prove it knows the PIN."
                onEvent?(.sessionError(code: "auth_failed", message: text))
                state = .failed(reason: text)
                throw ProtocolError(code: "auth_failed", message: text)
            }
        }

        // The verification code must agree, otherwise the session was tampered with.
        if let code = message.string("verifyCode"), code != derived.verifyCode {
            let text = "The verification codes do not match. Aborting the session."
            onEvent?(.sessionError(code: "verify_mismatch", message: text))
            state = .failed(reason: text)
            throw ProtocolError(code: "verify_mismatch", message: text)
        }

        keys = derived
        pendingPIN = ""
        verificationCode = derived.verifyCode
        state = .ready
        appendLog("session established (verify code \(derived.verifyCode))")

        // Confirm that the encrypted channel works in both directions.
        try sendMessage(
            Message(type: "ping", body: ["nonce": .int(Int64(Message.nowMilliseconds()))]),
            encrypted: true
        )
    }

    private func dispatch(event message: Message) {
        switch message.type {
        case "device.info":
            deviceInfo = DeviceInfo.parse(message.body)
            onEvent?(.deviceInfo(deviceInfo!))
        case "call.capabilities":
            callCapabilities = CallCapabilities.parse(message.body)
            onEvent?(.callCapabilities(callCapabilities!))
        case "call.state":
            let callId = message.string("callId") ?? ""
            let state = CallState.parse(message.string("state") ?? "unknown")
            onEvent?(.callState(
                callId: callId,
                state: state,
                number: message.string("number"),
                displayName: message.string("displayName"),
                startedAt: message.int("startedAt"),
                durationMs: message.int("durationMs")
            ))
        case "call.ended":
            onEvent?(.callEnded(
                callId: message.string("callId") ?? "",
                reason: message.string("reason") ?? "",
                durationMs: message.int("durationMs")
            ))
        case "contacts.batch":
            let contacts = (message.array("contacts") ?? []).compactMap(Contact.parse)
            onEvent?(.contactsBatch(
                requestId: message.string("requestId") ?? "",
                index: Int(message.int("index") ?? 0),
                total: Int(message.int("total") ?? 0),
                contacts: contacts,
                hasMore: message.bool("hasMore") ?? false
            ))
        case "contacts.complete":
            onEvent?(.contactsComplete(
                requestId: message.string("requestId") ?? "",
                total: Int(message.int("total") ?? 0)
            ))
        case "contacts.error":
            onEvent?(.contactsError(
                requestId: message.string("requestId") ?? "",
                code: message.string("code") ?? "",
                message: message.string("message") ?? ""
            ))
        case "recents.batch":
            let calls = (message.array("calls") ?? []).compactMap(RecentCall.parse)
            onEvent?(.recentsBatch(
                requestId: message.string("requestId") ?? "",
                index: Int(message.int("index") ?? 0),
                total: Int(message.int("total") ?? 0),
                calls: calls
            ))
        case "recents.complete":
            onEvent?(.recentsComplete(
                requestId: message.string("requestId") ?? "",
                total: Int(message.int("total") ?? 0)
            ))
        case "recents.error":
            onEvent?(.recentsError(
                requestId: message.string("requestId") ?? "",
                code: message.string("code") ?? "",
                message: message.string("message") ?? ""
            ))
        case "contact.favorite.result":
            onEvent?(.favoriteResult(
                contactId: message.string("contactId") ?? "",
                favorite: message.bool("favorite") ?? false,
                updated: message.bool("updated") ?? false,
                reason: message.string("reason")
            ))
        case "log.batch":
            let lines = (message.array("lines") ?? []).compactMap { $0.stringValue }
            onEvent?(.logBatch(requestId: message.string("requestId") ?? "", lines: lines))
        case "error":
            onEvent?(.error(
                code: message.string("code") ?? "",
                message: message.string("message") ?? "",
                fatal: message.bool("fatal") ?? false
            ))
        default:
            appendLog("unhandled message type \(message.type)")
        }
    }

    // MARK: - Outgoing frames

    private func sendMessage(_ message: Message, encrypted: Bool) throws {
        let payload = message.jsonData
        let identifier = nextMessageIdentifier()
        let maximum = max(1, transport.maximumPayloadSize - ProtocolConstants.headerSize - ProtocolConstants.tagSize)
        var frames = Fragmenter.frames(
            message: payload,
            messageIdentifier: identifier,
            startingSequence: outgoingSequence + 1,
            maximumPayload: maximum
        )

        if encrypted {
            guard let keys = keys else {
                throw ProtocolError(code: "not_ready", message: "The session is not established.")
            }
            frames = try frames.map {
                try $0.encrypted(key: keys.clientToServer, direction: .clientToServer)
            }
        }

        for frame in frames {
            outgoingSequence &+= 1
            try transport.send(frame.encoded())
        }
    }

    private func nextMessageIdentifier() -> UInt64 {
        messageCounter &+= 1
        return messageCounter
    }

    // MARK: - Pending requests

    private func completePending(id: String, with message: Message) {
        guard let request = pending.removeValue(forKey: id) else {
            appendLog("received a reply for an unknown request \(id)")
            return
        }
        request.continuation?.resume(returning: message)
    }

    private func failPendingRequests(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.continuation?.resume(throwing: error)
        }
    }

    private func scheduleTimeout(for identifier: String, after interval: TimeInterval) {
        queue.asyncAfter(deadline: .now() + interval) {
            guard let request = self.pending.removeValue(forKey: identifier) else { return }
            request.continuation?.resume(throwing: ProtocolError(
                code: "timeout",
                message: "The phone did not answer in time."
            ))
        }
    }

    // MARK: - Transport state

    private func handleTransportState(_ transportState: TransportState) {
        queue.async {
            switch transportState {
            case .disconnected(let reason):
                self.failPendingRequests(with: ProtocolError(
                    code: "disconnected",
                    message: reason ?? "The phone disconnected."
                ))
                self.keys = nil
                self.reassembler.reset()
                if case .failed = self.state {
                    // The session already failed for a more specific reason.
                } else {
                    self.state = .disconnected(reason: reason)
                }
            case .failed(let reason):
                self.failPendingRequests(with: ProtocolError(code: "transport_failed", message: reason))
                self.state = .failed(reason: reason)
            default:
                break
            }
        }
    }

    // MARK: - PIN handling

    /// The PIN the user entered. Held in memory only and cleared as soon as the
    /// handshake completes.
    private var pendingPIN: String = ""

    // MARK: - Logging

    private func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        log.append("[\(stamp)] \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    /// Export the diagnostic log.
    public func exportLog() -> String {
        queue.sync { log.joined(separator: "\n") }
    }

    // MARK: - Randomness

    private func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        if status != errSecSuccess {
            for index in 0..<count {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes)
    }
}
