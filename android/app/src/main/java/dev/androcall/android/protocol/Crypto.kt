package dev.androcall.android.protocol

/**
 * Cryptographic primitives for the androcall session key schedule.
 *
 * PBKDF2 and HKDF are implemented here rather than taken from the platform so
 * that the byte-for-byte behaviour is identical to the Swift implementation and
 * to the independent Python reference implementation, and so that the code
 * works on every supported API level.
 */
object Crypto {

    private const val HMAC_LENGTH = 32

    /** HMAC-SHA256. */
    fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")
        mac.init(javax.crypto.spec.SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    /** SHA-256. */
    fun sha256(data: ByteArray): ByteArray =
        java.security.MessageDigest.getInstance("SHA-256").digest(data)

    /**
     * PBKDF2-HMAC-SHA256 (RFC 8018).
     *
     * `SecretKeyFactory` only offers `PBKDF2WithHmacSHA256` from API 26, so the
     * construction is done directly to support API 24 and 25 as well.
     */
    fun pbkdf2Sha256(
        password: ByteArray,
        salt: ByteArray,
        iterations: Int,
        derivedKeyLength: Int
    ): ByteArray {
        require(iterations > 0) { "PBKDF2 iteration count must be positive" }
        require(derivedKeyLength > 0) { "derived key length must be positive" }

        val blockCount = (derivedKeyLength + HMAC_LENGTH - 1) / HMAC_LENGTH
        val output = ByteArray(blockCount * HMAC_LENGTH)

        for (blockIndex in 1..blockCount) {
            var block = salt.copyOf()
            block += intToBigEndian(blockIndex)

            var u = hmacSha256(password, block)
            val result = u.copyOf()
            for (iteration in 2..iterations) {
                u = hmacSha256(password, u)
                for (index in result.indices) {
                    result[index] = (result[index].toInt() xor u[index].toInt()).toByte()
                }
            }
            result.copyInto(output, (blockIndex - 1) * HMAC_LENGTH)
        }
        return output.copyOf(derivedKeyLength)
    }

    /** HKDF-SHA256 (RFC 5869). */
    fun hkdfSha256(
        inputKeyMaterial: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        outputLength: Int
    ): ByteArray {
        // RFC 5869 §2.2: an absent salt is a string of HashLen zero bytes; the
        // extract step is still an HMAC over the IKM.
        val effectiveSalt = if (salt.isEmpty()) ByteArray(HMAC_LENGTH) else salt
        val prk = hmacSha256(effectiveSalt, inputKeyMaterial)

        val output = ByteArray(outputLength)
        var block = ByteArray(0)
        var counter = 1
        var offset = 0
        while (offset < outputLength) {
            val input = block + info + byteArrayOf(counter.toByte())
            block = hmacSha256(prk, input)
            val take = minOf(block.size, outputLength - offset)
            block.copyInto(output, offset, 0, take)
            offset += take
            counter += 1
        }
        return output
    }

    /** The 12-byte GCM nonce: a 4-byte direction constant plus the 8-byte big-endian sequence. */
    fun nonce(direction: Int, sequence: Long): ByteArray =
        intToBigEndian(direction) + longToBigEndian(sequence)

    /** AES-256-GCM encryption. The header is the additional authenticated data. */
    fun seal(
        key: ByteArray,
        nonce: ByteArray,
        plaintext: ByteArray,
        additionalData: ByteArray
    ): Pair<ByteArray, ByteArray> {
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.ENCRYPT_MODE,
            javax.crypto.spec.SecretKeySpec(key, "AES"),
            javax.crypto.spec.GCMParameterSpec(128, nonce)
        )
        cipher.updateAAD(additionalData)
        val ciphertext = cipher.doFinal(plaintext)
        // The GCM tag is the last 16 bytes of the output.
        val tag = ciphertext.copyOfRange(ciphertext.size - 16, ciphertext.size)
        return ciphertext.copyOfRange(0, ciphertext.size - 16) to tag
    }

    /** AES-256-GCM decryption. */
    fun open(
        key: ByteArray,
        nonce: ByteArray,
        ciphertext: ByteArray,
        tag: ByteArray,
        additionalData: ByteArray
    ): ByteArray {
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.DECRYPT_MODE,
            javax.crypto.spec.SecretKeySpec(key, "AES"),
            javax.crypto.spec.GCMParameterSpec(128, nonce)
        )
        cipher.updateAAD(additionalData)
        return cipher.doFinal(ciphertext + tag)
    }

    /** Constant-time comparison of two byte arrays. */
    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var difference = 0
        for (index in a.indices) {
            difference = difference or (a[index].toInt() xor b[index].toInt())
        }
        return difference == 0
    }

    fun intToBigEndian(value: Int): ByteArray = byteArrayOf(
        (value ushr 24).toByte(),
        (value ushr 16).toByte(),
        (value ushr 8).toByte(),
        value.toByte()
    )

    fun longToBigEndian(value: Long): ByteArray = ByteArray(8) { index ->
        (value ushr (8 * (7 - index))).toByte()
    }

    fun intToLittleEndian(value: Int): ByteArray = byteArrayOf(
        value.toByte(),
        (value ushr 8).toByte(),
        (value ushr 16).toByte(),
        (value ushr 24).toByte()
    )

    fun longToLittleEndian(value: Long): ByteArray = ByteArray(8) { index ->
        (value ushr (8 * index)).toByte()
    }

    fun shortToLittleEndian(value: Int): ByteArray =
        byteArrayOf(value.toByte(), (value ushr 8).toByte())

    fun shortToBigEndian(value: Int): ByteArray =
        byteArrayOf((value ushr 8).toByte(), value.toByte())

    /** Hex-encode a byte array. */
    fun toHex(data: ByteArray): String {
        val builder = StringBuilder(data.size * 2)
        for (byte in data) {
            builder.append(String.format("%02x", byte))
        }
        return builder.toString()
    }

    /** Decode a hex string. */
    fun fromHex(text: String): ByteArray {
        require(text.length % 2 == 0) { "hex string must have an even length" }
        val output = ByteArray(text.length / 2)
        for (index in output.indices) {
            output[index] = text.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
        return output
    }
}
