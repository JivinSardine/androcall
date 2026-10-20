import CryptoKit
import Foundation

/// Cryptographic primitives used by the androcall session key schedule.
///
/// PBKDF2 and HKDF are implemented here (rather than taken from CommonCrypto)
/// so that the byte-for-byte behaviour is identical to the Kotlin implementation
/// and to the independent Python reference implementation, and so that the code
/// works identically on every macOS version and Android API level.
public enum AndroCallCrypto {

    // MARK: - Hashing

    /// HMAC-SHA256.
    public static func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let code = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(code)
    }

    /// SHA-256.
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: - PBKDF2

    /// PBKDF2-HMAC-SHA256 (RFC 8018).
    public static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        derivedKeyLength: Int
    ) -> Data {
        precondition(iterations > 0, "PBKDF2 iteration count must be positive")
        precondition(derivedKeyLength > 0, "derived key length must be positive")

        let hmacLength = 32
        let blockCount = Int(ceil(Double(derivedKeyLength) / Double(hmacLength)))
        var derived = Data()
        derived.reserveCapacity(blockCount * hmacLength)

        for blockIndex in 1...blockCount {
            var block = salt
            block.append(contentsOf: Data.uint32BigEndian(UInt32(blockIndex)))

            var u = hmacSHA256(key: password, data: block)
            var result = u
            if iterations > 1 {
                for _ in 2...iterations {
                    u = hmacSHA256(key: password, data: u)
                    result.xorInPlace(with: u)
                }
            }
            derived.append(result)
        }

        return derived.prefix(derivedKeyLength)
    }

    // MARK: - HKDF

    /// HKDF-SHA256 (RFC 5869) extract-and-expand.
    public static func hkdfSHA256(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputLength: Int
    ) -> Data {
        // RFC 5869 specifies an all-zero salt of HashLen bytes when the salt is
        // absent. Passing an explicit zero salt (rather than an empty one) keeps
        // the behaviour identical across CryptoKit and the JVM.
        let effectiveSalt = salt.isEmpty ? Data(repeating: 0, count: 32) : salt
        let prk = hmacSHA256(key: effectiveSalt, data: inputKeyMaterial)
        var output = Data()
        output.reserveCapacity(outputLength)

        var block = Data()
        var counter: UInt8 = 1
        while output.count < outputLength {
            var input = block
            input.append(info)
            input.append(counter)
            block = hmacSHA256(key: prk, data: input)
            output.append(block)
            counter += 1
        }

        return output.prefix(outputLength)
    }

    // MARK: - P-256 ECDH

    /// An ephemeral P-256 key pair used for one session handshake.
    public struct EphemeralKeyPair {
        public let privateKey: P256.KeyAgreement.PrivateKey
        public let publicKeyX963: Data

        public init() {
            let key = P256.KeyAgreement.PrivateKey()
            privateKey = key
            publicKeyX963 = key.publicKey.x963Representation
        }

        /// Rebuild a key pair from its 32-byte raw private key.
        ///
        /// Used by the conformance tests to reproduce the reference vectors.
        public init(rawPrivateKey: Data) throws {
            let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
            privateKey = key
            publicKeyX963 = key.publicKey.x963Representation
        }

        /// Derive the raw shared secret (the X coordinate of the shared point).
        public func sharedSecret(with peerPublicKeyX963: Data) throws -> Data {
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKeyX963)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            return secret.withUnsafeBytes { Data($0) }
        }
    }

    // MARK: - AES-256-GCM

    /// Seal `plaintext` with AES-256-GCM.
    ///
    /// The frame header is passed as additional authenticated data so that the
    /// header cannot be tampered with independently of the payload.
    public static func seal(
        key: Data,
        nonce: Data,
        plaintext: Data,
        authenticating additionalData: Data
    ) throws -> (ciphertext: Data, tag: Data) {
        let symmetricKey = SymmetricKey(data: key)
        let box = try AES.GCM.seal(
            plaintext,
            using: symmetricKey,
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: additionalData
        )
        return (box.ciphertext, box.tag)
    }

    /// Open an AES-256-GCM sealed box.
    public static func open(
        key: Data,
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        authenticating additionalData: Data
    ) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(box, using: symmetricKey, authenticating: additionalData)
    }

    // MARK: - Constant-time comparison

    /// Compare two byte sequences without an early exit.
    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            difference |= a ^ b
        }
        return difference == 0
    }
}

extension Data {
    /// XOR `other` into this buffer in place.
    mutating func xorInPlace(with other: Data) {
        precondition(count == other.count, "xorInPlace requires equal lengths")
        withUnsafeMutableBytes { (lhs: UnsafeMutableRawBufferPointer) in
            other.withUnsafeBytes { (rhs: UnsafeRawBufferPointer) in
                for index in 0..<lhs.count {
                    lhs[index] ^= rhs[index]
                }
            }
        }
    }

    /// Big-endian encoding of a 32-bit value.
    static func uint32BigEndian(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    /// Big-endian encoding of a 64-bit value.
    static func uint64BigEndian(_ value: UInt64) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 8)
    }

    /// Big-endian encoding of a 16-bit value.
    static func uint16BigEndian(_ value: UInt16) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 2)
    }

    /// Little-endian encoding of a 32-bit value (the frame wire format).
    static func uint32LittleEndian(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }

    /// Little-endian encoding of a 64-bit value (the frame wire format).
    static func uint64LittleEndian(_ value: UInt64) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 8)
    }

    /// Little-endian encoding of a 16-bit value (the frame wire format).
    static func uint16LittleEndian(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 2)
    }
}
