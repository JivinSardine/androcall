import Foundation

/// The connection state of a transport.
public enum TransportState: Equatable {
    case idle
    case discovering
    case connecting
    case connected
    case disconnecting
    case disconnected(reason: String?)
    case failed(reason: String)
}

/// A bidirectional byte channel to the phone.
///
/// The protocol layer only knows about frames and messages, so the transport
/// can be swapped (BLE today; an optional LAN transport later) without touching
/// the session logic.
public protocol Transport: AnyObject {
    /// Called for every frame received from the peer.
    var onFrame: ((Data) -> Void)? { get set }
    /// Called when the connection state changes.
    var onStateChange: ((TransportState) -> Void)? { get set }
    /// The largest payload that fits in one write.
    var maximumPayloadSize: Int { get }
    /// Human-readable description of the peer, when known.
    var peerName: String? { get }

    func start()
    func stop()
    func send(_ data: Data) throws
}

public enum TransportError: Error, LocalizedError {
    case notConnected
    case payloadTooLarge(maximum: Int)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The phone is not connected."
        case .payloadTooLarge(let maximum):
            return "The message does not fit in one Bluetooth write (maximum \(maximum) bytes)."
        case .writeFailed(let reason):
            return "Sending to the phone failed: \(reason)"
        }
    }
}

/// An in-memory transport used by the test suite and by the diagnostics screen.
///
/// It connects two sessions directly, which lets the whole protocol stack be
/// exercised without any Bluetooth hardware.
public final class LoopbackTransport: Transport {
    public var onFrame: ((Data) -> Void)?
    public var onStateChange: ((TransportState) -> Void)?
    public var maximumPayloadSize: Int
    public var peerName: String?

    /// The other end of the loopback.
    public weak var peer: LoopbackTransport?

    /// Simulated per-frame delivery delay, used to exercise timeouts.
    public var deliveryDelay: TimeInterval = 0

    /// When set, `send` throws instead of delivering.
    public var failureToSend: String?

    public private(set) var state: TransportState = .idle {
        didSet { onStateChange?(state) }
    }

    public init(maximumPayloadSize: Int = 400) {
        self.maximumPayloadSize = maximumPayloadSize
    }

    public func start() {
        state = .connected
    }

    public func stop() {
        state = .disconnected(reason: "Stopped")
    }

    public func send(_ data: Data) throws {
        if let failure = failureToSend {
            throw TransportError.writeFailed(failure)
        }
        guard state == .connected else { throw TransportError.notConnected }
        guard data.count <= maximumPayloadSize else {
            throw TransportError.payloadTooLarge(maximum: maximumPayloadSize)
        }
        guard let peer = peer else { return }
        if deliveryDelay > 0 {
            let payload = data
            DispatchQueue.global().asyncAfter(deadline: .now() + deliveryDelay) {
                peer.onFrame?(payload)
            }
        } else {
            peer.onFrame?(data)
        }
    }

    /// Simulate the peer disappearing.
    public func simulateDisconnect(reason: String = "Link lost") {
        state = .disconnected(reason: reason)
        peer?.state = .disconnected(reason: reason)
    }
}
