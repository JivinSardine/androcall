package dev.androcall.android.protocol

/**
 * The androcall session key schedule (PROTOCOL.md §6.2).
 *
 * The session key is derived from two independent factors: the PIN the user
 * typed on both devices (the authorisation factor) and an ephemeral P-256 ECDH
 * exchange (which binds the session and defeats a man-in-the-middle that does
 * not know the PIN).
 */
data class SessionKeys(
    val ikm: ByteArray,
    val clientToServer: ByteArray,
    val serverToClient: ByteArray,
    val proof: ByteArray,
    val verifyCode: String
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SessionKeys) return false
        return ikm.contentEquals(other.ikm) &&
            clientToServer.contentEquals(other.clientToServer) &&
            serverToClient.contentEquals(other.serverToClient) &&
            proof.contentEquals(other.proof) &&
            verifyCode == other.verifyCode
    }

    override fun hashCode(): Int {
        var result = ikm.contentHashCode()
        result = 31 * result + clientToServer.contentHashCode()
        result = 31 * result + serverToClient.contentHashCode()
        result = 31 * result + proof.contentHashCode()
        result = 31 * result + verifyCode.hashCode()
        return result
    }
}

object SessionKeySchedule {

    const val PROOF_PREFIX = "androcall-proof-v1"
    const val VERIFY_PREFIX = "androcall-verify-v1"
    private const val SESSION_SALT_PREFIX = "androcall-v1"
    private const val SESSION_INFO = "androcall-session-v1"
    private const val CLIENT_TO_SERVER_INFO = "androcall-c2s-v1"
    private const val SERVER_TO_CLIENT_INFO = "androcall-s2c-v1"

    /** Build the byte-exact handshake transcript. */
    fun transcript(
        serverNonce: ByteArray,
        clientNonce: ByteArray,
        serverPublicKey: ByteArray,
        clientPublicKey: ByteArray,
        salt: ByteArray,
        iterations: Int
    ): ByteArray = serverNonce + clientNonce + serverPublicKey + clientPublicKey +
        salt + Crypto.intToBigEndian(iterations)

    /** Derive the session keys. */
    fun derive(
        pin: String,
        salt: ByteArray,
        iterations: Int,
        serverNonce: ByteArray,
        clientNonce: ByteArray,
        serverPublicKey: ByteArray,
        clientPublicKey: ByteArray,
        ecdhShared: ByteArray
    ): SessionKeys {
        val pinSecret = Crypto.pbkdf2Sha256(
            pin.toByteArray(Charsets.UTF_8), salt, iterations, 32
        )
        val hkdfSalt = (SESSION_SALT_PREFIX + "").toByteArray(Charsets.UTF_8) + serverNonce + clientNonce
        val ikm = Crypto.hkdfSha256(
            ecdhShared + pinSecret,
            hkdfSalt,
            SESSION_INFO.toByteArray(Charsets.UTF_8),
            32
        )
        val clientToServer = Crypto.hkdfSha256(
            ikm, ByteArray(0), CLIENT_TO_SERVER_INFO.toByteArray(Charsets.UTF_8), 32
        )
        val serverToClient = Crypto.hkdfSha256(
            ikm, ByteArray(0), SERVER_TO_CLIENT_INFO.toByteArray(Charsets.UTF_8), 32
        )
        val transcript = transcript(
            serverNonce, clientNonce, serverPublicKey, clientPublicKey, salt, iterations
        )
        val proof = Crypto.hmacSha256(
            ikm, PROOF_PREFIX.toByteArray(Charsets.UTF_8) + transcript
        )
        val digest = Crypto.hmacSha256(ikm, VERIFY_PREFIX.toByteArray(Charsets.UTF_8))
        var codeValue = 0L
        for (index in 0 until 4) {
            codeValue = (codeValue shl 8) or (digest[index].toLong() and 0xFF)
        }
        val verifyCode = String.format("%04d", codeValue % 10000)
        return SessionKeys(ikm, clientToServer, serverToClient, proof, verifyCode)
    }
}
