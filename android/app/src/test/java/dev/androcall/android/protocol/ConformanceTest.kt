package dev.androcall.android.protocol

import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.Paths
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cross-platform conformance: the Kotlin implementation must agree with the
 * independent Python reference implementation byte for byte.
 *
 * The vectors live in `protocol/conformance/vectors.json` and are shared with
 * the Swift test suite, so a protocol change that only updates one platform
 * fails the other platform's suite.
 */
class ConformanceTest {

    private fun vectors(): JSONObject {
        val candidates = listOf(
            System.getProperty("androcall.repoRoot"),
            System.getenv("ANDROCALL_REPO_ROOT"),
            System.getProperty("user.dir") + "/..",
            System.getProperty("user.dir")
        )
        for (candidate in candidates) {
            val root = candidate ?: continue
            if (root.isBlank()) continue
            val file = File(root, "protocol/conformance/vectors.json")
            if (file.exists()) {
                return JSONObject(file.readText())
            }
        }
        throw IllegalStateException(
            "Could not find protocol/conformance/vectors.json. " +
                "Set ANDROCALL_REPO_ROOT or pass -Dandrocall.repoRoot=<repo>."
        )
    }

    private fun hex(value: String): ByteArray = Crypto.fromHex(value)

    /** Convert a parsed JSON object into canonical values. */
    private fun toCanonical(json: JSONObject): Map<String, CanonicalJson.Value> {
        val members = LinkedHashMap<String, CanonicalJson.Value>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            members[key] = when (val value = json.get(key)) {
                is JSONObject -> CanonicalJson.Value.Obj(toCanonical(value))
                is org.json.JSONArray -> CanonicalJson.Value.Arr(
                    (0 until value.length()).map { index -> toCanonical(value.get(index)) }
                )
                is Boolean -> CanonicalJson.Value.Bool(value)
                is Int -> CanonicalJson.Value.Num(value.toLong())
                is Long -> CanonicalJson.Value.Num(value)
                is Double -> CanonicalJson.Value.Num(value.toLong())
                JSONObject.NULL -> CanonicalJson.Value.Null
                else -> CanonicalJson.Value.Str(value.toString())
            }
        }
        return members
    }

    /** Convert a parsed JSON array element into a canonical value. */
    private fun toCanonical(value: Any): CanonicalJson.Value = when (value) {
        is JSONObject -> CanonicalJson.Value.Obj(toCanonical(value))
        is org.json.JSONArray -> CanonicalJson.Value.Arr(
            (0 until value.length()).map { index -> toCanonical(value.get(index)) }
        )
        is Boolean -> CanonicalJson.Value.Bool(value)
        is Int -> CanonicalJson.Value.Num(value.toLong())
        is Long -> CanonicalJson.Value.Num(value)
        is Double -> CanonicalJson.Value.Num(value.toLong())
        JSONObject.NULL -> CanonicalJson.Value.Null
        else -> CanonicalJson.Value.Str(value.toString())
    }

    private fun assertHexEquals(expected: String, actual: ByteArray, label: String) {
        assertEquals(label, expected, Crypto.toHex(actual))
    }

    @Test
    fun `the key schedule matches the reference`() {
        val schedule = vectors().getJSONObject("keySchedule")

        val serverPrivate = hex(schedule.getString("serverPrivate"))
        val clientPrivate = hex(schedule.getString("clientPrivate"))
        val serverPublic = hex(schedule.getString("serverPublicKey"))
        val clientPublic = hex(schedule.getString("clientPublicKey"))

        val serverKeys = EphemeralKeyPair.fromRawPrivateKey(serverPrivate)
        val clientKeys = EphemeralKeyPair.fromRawPrivateKey(clientPrivate)

        assertHexEquals(schedule.getString("serverPublicKey"), serverKeys.publicKeyX963, "server public key")
        assertHexEquals(schedule.getString("clientPublicKey"), clientKeys.publicKeyX963, "client public key")

        val expectedShared = hex(schedule.getString("ecdhSharedSecret"))
        val sharedFromServer = serverKeys.sharedSecret(clientPublic)
        val sharedFromClient = clientKeys.sharedSecret(serverPublic)
        assertArrayEquals("shared secret (server side)", expectedShared, sharedFromServer)
        assertArrayEquals("shared secret (client side)", expectedShared, sharedFromClient)

        val transcript = SessionKeySchedule.transcript(
            hex(schedule.getString("serverNonce")),
            hex(schedule.getString("clientNonce")),
            serverPublic,
            clientPublic,
            hex(schedule.getString("salt")),
            schedule.getInt("iterations")
        )
        assertHexEquals(schedule.getString("transcript"), transcript, "transcript")

        val derived = SessionKeySchedule.derive(
            pin = schedule.getString("pin"),
            salt = hex(schedule.getString("salt")),
            iterations = schedule.getInt("iterations"),
            serverNonce = hex(schedule.getString("serverNonce")),
            clientNonce = hex(schedule.getString("clientNonce")),
            serverPublicKey = serverPublic,
            clientPublicKey = clientPublic,
            ecdhShared = sharedFromServer
        )
        assertHexEquals(schedule.getString("ikm"), derived.ikm, "ikm")
        assertHexEquals(schedule.getString("c2sKey"), derived.clientToServer, "c2s key")
        assertHexEquals(schedule.getString("s2cKey"), derived.serverToClient, "s2c key")
        assertHexEquals(schedule.getString("proof"), derived.proof, "proof")
        assertEquals("verify code", schedule.getString("verifyCode"), derived.verifyCode)
    }

    @Test
    fun `a wrong PIN produces a different proof`() {
        val schedule = vectors().getJSONObject("keySchedule")
        val serverKeys = EphemeralKeyPair.fromRawPrivateKey(hex(schedule.getString("serverPrivate")))
        val shared = serverKeys.sharedSecret(hex(schedule.getString("clientPublicKey")))

        val correct = SessionKeySchedule.derive(
            pin = schedule.getString("pin"),
            salt = hex(schedule.getString("salt")),
            iterations = schedule.getInt("iterations"),
            serverNonce = hex(schedule.getString("serverNonce")),
            clientNonce = hex(schedule.getString("clientNonce")),
            serverPublicKey = hex(schedule.getString("serverPublicKey")),
            clientPublicKey = hex(schedule.getString("clientPublicKey")),
            ecdhShared = shared
        )
        val wrong = SessionKeySchedule.derive(
            pin = "000000",
            salt = hex(schedule.getString("salt")),
            iterations = schedule.getInt("iterations"),
            serverNonce = hex(schedule.getString("serverNonce")),
            clientNonce = hex(schedule.getString("clientNonce")),
            serverPublicKey = hex(schedule.getString("serverPublicKey")),
            clientPublicKey = hex(schedule.getString("clientPublicKey")),
            ecdhShared = shared
        )
        assertTrue("a wrong PIN must produce a different proof", !correct.proof.contentEquals(wrong.proof))
        assertTrue(
            "a wrong PIN must produce a different session key",
            !correct.clientToServer.contentEquals(wrong.clientToServer)
        )
    }

    @Test
    fun `frames match the reference`() {
        val framing = vectors().getJSONObject("framing")
        val expectedFrame = hex(framing.getString("plaintextFrameHex"))
        val decoded = Frame.decode(expectedFrame)
        val expected = framing.getJSONObject("plaintextFrameDecoded")

        assertEquals("kind", expected.getInt("kind"), decoded.kind)
        assertEquals("flags", expected.getInt("flags"), decoded.flags)
        assertEquals("sequence", expected.getLong("seq"), decoded.sequence)
        assertEquals("message id", expected.getLong("msgId"), decoded.messageId)
        assertEquals("fragment index", expected.getInt("fragIndex"), decoded.fragmentIndex)
        assertEquals("fragment count", expected.getInt("fragCount"), decoded.fragmentCount)
        assertHexEquals(expected.getString("payloadHex"), decoded.payload, "payload")

        assertArrayEquals(
            "re-encoded frame",
            expectedFrame,
            decoded.encode()
        )

        assertHexEquals(
            framing.getString("nonceC2SSeq1"),
            Crypto.nonce(Protocol.DIRECTION_CLIENT_TO_SERVER, 1),
            "c2s nonce"
        )
        assertHexEquals(
            framing.getString("nonceS2CSeq1"),
            Crypto.nonce(Protocol.DIRECTION_SERVER_TO_CLIENT, 1),
            "s2c nonce"
        )

        val key = hex(vectors().getJSONObject("keySchedule").getString("c2sKey"))
        val sealed = decoded.encrypted(key, Protocol.DIRECTION_CLIENT_TO_SERVER)
        assertHexEquals(framing.getString("encryptedFrameHex"), sealed.encode(), "encrypted frame")
        assertArrayEquals("decrypted payload", decoded.payload, sealed.decrypted(key, Protocol.DIRECTION_CLIENT_TO_SERVER))

        val s2cKey = hex(vectors().getJSONObject("keySchedule").getString("s2cKey"))
        val sealedS2C = decoded.encrypted(s2cKey, Protocol.DIRECTION_SERVER_TO_CLIENT)
        assertHexEquals(
            framing.getString("encryptedFrameS2CHex"),
            sealedS2C.encode(),
            "encrypted frame (s2c)"
        )
    }

    @Test
    fun `fragmentation matches the reference`() {
        val fragmentation = vectors().getJSONObject("fragmentation")
        val message = hex(fragmentation.getString("messageHex"))
        val expectedFrames = fragmentation.getJSONArray("frames")

        val frames = Fragmenter.frames(message, 0xFEEDFACE, 7, 16)
        assertEquals("frame count", expectedFrames.length(), frames.size)
        for (index in frames.indices) {
            assertArrayEquals(
                "frame $index",
                hex(expectedFrames.getString(index)),
                frames[index].encode()
            )
        }

        val reassembler = MessageReassembler()
        var output: ByteArray? = null
        for (frame in frames) {
            val complete = reassembler.accept(frame)
            if (complete != null) output = complete
        }
        assertArrayEquals("reassembled message", message, output)
    }

    @Test
    fun `canonical JSON matches the reference`() {
        val canonical = vectors().getJSONObject("canonicalJson")
        val messages = canonical.getJSONArray("messages")

        for (index in 0 until messages.length()) {
            val entry = messages.getJSONObject(index)
            val name = entry.getString("name")
            val expectedJson = entry.getString("json")
            val parsed = entry.getJSONObject("parsed")

            val body = toCanonical(parsed.getJSONObject("body"))

            val message = Message(
                type = parsed.getString("type"),
                id = parsed.getString("id"),
                timestamp = parsed.getLong("ts"),
                replyTo = if (parsed.isNull("replyTo")) null else parsed.getString("replyTo"),
                body = body
            )
            assertEquals("canonical JSON of $name", expectedJson, message.toJson())
        }
    }

    @Test
    fun `phone number sanitisation matches the reference`() {
        val numbers = vectors().getJSONObject("phoneNumbers")
        val cases = numbers.getJSONArray("cases")
        for (index in 0 until cases.length()) {
            val entry = cases.getJSONObject(index)
            assertEquals(
                "sanitize(${entry.getString("input")})",
                entry.getString("expected"),
                PhoneNumberSanitizer.sanitize(entry.getString("input"))
            )
        }
    }

    @Test
    fun `a message round-trips through the parser`() {
        val canonical = vectors().getJSONObject("canonicalJson")
        val messages = canonical.getJSONArray("messages")
        for (index in 0 until messages.length()) {
            val expectedJson = messages.getJSONObject(index).getString("json")
            val message = Message.parse(expectedJson.toByteArray(Charsets.UTF_8))
            assertNotNull(message)
            assertEquals("re-encoded JSON", expectedJson, message.toJson())
        }
    }
}
