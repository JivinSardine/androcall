package dev.androcall.android.protocol

/**
 * One androcall frame (PROTOCOL.md §3).
 *
 * A frame is the unit that travels in a single BLE write. Logical messages
 * larger than the negotiated ATT MTU are split across several frames that
 * share a `messageId`.
 */
data class Frame(
    val kind: Int,
    val flags: Int,
    val sequence: Long,
    val messageId: Long,
    val fragmentIndex: Int,
    val fragmentCount: Int,
    val payload: ByteArray,
    val tag: ByteArray? = null
) {

    /**
     * The 23-byte frame header. It is the additional authenticated data for
     * encrypted frames, so the header cannot be modified in flight.
     */
    fun header(): ByteArray {
        val out = ByteArray(Protocol.HEADER_SIZE)
        var offset = 0
        System.arraycopy(Protocol.MAGIC, 0, out, offset, 2); offset += 2
        out[offset++] = Protocol.FRAME_VERSION.toByte()
        out[offset++] = kind.toByte()
        out[offset++] = flags.toByte()
        System.arraycopy(Crypto.intToLittleEndian(sequence.toInt()), 0, out, offset, 4); offset += 4
        System.arraycopy(Crypto.longToLittleEndian(messageId), 0, out, offset, 8); offset += 8
        System.arraycopy(Crypto.shortToLittleEndian(fragmentIndex), 0, out, offset, 2); offset += 2
        System.arraycopy(Crypto.shortToLittleEndian(fragmentCount), 0, out, offset, 2); offset += 2
        System.arraycopy(Crypto.shortToLittleEndian(payload.size), 0, out, offset, 2)
        return out
    }

    /** The complete wire representation. */
    fun encode(): ByteArray {
        val out = ByteArray(Protocol.HEADER_SIZE + payload.size + (tag?.size ?: 0))
        System.arraycopy(header(), 0, out, 0, Protocol.HEADER_SIZE)
        System.arraycopy(payload, 0, out, Protocol.HEADER_SIZE, payload.size)
        if (tag != null) {
            System.arraycopy(tag, 0, out, Protocol.HEADER_SIZE + payload.size, tag.size)
        }
        return out
    }

    /**
     * Seal this frame's payload with AES-256-GCM.
     *
     * The additional authenticated data is the header of the **sealed** frame,
     * so the receiver authenticates exactly the bytes it received.
     */
    fun encrypted(key: ByteArray, direction: Int): Frame {
        val sealed = copy(kind = Protocol.KIND_ENCRYPTED)
        val header = sealed.header()
        val nonce = Crypto.nonce(direction, sequence)
        val (ciphertext, tag) = Crypto.seal(key, nonce, payload, header)
        return sealed.copy(payload = ciphertext, tag = tag)
    }

    /** Open the payload of an encrypted frame. */
    fun decrypted(key: ByteArray, direction: Int): ByteArray {
        if (kind != Protocol.KIND_ENCRYPTED) return payload
        val tagBytes = tag ?: throw IllegalArgumentException("the encrypted frame has no tag")
        val nonce = Crypto.nonce(direction, sequence)
        return Crypto.open(key, nonce, payload, tagBytes, header())
    }

    companion object {
        /** Parse a frame from its wire representation. */
        fun decode(data: ByteArray): Frame {
            if (data.size < Protocol.HEADER_SIZE) {
                throw IllegalArgumentException("the frame is shorter than the header")
            }
            if (data[0] != Protocol.MAGIC[0] || data[1] != Protocol.MAGIC[1]) {
                throw IllegalArgumentException("the frame does not start with the androcall magic bytes")
            }
            if (data[2] != Protocol.FRAME_VERSION.toByte()) {
                throw IllegalArgumentException("unsupported frame version")
            }
            val kind = data[3].toInt() and 0xFF
            val flags = data[4].toInt() and 0xFF
            val sequence = littleEndianInt(data, 5).toLong() and 0xFFFFFFFFL
            val messageId = littleEndianLong(data, 9)
            val fragmentIndex = littleEndianShort(data, 17)
            val fragmentCount = littleEndianShort(data, 19)
            val length = littleEndianShort(data, 21)
            if (data.size < Protocol.HEADER_SIZE + length) {
                throw IllegalArgumentException("the frame payload is truncated")
            }
            val payload = data.copyOfRange(Protocol.HEADER_SIZE, Protocol.HEADER_SIZE + length)
            var tag: ByteArray? = null
            if (kind == Protocol.KIND_ENCRYPTED) {
                if (data.size < Protocol.HEADER_SIZE + length + Protocol.TAG_SIZE) {
                    throw IllegalArgumentException("the frame tag is truncated")
                }
                tag = data.copyOfRange(
                    Protocol.HEADER_SIZE + length,
                    Protocol.HEADER_SIZE + length + Protocol.TAG_SIZE
                )
            }
            return Frame(kind, flags, sequence, messageId, fragmentIndex, fragmentCount, payload, tag)
        }

        private fun littleEndianInt(data: ByteArray, offset: Int): Int =
            (data[offset].toInt() and 0xFF) or
                ((data[offset + 1].toInt() and 0xFF) shl 8) or
                ((data[offset + 2].toInt() and 0xFF) shl 16) or
                ((data[offset + 3].toInt() and 0xFF) shl 24)

        private fun littleEndianShort(data: ByteArray, offset: Int): Int =
            (data[offset].toInt() and 0xFF) or ((data[offset + 1].toInt() and 0xFF) shl 8)

        private fun littleEndianLong(data: ByteArray, offset: Int): Long {
            var value = 0L
            for (index in 7 downTo 0) {
                value = (value shl 8) or (data[offset + index].toLong() and 0xFF)
            }
            return value
        }
    }
}

