package dev.androcall.android.protocol

import java.math.BigInteger
import java.security.SecureRandom

/**
 * NIST P-256 (secp256r1) arithmetic.
 *
 * The scalar multiplication is implemented here rather than relying on the
 * platform provider, because the JCA API exposes no way to derive a public
 * point from a fixed private scalar. Implementing it directly also guarantees
 * that the phone, the Mac and the reference implementation agree byte for
 * byte, whatever the device's crypto provider is.
 */
object P256 {

    private val P = BigInteger(
        "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF", 16
    )
    private val A = P.subtract(BigInteger.valueOf(3))
    private val B = BigInteger(
        "5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B", 16
    )
    private val N = BigInteger(
        "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551", 16
    )
    private val GX = BigInteger(
        "6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296", 16
    )
    private val GY = BigInteger(
        "4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5", 16
    )

    /** A point on the curve; `null` means the point at infinity. */
    private data class Point(val x: BigInteger, val y: BigInteger)

    private val G = Point(GX, GY)

    private fun isOnCurve(point: Point): Boolean {
        val left = point.y.multiply(point.y).mod(P)
        val right = point.x.multiply(point.x).multiply(point.x)
            .add(A.multiply(point.x)).add(B).mod(P)
        return left == right
    }

    private fun add(p: Point?, q: Point?): Point? {
        if (p == null) return q
        if (q == null) return p
        if (p.x == q.x && p.y.add(q.y).mod(P) == BigInteger.ZERO) return null
        val lambda = if (p == q) {
            val numerator = p.x.multiply(p.x).multiply(BigInteger.valueOf(3)).add(A)
            val denominator = p.y.multiply(BigInteger.valueOf(2)).mod(P)
            numerator.multiply(denominator.modInverse(P)).mod(P)
        } else {
            val numerator = q.y.subtract(p.y).mod(P)
            val denominator = q.x.subtract(p.x).mod(P)
            numerator.multiply(denominator.modInverse(P)).mod(P)
        }
        val x = lambda.multiply(lambda).subtract(p.x).subtract(q.x).mod(P)
        val y = lambda.multiply(p.x.subtract(x)).subtract(p.y).mod(P)
        return Point(x, y)
    }

    private fun multiply(scalar: BigInteger, point: Point): Point? {
        var result: Point? = null
        var addend: Point? = point
        var k = scalar
        while (k.signum() > 0) {
            if (k.testBit(0)) {
                result = add(result, addend)
            }
            addend = add(addend, addend)
            k = k.shiftRight(1)
        }
        return result
    }

    /** Generate a random private scalar in [1, n). */
    fun generatePrivateKey(random: SecureRandom = SecureRandom()): ByteArray {
        while (true) {
            val candidate = ByteArray(32)
            random.nextBytes(candidate)
            val value = BigInteger(1, candidate)
            if (value.signum() > 0 && value < N) {
                return toFixedLength(value, 32)
            }
        }
    }

    /** The 65-byte X9.63 uncompressed public point for a private scalar. */
    fun publicKey(privateKey: ByteArray): ByteArray {
        val scalar = BigInteger(1, privateKey)
        require(scalar.signum() > 0 && scalar < N) { "the private scalar is out of range" }
        val point = multiply(scalar, G) ?: throw IllegalStateException("the generator is invalid")
        require(isOnCurve(point)) { "the derived point is not on the curve" }
        return byteArrayOf(0x04) + toFixedLength(point.x, 32) + toFixedLength(point.y, 32)
    }

    /**
     * The raw ECDH shared secret: the X coordinate of `privateKey * peerPublicKey`.
     */
    fun sharedSecret(privateKey: ByteArray, peerPublicKey: ByteArray): ByteArray {
        require(peerPublicKey.size == 65 && peerPublicKey[0] == 0x04.toByte()) {
            "the peer public key must be a 65-byte X9.63 uncompressed point"
        }
        val x = BigInteger(1, peerPublicKey.copyOfRange(1, 33))
        val y = BigInteger(1, peerPublicKey.copyOfRange(33, 65))
        val peer = Point(x, y)
        require(isOnCurve(peer)) { "the peer public key is not on the curve" }
        val shared = multiply(BigInteger(1, privateKey), peer)
            ?: throw IllegalStateException("the shared point is at infinity")
        return toFixedLength(shared.x, 32)
    }

    private fun toFixedLength(value: BigInteger, length: Int): ByteArray {
        val bytes = value.toByteArray()
        val unsigned = if (bytes.size > length && bytes[0] == 0.toByte()) {
            bytes.copyOfRange(1, bytes.size)
        } else {
            bytes
        }
        val output = ByteArray(length)
        if (unsigned.size <= length) {
            unsigned.copyInto(output, length - unsigned.size)
        } else {
            unsigned.copyInto(output)
        }
        return output
    }
}
