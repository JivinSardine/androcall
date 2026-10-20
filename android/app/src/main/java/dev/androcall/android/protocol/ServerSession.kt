package dev.androcall.android.protocol

import android.util.Log
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * The phone-side protocol session (PROTOCOL.md §7.3).
 *
 * The phone is the GATT server. It waits for the Mac to send `session.hello`,
 * replies with a challenge, verifies the Mac's proof, and only then accepts
 * any other message. The phone never initiates a call and never re-sends a
 * `call.place`.
 */
class ServerSession(
    /** Called when a request arrives that the phone has to act on. */
    private val requestHandler: (Message) -> Unit,
    /** Called when the phone wants to push an event to the Mac. */
    private val eventSink: (Message) -> Unit,
    /** Called for every outbound frame, so the caller can choose a characteristic. */
    private val frameSink: (Frame) -> Unit,
    /** The largest payload that fits in one write on this connection. */
    private val maxPayload: () -> Int,
    /** The PIN the user entered in the companion app. */
    private val pin: String
) {

    enum class State { IDLE, HANDSHAKING, AUTHENTICATING, READY, FAILED }

    @Volatile
    var state: State = State.IDLE
        private set

    /** The verification code the user compares on both screens. */
    @Volatile
    var verifyCode: String? = null
        private set

    /** The session identifier shown in the diagnostics screen. */
    @Volatile
    var sessionId: String = Message.newIdentifier()
        private set

    private var keys: SessionKeys? = null
    private var handshake: Handshake? = null
    private val reassembler = MessageReassembler()
    private var outgoingSequence = 0L
    private var messageCounter = 0L
    private var highestIncomingSequence = 0L
    private var highestIncomingSequenceSet = false
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "androcall-protocol").apply { isDaemon = true }
    }

    private class Handshake(
        val serverKeyPair: EphemeralKeyPair,
        val serverNonce: ByteArray,
        val salt: ByteArray,
        val iterations: Int
    )

    /** Feed a frame received from the Mac. */
    fun onFrame(data: ByteArray) {
        executor.execute {
            try {
                handle(Frame.decode(data))
            } catch (error: Exception) {
                Log.w(TAG, "dropped a malformed frame", error)
            }
        }
    }

    /** The transport went away. */
    fun onDisconnected() {
        executor.execute {
            keys = null
            handshake = null
            reassembler.reset()
            state = State.IDLE
        }
    }

    private fun handle(frame: Frame) {
        if (highestIncomingSequenceSet && frame.sequence <= highestIncomingSequence) {
            Log.w(TAG, "dropped a replayed frame")
            return
        }
        highestIncomingSequence = frame.sequence
        highestIncomingSequenceSet = true

        var plainFrame = frame
        if (frame.kind == Protocol.KIND_ENCRYPTED) {
            val sessionKeys = keys ?: throw IllegalStateException("encrypted frame before the handshake")
            plainFrame = frame.copy(
                kind = Protocol.KIND_PLAINTEXT,
                payload = frame.decrypted(sessionKeys.clientToServer, Protocol.DIRECTION_CLIENT_TO_SERVER),
                tag = null
            )
        }

        val messageData = reassembler.accept(plainFrame) ?: return
        val message = Message.parse(messageData)

        when (message.type) {
            "session.hello" -> handleHello(message)
            "session.response" -> handleResponse(message)
            "ping" -> sendEvent(Message("pong", replyTo = message.id, body = mapOf(
                "nonce" to CanonicalJson.Value.Num(message.number("nonce") ?: 0)
            )))
            else -> {
                if (state != State.READY) {
                    sendError("invalid_state", "The session is not established.", fatal = true)
                    return
                }
                requestHandler(message)
            }
        }
    }

    private fun handleHello(message: Message) {
        val clientNonceBase64 = message.string("clientNonce")
            ?: throw IllegalArgumentException("session.hello is missing the client nonce")
        val clientNonce = java.util.Base64.getDecoder().decode(clientNonceBase64)
        if (clientNonce.size != 16) {
            throw IllegalArgumentException("the client nonce must be 16 bytes")
        }

        pendingClientNonce = clientNonce
        val salt = ByteArray(16)
        SecureRandom().nextBytes(salt)
        val serverNonce = ByteArray(16)
        SecureRandom().nextBytes(serverNonce)
        val serverKeyPair = EphemeralKeyPair()
        handshake = Handshake(serverKeyPair, serverNonce, salt, Protocol.PBKDF2_ITERATIONS)
        state = State.HANDSHAKING

        val builder = JsonObjectBuilder()
        builder.put("salt", java.util.Base64.getEncoder().encodeToString(salt))
        builder.put("iterations", Protocol.PBKDF2_ITERATIONS)
        builder.put("serverPubKey", java.util.Base64.getEncoder().encodeToString(serverKeyPair.publicKeyX963))
        builder.put("serverNonce", java.util.Base64.getEncoder().encodeToString(serverNonce))
        sendPlain(Message("session.challenge", replyTo = message.id, body = builder.build().members))
    }

    private fun handleResponse(message: Message) {
        val current = handshake ?: throw IllegalStateException("no handshake in progress")
        val clientPublicKey = java.util.Base64.getDecoder().decode(
            message.string("clientPubKey")
                ?: throw IllegalArgumentException("session.response is missing the client public key")
        )
        val proof = java.util.Base64.getDecoder().decode(
            message.string("proof")
                ?: throw IllegalArgumentException("session.response is missing the proof")
        )
        val clientNonce = pendingClientNonce
            ?: throw IllegalStateException("no client nonce")

        val shared = current.serverKeyPair.sharedSecret(clientPublicKey)
        val derived = SessionKeySchedule.derive(
            pin = pin,
            salt = current.salt,
            iterations = current.iterations,
            serverNonce = current.serverNonce,
            clientNonce = clientNonce,
            serverPublicKey = current.serverKeyPair.publicKeyX963,
            clientPublicKey = clientPublicKey,
            ecdhShared = shared
        )
        if (!Crypto.constantTimeEquals(proof, derived.proof)) {
            state = State.FAILED
            sendPlain(Message("session.error", body = mapOf(
                "code" to CanonicalJson.Value.Str("auth_failed"),
                "message" to CanonicalJson.Value.Str("The Mac did not prove it knows the PIN.")
            )))
            return
        }

        keys = derived
        verifyCode = derived.verifyCode
        state = State.READY
        sessionId = Message.newIdentifier()

        val builder = JsonObjectBuilder()
        builder.put("sessionId", sessionId)
        builder.put("verifyCode", derived.verifyCode)
        builder.put("proof", java.util.Base64.getEncoder().encodeToString(derived.proof))
        sendPlain(Message("session.ready", body = builder.build().members))
        Log.i(TAG, "session established")
    }

    private var pendingClientNonce: ByteArray? = null

    /** Push an event to the Mac. */
    fun sendEvent(message: Message) {
        executor.execute {
            try {
                send(message, encrypted = true)
            } catch (error: Exception) {
                Log.w(TAG, "could not send an event", error)
            }
        }
    }

    /** Reply to a request. */
    fun reply(request: Message, body: Map<String, CanonicalJson.Value>) {
        sendEvent(Message(type = "call.result", replyTo = request.id, body = body))
    }

    /** Send an error message. */
    fun sendError(code: String, message: String, fatal: Boolean = false) {
        val builder = JsonObjectBuilder()
        builder.put("code", code)
        builder.put("message", message)
        builder.put("fatal", fatal)
        sendEvent(Message("error", body = builder.build().members))
    }

    private fun sendPlain(message: Message) {
        executor.execute {
            try {
                send(message, encrypted = false)
            } catch (error: Exception) {
                Log.w(TAG, "could not send a handshake message", error)
            }
        }
    }

    private fun send(message: Message, encrypted: Boolean) {
        val sessionKeys = keys
        if (encrypted && sessionKeys == null) {
            throw IllegalStateException("the session is not established")
        }
        val payload = message.toBytes()
        messageCounter += 1
        val maximum = maxOf(1, maxPayload() - Protocol.HEADER_SIZE - Protocol.TAG_SIZE)
        val frames = Fragmenter.frames(payload, messageCounter, outgoingSequence + 1, maximum)
        for (frame in frames) {
            outgoingSequence += 1
            val toSend = if (encrypted) {
                frame.encrypted(sessionKeys!!.serverToClient, Protocol.DIRECTION_SERVER_TO_CLIENT)
            } else {
                frame
            }
            frameSink(toSend)
        }
    }

    companion object {
        private const val TAG = "AndroCallSession"
    }
}
