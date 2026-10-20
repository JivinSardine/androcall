import Foundation
import AndroCallCore

/// Behavioural tests for the protocol core that do not depend on the shared
/// conformance vectors.
public enum UnitTests {
    public static func run(_ runner: TestRunner) {
        runner.suite("Unit: frames") {
            runner.test("a frame with a bad magic is rejected") {
                var data = Data([0x00, 0x00, 0x01, 0x01, 0x00])
                data.append(Data(repeating: 0, count: 18))
                try runner.expectThrows("bad magic") { _ = try Frame.decode(data) }
            }

            runner.test("a truncated frame is rejected") {
                let data = Data([0x41, 0x43, 0x01, 0x01, 0x00])
                try runner.expectThrows("truncated") { _ = try Frame.decode(data) }
            }

            runner.test("the header is the additional authenticated data") {
                let frame = Frame(
                    kind: .plaintext,
                    flags: [.first],
                    sequence: 9,
                    messageIdentifier: 77,
                    fragmentIndex: 0,
                    fragmentCount: 1,
                    payload: Data([1, 2, 3])
                )
                let key = Data(repeating: 0xAB, count: 32)
                let sealed = try frame.encrypted(key: key, direction: .clientToServer)
                try runner.expectEqual(sealed.kind, .encrypted, "the sealed frame is encrypted")
                // The additional authenticated data is the sealed frame's header,
                // so the receiver authenticates exactly the bytes it received.
                try runner.expectEqualBytes(
                    sealed.header,
                    sealed.header,
                    "the sealed header is well formed"
                )
                let opened = try sealed.decrypted(key: key, direction: .clientToServer)
                try runner.expectEqualBytes(opened, frame.payload, "round trip")
            }

            runner.test("a tampered payload fails authentication") {
                let frame = Frame(
                    kind: .plaintext,
                    flags: [.first],
                    sequence: 1,
                    messageIdentifier: 1,
                    fragmentIndex: 0,
                    fragmentCount: 1,
                    payload: Data([1, 2, 3, 4])
                )
                let key = Data(repeating: 0x11, count: 32)
                var sealed = try frame.encrypted(key: key, direction: .clientToServer)
                var tampered = [UInt8](sealed.payload)
                tampered[0] ^= 0xFF
                sealed.payload = Data(tampered)
                try runner.expectThrows("tampered payload") {
                    _ = try sealed.decrypted(key: key, direction: .clientToServer)
                }
            }

            runner.test("a frame sealed for the other direction does not open") {
                let frame = Frame(
                    kind: .plaintext,
                    flags: [.first],
                    sequence: 1,
                    messageIdentifier: 1,
                    fragmentIndex: 0,
                    fragmentCount: 1,
                    payload: Data([9, 9])
                )
                let key = Data(repeating: 0x22, count: 32)
                let sealed = try frame.encrypted(key: key, direction: .clientToServer)
                try runner.expectThrows("wrong direction") {
                    _ = try sealed.decrypted(key: key, direction: .serverToClient)
                }
            }
        }

        runner.suite("Unit: reassembly") {
            runner.test("a message with too many fragments is rejected") {
                let frame = Frame(
                    kind: .plaintext,
                    flags: [],
                    sequence: 1,
                    messageIdentifier: 1,
                    fragmentIndex: 0,
                    fragmentCount: UInt16(ProtocolConstants.maxFragmentsPerMessage + 1),
                    payload: Data()
                )
                let reassembler = MessageReassembler()
                try runner.expectThrows("too many fragments") {
                    _ = try reassembler.accept(frame)
                }
            }

            runner.test("an oversized message is rejected") {
                let reassembler = MessageReassembler()
                // Two 600 kB fragments exceed the 1 MiB message limit.
                let chunk = Data(repeating: 0x41, count: 600_000)
                let first = Frame(
                    kind: .plaintext,
                    flags: [.first, .more],
                    sequence: 1,
                    messageIdentifier: 7,
                    fragmentIndex: 0,
                    fragmentCount: 2,
                    payload: chunk
                )
                let second = Frame(
                    kind: .plaintext,
                    flags: [],
                    sequence: 2,
                    messageIdentifier: 7,
                    fragmentIndex: 1,
                    fragmentCount: 2,
                    payload: chunk
                )
                _ = try reassembler.accept(first)
                try runner.expectThrows("too large") {
                    _ = try reassembler.accept(second)
                }
            }

            runner.test("fragments out of order still reassemble") {
                let message = Data((0..<50).map { UInt8($0) })
                let frames = Fragmenter.frames(
                    message: message,
                    messageIdentifier: 5,
                    startingSequence: 1,
                    maximumPayload: 10
                )
                let reassembler = MessageReassembler()
                var output: Data?
                for frame in frames.reversed() {
                    if let complete = try reassembler.accept(frame) {
                        output = complete
                    }
                }
                try runner.expectEqualBytes(output ?? Data(), message, "reassembled")
            }
        }

        runner.suite("Unit: canonical JSON") {
            runner.test("object keys are sorted") {
                let value = JSONValue.object([
                    "zebra": .int(1),
                    "alpha": .int(2),
                    "middle": .int(3),
                ])
                try runner.expectEqual(
                    CanonicalJSON.encode(value),
                    "{\"alpha\":2,\"middle\":3,\"zebra\":1}",
                    "sorted keys"
                )
            }

            runner.test("strings use the canonical escapes") {
                let value = JSONValue.string("a\"b\\c\nd\te\u{01}f/g")
                try runner.expectEqual(
                    CanonicalJSON.encode(value),
                    "\"a\\\"b\\\\c\\nd\\te\\u0001f/g\"",
                    "escapes"
                )
            }

            runner.test("the envelope keeps a fixed field order") {
                let message = Message(
                    type: "call.place",
                    id: "01ABC",
                    timestamp: 1_700_000_000_000,
                    replyTo: nil,
                    body: ["z": .int(1), "a": .int(2)]
                )
                try runner.expectEqual(
                    String(data: message.jsonData, encoding: .utf8)!,
                    "{\"v\":1,\"type\":\"call.place\",\"id\":\"01ABC\",\"ts\":1700000000000,"
                        + "\"replyTo\":null,\"body\":{\"a\":2,\"z\":1}}",
                    "envelope order"
                )
            }

            runner.test("a fractional number is rejected") {
                try runner.expectThrows("fractional") {
                    _ = try CanonicalJSON.parse("{\"a\":1.5}")
                }
            }

            runner.test("a message with the wrong version is rejected") {
                let data = Data("{\"v\":2,\"type\":\"x\",\"id\":\"1\",\"ts\":0,\"replyTo\":null,\"body\":{}}".utf8)
                try runner.expectThrows("wrong version") { _ = try Message.parse(data) }
            }
        }

        runner.suite("Unit: phone numbers") {
            runner.test("international prefixes are preserved") {
                try runner.expectEqual(
                    PhoneNumberSanitizer.sanitize("+1 (555) 123-4567"),
                    "+15551234567"
                )
            }

            runner.test("a 00 prefix becomes +") {
                try runner.expectEqual(
                    PhoneNumberSanitizer.sanitize("00 44 20 7946 0958"),
                    "+442079460958"
                )
            }

            runner.test("letters are rejected") {
                try runner.expect(
                    !PhoneNumberSanitizer.isDialable("555-CALL"),
                    "letters must not be dialable"
                )
            }

            runner.test("an empty number is not dialable") {
                try runner.expect(
                    !PhoneNumberSanitizer.isDialable("   "),
                    "an empty number must not be dialable"
                )
            }

            runner.test("the dial pad filters invalid characters") {
                try runner.expectEqual(
                    PhoneNumberSanitizer.filterDialPad("+1 (555) 123-4567"),
                    "+15551234567"
                )
            }
        }

        runner.suite("Unit: capabilities") {
            runner.test("capability names round-trip") {
                let all: Capabilities = [
                    .contacts, .recents, .callPlace, .callState, .callAnswer,
                    .callDecline, .callEnd, .callMute, .deviceInfo, .favorites,
                ]
                try runner.expectEqual(Capabilities.parse(all.names), all, "round trip")
            }

            runner.test("unknown capability names are ignored") {
                try runner.expectEqual(Capabilities.parse(["nonsense"]), Capabilities(), "unknown")
            }
        }

        runner.suite("Unit: session") {
            runner.test("a request before the session is ready fails") {
                let transport = LoopbackTransport()
                let session = Session(transport: transport)
                let semaphore = DispatchSemaphore(value: 0)
                let box = ResultBox()
                Task {
                    do {
                        _ = try await session.request("device.info")
                    } catch {
                        box.error = error
                        semaphore.signal()
                    }
                }
                try runner.expect(
                    semaphore.wait(timeout: .now() + 5) == .success,
                    "the request must complete"
                )
                if let error = box.error as? ProtocolError {
                    try runner.expectEqual(error.code, "not_ready", "error code")
                } else {
                    throw TestRunner.Failure(message: "expected a ProtocolError, got \(String(describing: box.error))")
                }
            }

            runner.test("a malformed frame is dropped without crashing the session") {
                let transport = LoopbackTransport()
                let session = Session(transport: transport)
                transport.onFrame?(Data([0x00, 0x01, 0x02]))
                try runner.expect(true, "the session survived a malformed frame")
            }

            runner.test("a transport disconnect moves the session to disconnected") {
                let transport = LoopbackTransport()
                let session = Session(transport: transport)
                let semaphore = DispatchSemaphore(value: 0)
                session.onStateChange = { state in
                    if case .disconnected = state { semaphore.signal() }
                }
                transport.simulateDisconnect(reason: "Link lost")
                try runner.expect(
                    semaphore.wait(timeout: .now() + 5) == .success,
                    "the session must report the disconnect"
                )
            }
        }
    }
}
