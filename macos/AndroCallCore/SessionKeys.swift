import Foundation

/// The androcall session key schedule (PROTOCOL.md §6.2).
///
/// The session key is derived from two independent factors:
///
/// * the **PIN** the user typed on both devices (the authorisation factor), and
/// * an **ephemeral P-256 ECDH exchange** (binds the session and defeats a
///   man-in-the-middle who does not know the PIN).
///
/// A peer proves possession of the PIN by returning an HMAC over a transcript
/// that covers every value exchanged so far, and both sides display a short
/// verification code so the user can detect a relay or a MITM.
public struct SessionKeys: Equatable {
    /// Intermediate keying material.
    public let ikm: Data
    /// Key for frames sent by the Mac (client → server).
    public let clientToServer: Data
    /// Key for frames sent by the phone (server → client).
    public let serverToClient: Data
    /// HMAC proof of the PIN over the handshake transcript.
    public let proof: Data
    /// Four-digit verification code shown on both screens.
    public let verifyCode: String
}

public enum SessionKeyError: Error, LocalizedError {
    case invalidPublicKey

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "The peer sent an invalid P-256 public key."
        }
    }
}

public enum SessionKeySchedule {

    /// Build the byte-exact handshake transcript (PROTOCOL.md §6.2).
    public static func transcript(
        serverNonce: Data,
        clientNonce: Data,
        serverPublicKey: Data,
        clientPublicKey: Data,
        salt: Data,
        iterations: Int
    ) -> Data {
        var out = Data()
        out.append(serverNonce)
        out.append(clientNonce)
        out.append(serverPublicKey)
        out.append(clientPublicKey)
        out.append(salt)
        out.append(Data.uint32BigEndian(UInt32(iterations)))
        return out
    }

    /// Derive the session keys.
    ///
    /// - Parameters:
    ///   - pin: the user-supplied 6-digit PIN.
    ///   - salt: 16 random bytes sent by the phone.
    ///   - iterations: PBKDF2 iteration count sent by the phone.
    ///   - ecdhShared: the raw ECDH shared secret (32 bytes).
    public static func derive(
        pin: String,
        salt: Data,
        iterations: Int,
        serverNonce: Data,
        clientNonce: Data,
        serverPublicKey: Data,
        clientPublicKey: Data,
        ecdhShared: Data
    ) -> SessionKeys {
        let pinSecret = AndroCallCrypto.pbkdf2SHA256(
            password: Data(pin.utf8),
            salt: salt,
            iterations: iterations,
            derivedKeyLength: 32
        )

        var hkdfSalt = Data(ProtocolConstants.sessionSaltPrefix.utf8)
        hkdfSalt.append(serverNonce)
        hkdfSalt.append(clientNonce)

        let ikm = AndroCallCrypto.hkdfSHA256(
            inputKeyMaterial: ecdhShared + pinSecret,
            salt: hkdfSalt,
            info: Data(ProtocolConstants.sessionInfo.utf8),
            outputLength: 32
        )

        let c2s = AndroCallCrypto.hkdfSHA256(
            inputKeyMaterial: ikm,
            salt: Data(),
            info: Data(ProtocolConstants.clientToServerInfo.utf8),
            outputLength: 32
        )
        let s2c = AndroCallCrypto.hkdfSHA256(
            inputKeyMaterial: ikm,
            salt: Data(),
            info: Data(ProtocolConstants.serverToClientInfo.utf8),
            outputLength: 32
        )

        let transcript = transcript(
            serverNonce: serverNonce,
            clientNonce: clientNonce,
            serverPublicKey: serverPublicKey,
            clientPublicKey: clientPublicKey,
            salt: salt,
            iterations: iterations
        )

        var proofInput = Data(ProtocolConstants.proofPrefix.utf8)
        proofInput.append(transcript)
        let proof = AndroCallCrypto.hmacSHA256(key: ikm, data: proofInput)

        // verifyCode = first four bytes of HMAC-SHA256(ikm, "androcall-verify-v1"),
        // read big-endian, taken modulo 10000, rendered zero-padded.
        let verifyDigest = AndroCallCrypto.hmacSHA256(
            key: ikm,
            data: Data(ProtocolConstants.verifyPrefix.utf8)
        )
        let codeValue = verifyDigest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let verifyCode = String(format: "%04u", codeValue % 10_000)

        return SessionKeys(
            ikm: ikm,
            clientToServer: c2s,
            serverToClient: s2c,
            proof: proof,
            verifyCode: verifyCode
        )
    }

    /// Compute the shared secret for an ephemeral key pair and a peer public key.
    public static func sharedSecret(
        privateKey: AndroCallCrypto.EphemeralKeyPair,
        peerPublicKey: Data
    ) throws -> Data {
        do {
            return try privateKey.sharedSecret(with: peerPublicKey)
        } catch {
            throw SessionKeyError.invalidPublicKey
        }
    }
}
