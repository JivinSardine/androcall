import Foundation
import AndroCallCore

/// Loads the shared conformance vectors produced by the independent Python
/// reference implementation.
public enum ConformanceVectors {
    public static func load() throws -> [String: JSONValue] {
        let url = try locate()
        let data = try Data(contentsOf: url)
        guard let root = try? CanonicalJSON.parse(data), let object = root.objectValue else {
            throw TestRunner.Failure(message: "The conformance vector file is not a JSON object.")
        }
        return object
    }

    static func locate() throws -> URL {
        var candidates: [URL] = []
        if let root = ProcessInfo.processInfo.environment["ANDROCALL_REPO_ROOT"] {
            candidates.append(URL(fileURLWithPath: root))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(directory)
            directory = directory.deletingLastPathComponent()
        }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(current)

        for candidate in candidates {
            let url = candidate.appendingPathComponent("protocol/conformance/vectors.json")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw TestRunner.Failure(
            message: "Could not find protocol/conformance/vectors.json. Set ANDROCALL_REPO_ROOT."
        )
    }
}

/// Cross-platform conformance: the Swift implementation must agree with the
/// independent reference implementation byte for byte.
public enum ConformanceTests {
    public static func run(_ runner: TestRunner) {
        runner.suite("Conformance: key schedule") {
            let vectors = try ConformanceVectors.load()
            guard let schedule = vectors["keySchedule"]?.objectValue else {
                throw TestRunner.Failure(message: "The vectors have no keySchedule section.")
            }
            let salt = try Data.requireHex(schedule["salt"]!.stringValue!)
            let serverNonce = try Data.requireHex(schedule["serverNonce"]!.stringValue!)
            let clientNonce = try Data.requireHex(schedule["clientNonce"]!.stringValue!)
            let serverPublic = try Data.requireHex(schedule["serverPublicKey"]!.stringValue!)
            let clientPublic = try Data.requireHex(schedule["clientPublicKey"]!.stringValue!)
            let serverPrivate = try Data.requireHex(schedule["serverPrivate"]!.stringValue!)
            let clientPrivate = try Data.requireHex(schedule["clientPrivate"]!.stringValue!)
            let iterations = Int(schedule["iterations"]!.intValue!)
            let expectedShared = try Data.requireHex(schedule["ecdhSharedSecret"]!.stringValue!)
            let expectedTranscript = try Data.requireHex(schedule["transcript"]!.stringValue!)

            let serverKeys = try AndroCallCrypto.EphemeralKeyPair(rawPrivateKey: serverPrivate)
            let clientKeys = try AndroCallCrypto.EphemeralKeyPair(rawPrivateKey: clientPrivate)

            runner.test("the ephemeral public keys match the reference") {
                try runner.expectEqualBytes(
                    serverKeys.publicKeyX963,
                    serverPublic,
                    "server public key"
                )
                try runner.expectEqualBytes(
                    clientKeys.publicKeyX963,
                    clientPublic,
                    "client public key"
                )
            }

            runner.test("the ECDH shared secret matches the reference") {
                let shared = try serverKeys.sharedSecret(with: clientPublic)
                try runner.expectEqualBytes(shared, expectedShared, "shared secret")
                let other = try clientKeys.sharedSecret(with: serverPublic)
                try runner.expectEqualBytes(other, expectedShared, "shared secret (other side)")
            }

            runner.test("the transcript matches the reference") {
                let transcript = SessionKeySchedule.transcript(
                    serverNonce: serverNonce,
                    clientNonce: clientNonce,
                    serverPublicKey: serverPublic,
                    clientPublicKey: clientPublic,
                    salt: salt,
                    iterations: iterations
                )
                try runner.expectEqualBytes(transcript, expectedTranscript, "transcript")
            }

            runner.test("the derived keys match the reference") {
                let shared = try serverKeys.sharedSecret(with: clientPublic)
                let derived = SessionKeySchedule.derive(
                    pin: schedule["pin"]!.stringValue!,
                    salt: salt,
                    iterations: iterations,
                    serverNonce: serverNonce,
                    clientNonce: clientNonce,
                    serverPublicKey: serverPublic,
                    clientPublicKey: clientPublic,
                    ecdhShared: shared
                )
                try runner.expectEqualBytes(
                    derived.ikm,
                    try Data.requireHex(schedule["ikm"]!.stringValue!),
                    "ikm"
                )
                try runner.expectEqualBytes(
                    derived.clientToServer,
                    try Data.requireHex(schedule["c2sKey"]!.stringValue!),
                    "c2s key"
                )
                try runner.expectEqualBytes(
                    derived.serverToClient,
                    try Data.requireHex(schedule["s2cKey"]!.stringValue!),
                    "s2c key"
                )
                try runner.expectEqualBytes(
                    derived.proof,
                    try Data.requireHex(schedule["proof"]!.stringValue!),
                    "proof"
                )
                try runner.expectEqual(
                    derived.verifyCode,
                    schedule["verifyCode"]!.stringValue!,
                    "verify code"
                )
            }

            runner.test("the PIN changes the derived keys") {
                let shared = try serverKeys.sharedSecret(with: clientPublic)
                let wrong = SessionKeySchedule.derive(
                    pin: "000000",
                    salt: salt,
                    iterations: iterations,
                    serverNonce: serverNonce,
                    clientNonce: clientNonce,
                    serverPublicKey: serverPublic,
                    clientPublicKey: clientPublic,
                    ecdhShared: shared
                )
                try runner.expect(
                    wrong.proof != derived_proof(schedule),
                    "a wrong PIN must produce a different proof"
                )
                try runner.expect(
                    wrong.clientToServer != derived_c2s(schedule),
                    "a wrong PIN must produce a different session key"
                )
            }
        }

        runner.suite("Conformance: framing") {
            let vectors = try ConformanceVectors.load()
            guard let framing = vectors["framing"]?.objectValue else {
                throw TestRunner.Failure(message: "The vectors have no framing section.")
            }
            let expectedFrame = try Data.requireHex(framing["plaintextFrameHex"]!.stringValue!)
            let decoded = framing["plaintextFrameDecoded"]!.objectValue!

            runner.test("a frame decodes to the reference values") {
                let frame = try Frame.decode(expectedFrame)
                try runner.expectEqual(frame.kind, .plaintext, "kind")
                try runner.expectEqual(frame.flags, .first, "flags")
                try runner.expectEqual(frame.sequence, UInt32(decoded["seq"]!.intValue!), "sequence")
                try runner.expectEqual(
                    frame.messageIdentifier,
                    UInt64(decoded["msgId"]!.intValue!),
                    "message id"
                )
                try runner.expectEqual(
                    frame.fragmentIndex,
                    UInt16(decoded["fragIndex"]!.intValue!),
                    "fragment index"
                )
                try runner.expectEqual(
                    frame.fragmentCount,
                    UInt16(decoded["fragCount"]!.intValue!),
                    "fragment count"
                )
                try runner.expectEqualBytes(
                    frame.payload,
                    try Data.requireHex(decoded["payloadHex"]!.stringValue!),
                    "payload"
                )
            }

            runner.test("re-encoding a frame reproduces the reference bytes") {
                let frame = try Frame.decode(expectedFrame)
                try runner.expectEqualBytes(frame.encoded(), expectedFrame, "re-encoded frame")
            }

            runner.test("the GCM nonce matches the reference") {
                let c2s = try Data.requireHex(framing["nonceC2SSeq1"]!.stringValue!)
                let s2c = try Data.requireHex(framing["nonceS2CSeq1"]!.stringValue!)
                try runner.expectEqualBytes(
                    Frame.nonce(direction: .clientToServer, sequence: 1),
                    c2s,
                    "c2s nonce"
                )
                try runner.expectEqualBytes(
                    Frame.nonce(direction: .serverToClient, sequence: 1),
                    s2c,
                    "s2c nonce"
                )
            }

            runner.test("sealing a frame matches the reference") {
                let frame = try Frame.decode(expectedFrame)
                let key = try Data.requireHex(vectors["keySchedule"]!.objectValue!["c2sKey"]!.stringValue!)
                let sealed = try frame.encrypted(key: key, direction: .clientToServer)
                try runner.expectEqualBytes(
                    sealed.encoded(),
                    try Data.requireHex(framing["encryptedFrameHex"]!.stringValue!),
                    "encrypted frame"
                )
                let opened = try sealed.decrypted(key: key, direction: .clientToServer)
                try runner.expectEqualBytes(opened, frame.payload, "decrypted payload")
            }

            runner.test("sealing with the other direction key matches the reference") {
                let frame = try Frame.decode(expectedFrame)
                let key = try Data.requireHex(vectors["keySchedule"]!.objectValue!["s2cKey"]!.stringValue!)
                let sealed = try frame.encrypted(key: key, direction: .serverToClient)
                try runner.expectEqualBytes(
                    sealed.encoded(),
                    try Data.requireHex(framing["encryptedFrameS2CHex"]!.stringValue!),
                    "encrypted frame (s2c)"
                )
            }
        }

        runner.suite("Conformance: fragmentation") {
            let vectors = try ConformanceVectors.load()
            guard let fragmentation = vectors["fragmentation"]?.objectValue else {
                throw TestRunner.Failure(message: "The vectors have no fragmentation section.")
            }
            let message = try Data.requireHex(fragmentation["messageHex"]!.stringValue!)
            let expectedFrames = (fragmentation["frames"]!.arrayValue ?? []).compactMap { $0.stringValue }

            runner.test("fragmentation matches the reference") {
                let frames = Fragmenter.frames(
                    message: message,
                    messageIdentifier: 0xFEEDFACE,
                    startingSequence: 7,
                    maximumPayload: 16
                )
                try runner.expectEqual(frames.count, expectedFrames.count, "frame count")
                for (index, frame) in frames.enumerated() {
                    try runner.expectEqualBytes(
                        frame.encoded(),
                        try Data.requireHex(expectedFrames[index]),
                        "frame \(index)"
                    )
                }
            }

            runner.test("fragments reassemble into the original message") {
                let frames = Fragmenter.frames(
                    message: message,
                    messageIdentifier: 42,
                    startingSequence: 1,
                    maximumPayload: 7
                )
                let reassembler = MessageReassembler()
                var output: Data?
                for frame in frames {
                    if let complete = try reassembler.accept(frame) {
                        output = complete
                    }
                }
                try runner.expectEqualBytes(output ?? Data(), message, "reassembled message")
            }
        }

        runner.suite("Conformance: canonical JSON") {
            let vectors = try ConformanceVectors.load()
            guard let canonical = vectors["canonicalJson"]?.objectValue else {
                throw TestRunner.Failure(message: "The vectors have no canonicalJson section.")
            }
            let messages = canonical["messages"]!.arrayValue ?? []

            for entry in messages {
                guard let object = entry.objectValue else { continue }
                let name = object["name"]!.stringValue!
                let expected = object["json"]!.stringValue!
                let parsed = object["parsed"]!.objectValue!

                runner.test("the canonical encoding of \(name) matches the reference") {
                    let body = parsed["body"]!.objectValue ?? [:]
                    let message = Message(
                        type: parsed["type"]!.stringValue!,
                        id: parsed["id"]!.stringValue!,
                        timestamp: parsed["ts"]!.intValue!,
                        replyTo: parsed["replyTo"]!.stringValue,
                        body: body
                    )
                    try runner.expectEqual(
                        String(data: message.jsonData, encoding: .utf8)!,
                        expected,
                        "canonical JSON"
                    )
                }

                runner.test("\(name) round-trips through the parser") {
                    let data = Data(expected.utf8)
                    let message = try Message.parse(data)
                    try runner.expectEqual(message.type, parsed["type"]!.stringValue!, "type")
                    try runner.expectEqual(message.id, parsed["id"]!.stringValue!, "id")
                    try runner.expectEqual(message.timestamp, parsed["ts"]!.intValue!, "ts")
                    try runner.expectEqualBytes(message.jsonData, data, "re-encoded JSON")
                }
            }
        }

        runner.suite("Conformance: phone numbers") {
            let vectors = try ConformanceVectors.load()
            let cases = vectors["phoneNumbers"]?.objectValue?["cases"]?.arrayValue ?? []
            runner.test("sanitisation matches the reference") {
                for entry in cases {
                    guard let object = entry.objectValue else { continue }
                    let input = object["input"]!.stringValue!
                    let expected = object["expected"]!.stringValue!
                    try runner.expectEqual(
                        PhoneNumberSanitizer.sanitize(input),
                        expected,
                        "sanitize(\(input))"
                    )
                }
            }
        }
    }

    private static func derived_proof(_ schedule: [String: JSONValue]) -> Data {
        Data(hexString: schedule["proof"]!.stringValue!)!
    }

    private static func derived_c2s(_ schedule: [String: JSONValue]) -> Data {
        Data(hexString: schedule["c2sKey"]!.stringValue!)!
    }
}
