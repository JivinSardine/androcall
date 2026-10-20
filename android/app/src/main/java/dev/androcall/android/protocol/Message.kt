package dev.androcall.android.protocol

import java.security.SecureRandom


/**
 * A protocol message (PROTOCOL.md §4).
 */
data class Message(
    val type: String,
    val id: String = newIdentifier(),
    val timestamp: Long = System.currentTimeMillis(),
    val replyTo: String? = null,
    val body: Map<String, CanonicalJson.Value> = emptyMap(),
    val version: Int = Protocol.VERSION
) {

    /** The canonical JSON bytes. */
    fun toBytes(): ByteArray {
        val members = listOf(
            "v" to CanonicalJson.Value.Num(version.toLong()),
            "type" to CanonicalJson.Value.Str(type),
            "id" to CanonicalJson.Value.Str(id),
            "ts" to CanonicalJson.Value.Num(timestamp),
            "replyTo" to (replyTo?.let { CanonicalJson.Value.Str(it) } ?: CanonicalJson.Value.Null),
            "body" to CanonicalJson.Value.Obj(body)
        )
        val builder = JsonObjectBuilder()
        // The envelope keeps a fixed field order, which the canonical encoder
        // would otherwise sort; build it explicitly.
        val out = StringBuilder()
        out.append('{')
        members.forEachIndexed { index, (key, value) ->
            if (index > 0) out.append(',')
            out.append('"').append(key).append("\":").append(CanonicalJson.encode(value))
        }
        out.append('}')
        return out.toString().toByteArray(Charsets.UTF_8)
    }

    /** The canonical JSON text. */
    fun toJson(): String = String(toBytes(), Charsets.UTF_8)

    fun string(key: String): String? =
        (body[key] as? CanonicalJson.Value.Str)?.value

    fun number(key: String): Long? =
        (body[key] as? CanonicalJson.Value.Num)?.value

    fun bool(key: String): Boolean? =
        (body[key] as? CanonicalJson.Value.Bool)?.value

    fun array(key: String): List<CanonicalJson.Value> =
        (body[key] as? CanonicalJson.Value.Arr)?.items ?: emptyList()

    fun obj(key: String): Map<String, CanonicalJson.Value> =
        (body[key] as? CanonicalJson.Value.Obj)?.members ?: emptyMap()

    companion object {
        /** Parse a message from its canonical JSON bytes. */
        fun parse(bytes: ByteArray): Message {
            val value = CanonicalJson.parse(bytes)
            if (value !is CanonicalJson.Value.Obj) {
                throw IllegalArgumentException("the message is not a JSON object")
            }
            val members = value.members
            val version = (members["v"] as? CanonicalJson.Value.Num)?.value?.toInt()
                ?: throw IllegalArgumentException("the message is missing 'v'")
            if (version != Protocol.VERSION) {
                throw IllegalArgumentException("unsupported protocol version $version")
            }
            val type = (members["type"] as? CanonicalJson.Value.Str)?.value
                ?: throw IllegalArgumentException("the message is missing 'type'")
            val id = (members["id"] as? CanonicalJson.Value.Str)?.value
                ?: throw IllegalArgumentException("the message is missing 'id'")
            val timestamp = (members["ts"] as? CanonicalJson.Value.Num)?.value
                ?: throw IllegalArgumentException("the message is missing 'ts'")
            val replyToValue = members["replyTo"]
                ?: throw IllegalArgumentException("the message is missing 'replyTo'")
            val replyTo = when (replyToValue) {
                is CanonicalJson.Value.Str -> replyToValue.value
                is CanonicalJson.Value.Null -> null
                else -> throw IllegalArgumentException("'replyTo' must be a string or null")
            }
            val body = when (val bodyValue = members["body"]) {
                is CanonicalJson.Value.Obj -> bodyValue.members
                is CanonicalJson.Value.Null -> emptyMap()
                else -> throw IllegalArgumentException("'body' must be an object")
            }
            return Message(type, id, timestamp, replyTo, body, version)
        }

        /** Generate a 26-character base32 identifier. */
        fun newIdentifier(): String {
            val bytes = ByteArray(16)
            SecureRandom().nextBytes(bytes)
            return encodeBase32(bytes)
        }

        /** Encode 16 bytes as a 26-character base32 (Crockford) string. */
        fun encodeBase32(bytes: ByteArray): String {
            val alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
            var value = 0L
            for (index in 0 until 8) {
                value = (value shl 8) or (bytes[index].toLong() and 0xFF)
            }
            val output = CharArray(26)
            var index = 25
            while (index >= 10) {
                output[index] = alphabet[(value and 0x1F).toInt()]
                value = value ushr 5
                index -= 1
            }
            var remainder = value
            var position = index
            while (position >= 0) {
                output[position] = alphabet[(remainder and 0x1F).toInt()]
                remainder = remainder ushr 5
                position -= 1
            }
            return String(output)
        }
    }
}

/**
 * An ephemeral P-256 key pair used for one session handshake.
 */
class EphemeralKeyPair private constructor(privateKey: ByteArray) {

    constructor() : this(P256.generatePrivateKey())


    /** The 32-byte private key. */
    val rawPrivateKey: ByteArray = privateKey.copyOf()

    /** The 65-byte X9.63 uncompressed public key. */
    val publicKeyX963: ByteArray = P256.publicKey(rawPrivateKey)

    /** Derive the raw shared secret (the X coordinate of the shared point). */
    fun sharedSecret(peerPublicKeyX963: ByteArray): ByteArray =
        P256.sharedSecret(rawPrivateKey, peerPublicKeyX963)

    companion object {
        /** Generate a fresh ephemeral key pair. */
        fun generate(): EphemeralKeyPair = EphemeralKeyPair(P256.generatePrivateKey())

        /** Rebuild a key pair from its raw 32-byte private key (used by the tests). */
        fun fromRawPrivateKey(raw: ByteArray): EphemeralKeyPair = EphemeralKeyPair(raw.copyOf())
    }
}