/** Splits a logical message into frames that fit within `maximumPayload` bytes. */
object Fragmenter {
    fun frames(
        message: ByteArray,
        messageId: Long,
        startingSequence: Long,
        maximumPayload: Int
    ): List<Frame> {
        require(maximumPayload > 0) { "maximumPayload must be positive" }
        val chunks: List<ByteArray> = if (message.isEmpty()) {
            listOf(ByteArray(0))
        } else {
            message.toList().chunked(maximumPayload).map { it.toByteArray() }
        }
        return chunks.mapIndexed { index, chunk ->
            var flags = 0
            if (index == 0) flags = flags or Protocol.FLAG_FIRST
            if (index != chunks.size - 1) flags = flags or Protocol.FLAG_MORE
            Frame(
                kind = Protocol.KIND_PLAINTEXT,
                flags = flags,
                sequence = startingSequence + index,
                messageId = messageId,
                fragmentIndex = index,
                fragmentCount = chunks.size,
                payload = chunk
            )
        }
    }
}

/** Reassembles frames into logical messages. */
class MessageReassembler {

    private class Buffer(
        val fragmentCount: Int,
        val parts: MutableMap<Int, ByteArray> = HashMap(),
        var totalBytes: Int = 0
    )

    private val buffers = HashMap<Long, Buffer>()

    /** Feed a frame. Returns the complete message when the last fragment arrives. */
    @Throws(IllegalArgumentException::class)
    fun accept(frame: Frame): ByteArray? {
        if (frame.fragmentCount < 1) throw IllegalArgumentException("invalid fragment count")
        if (frame.fragmentCount > Protocol.MAX_FRAGMENTS_PER_MESSAGE) {
            throw IllegalArgumentException("the message has too many fragments")
        }
        if (frame.fragmentIndex >= frame.fragmentCount) {
            throw IllegalArgumentException("the fragment index is outside the fragment count")
        }
        val buffer = buffers.getOrPut(frame.messageId) { Buffer(frame.fragmentCount) }
        if (buffer.fragmentCount != frame.fragmentCount) {
            throw IllegalArgumentException("the fragments disagree about the fragment count")
        }
        if (!buffer.parts.containsKey(frame.fragmentIndex)) {
            buffer.totalBytes += frame.payload.size
            if (buffer.totalBytes > Protocol.MAX_MESSAGE_BYTES) {
                buffers.remove(frame.messageId)
                throw IllegalArgumentException("the message exceeds the maximum message size")
            }
        }
        buffer.parts[frame.fragmentIndex] = frame.payload
        if (buffer.parts.size != frame.fragmentCount) return null

        buffers.remove(frame.messageId)
        var out = ByteArray(buffer.totalBytes)
        var offset = 0
        for (index in 0 until frame.fragmentCount) {
            val part = buffer.parts[index] ?: throw IllegalArgumentException("a fragment is missing")
            System.arraycopy(part, 0, out, offset, part.size)
            offset += part.size
        }
        return out
    }

    /** Drop any partially received message. */
    fun reset() {
        buffers.clear()
    }
}
