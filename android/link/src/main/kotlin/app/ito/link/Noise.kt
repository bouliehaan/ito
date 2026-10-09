package app.ito.link

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/*
 * Noise_XX_25519_ChaChaPoly_SHA256, written straight from the Noise spec
 * (revision 34) on the platform's own primitives: Conscrypt on Android,
 * SunJCE on the host. No third-party crypto. The Swift side is the same
 * spec on CryptoKit, and both are pinned to the cacophony test vector in
 * /vectors, so the two implementations cannot drift apart silently.
 */

const val PROTOCOL_NAME = "Noise_XX_25519_ChaChaPoly_SHA256"
val PROLOGUE: ByteArray = "ito/1".toByteArray()

class DhKey(val priv: ByteArray, val pub: ByteArray) {
    companion object {
        fun generate(): DhKey = fromPrivate(ByteArray(32).also(random::nextBytes))
        fun fromPrivate(priv: ByteArray): DhKey = DhKey(priv.copyOf(), X25519.publicOf(priv))
        private val random = SecureRandom()
    }
}

object X25519 {
    // RFC 8410 wrappers, so raw 32-byte keys go through the standard JCA key specs.
    private val X509_PREFIX = hex("302a300506032b656e032100")
    private val PKCS8_PREFIX = hex("302e020100300506032b656e04220420")
    private val BASEPOINT = ByteArray(32).also { it[0] = 9 }

    fun publicOf(priv: ByteArray): ByteArray = dh(priv, BASEPOINT)

    fun dh(priv: ByteArray, pub: ByteArray): ByteArray {
        require(priv.size == 32 && pub.size == 32) { "x25519 keys are 32 bytes" }
        val kf = KeyFactory.getInstance("XDH")
        val ka = KeyAgreement.getInstance("XDH")
        ka.init(kf.generatePrivate(PKCS8EncodedKeySpec(PKCS8_PREFIX + priv)))
        ka.doPhase(kf.generatePublic(X509EncodedKeySpec(X509_PREFIX + pub)), true)
        return ka.generateSecret()
    }
}

internal object ChaChaPoly {
    private fun nonce(n: Long): ByteArray =
        ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putInt(0).putLong(n).array()

    private fun cipher(mode: Int, key: ByteArray, n: Long, ad: ByteArray): Cipher =
        Cipher.getInstance("ChaCha20-Poly1305").apply {
            init(mode, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce(n)))
            updateAAD(ad)
        }

    fun seal(key: ByteArray, n: Long, ad: ByteArray, pt: ByteArray): ByteArray =
        cipher(Cipher.ENCRYPT_MODE, key, n, ad).doFinal(pt)

    fun open(key: ByteArray, n: Long, ad: ByteArray, ct: ByteArray): ByteArray =
        cipher(Cipher.DECRYPT_MODE, key, n, ad).doFinal(ct)
}

fun sha256(vararg parts: ByteArray): ByteArray =
    MessageDigest.getInstance("SHA-256").run { parts.forEach(::update); digest() }

private fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray =
    Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256"))
        parts.forEach(::update)
        doFinal()
    }

private fun hkdf2(ck: ByteArray, ikm: ByteArray): Pair<ByteArray, ByteArray> {
    val temp = hmac(ck, ikm)
    val out1 = hmac(temp, byteArrayOf(1))
    val out2 = hmac(temp, out1, byteArrayOf(2))
    return out1 to out2
}

class CipherState(private var k: ByteArray? = null) {
    private var n = 0L

    fun hasKey() = k != null

    fun initializeKey(key: ByteArray) {
        k = key
        n = 0
    }

    fun encrypt(ad: ByteArray, pt: ByteArray): ByteArray {
        val key = k ?: return pt
        check(n != -1L) { "nonce exhausted" }
        return ChaChaPoly.seal(key, n, ad, pt).also { n++ }
    }

    // A failed open throws before the counter moves, per the spec.
    fun decrypt(ad: ByteArray, ct: ByteArray): ByteArray {
        val key = k ?: return ct
        check(n != -1L) { "nonce exhausted" }
        return ChaChaPoly.open(key, n, ad, ct).also { n++ }
    }
}

private class SymmetricState {
    var h: ByteArray
    var ck: ByteArray
    val cs = CipherState()

    init {
        val name = PROTOCOL_NAME.toByteArray()
        h = if (name.size <= 32) name.copyOf(32) else sha256(name)
        ck = h.copyOf()
    }

    fun mixKey(ikm: ByteArray) {
        val (a, b) = hkdf2(ck, ikm)
        ck = a
        cs.initializeKey(b)
    }

    fun mixHash(data: ByteArray) {
        h = sha256(h, data)
    }

    fun encryptAndHash(pt: ByteArray): ByteArray = cs.encrypt(h, pt).also(::mixHash)

    fun decryptAndHash(ct: ByteArray): ByteArray = cs.decrypt(h, ct).also { mixHash(ct) }

    fun split(): Pair<CipherState, CipherState> {
        val (a, b) = hkdf2(ck, ByteArray(0))
        return CipherState(a) to CipherState(b)
    }
}

/** The two directions of an established session. Not thread-safe; callers serialize. */
class Transport(private val tx: CipherState, private val rx: CipherState) {
    fun seal(pt: ByteArray): ByteArray = tx.encrypt(EMPTY, pt)
    fun open(ct: ByteArray): ByteArray = rx.decrypt(EMPTY, ct)

    private companion object {
        val EMPTY = ByteArray(0)
    }
}

/**
 * XX:  -> e
 *      <- e, ee, s, es
 *      -> s, se
 * [fixedEphemeral] exists for the test vector only.
 */
class XXHandshake(
    private val initiator: Boolean,
    private val s: DhKey,
    prologue: ByteArray = PROLOGUE,
    private val fixedEphemeral: DhKey? = null,
) {
    private val ss = SymmetricState()
    private var e: DhKey? = null
    private var re: ByteArray? = null
    private var step = 0

    /** The remote static key, known after message 2 (initiator) or 3 (responder). */
    var remoteStatic: ByteArray? = null
        private set

    init {
        ss.mixHash(prologue)
    }

    val isComplete get() = step == 3

    /** Valid once complete: identical on both ends, and binds everything that was exchanged. */
    val handshakeHash: ByteArray get() = ss.h.copyOf()

    private val myTurn get() = (step % 2 == 0) == initiator

    fun writeMessage(payload: ByteArray = ByteArray(0)): ByteArray {
        check(!isComplete && myTurn) { "not our turn to write" }
        var out = ByteArray(0)
        when (step) {
            0 -> out += writeE()
            1 -> {
                out += writeE()
                ss.mixKey(X25519.dh(e!!.priv, re!!))          // ee
                out += ss.encryptAndHash(s.pub)               // s
                ss.mixKey(X25519.dh(s.priv, re!!))            // es (responder side)
            }
            2 -> {
                out += ss.encryptAndHash(s.pub)               // s
                ss.mixKey(X25519.dh(s.priv, re!!))            // se (initiator side)
            }
        }
        out += ss.encryptAndHash(payload)
        step++
        return out
    }

    fun readMessage(message: ByteArray): ByteArray {
        check(!isComplete && !myTurn) { "not our turn to read" }
        var off = 0
        fun take(n: Int): ByteArray {
            require(message.size >= off + n) { "handshake message too short" }
            return message.copyOfRange(off, off + n).also { off += n }
        }
        when (step) {
            0 -> readE(take(32))
            1 -> {
                readE(take(32))
                ss.mixKey(X25519.dh(e!!.priv, re!!))          // ee
                remoteStatic = ss.decryptAndHash(take(48))    // s
                ss.mixKey(X25519.dh(e!!.priv, remoteStatic!!)) // es (initiator side)
            }
            2 -> {
                remoteStatic = ss.decryptAndHash(take(48))    // s
                ss.mixKey(X25519.dh(e!!.priv, remoteStatic!!)) // se (responder side)
            }
        }
        val payload = ss.decryptAndHash(message.copyOfRange(off, message.size))
        step++
        return payload
    }

    fun split(): Transport {
        check(isComplete) { "handshake not finished" }
        val (c1, c2) = ss.split()
        return if (initiator) Transport(c1, c2) else Transport(c2, c1)
    }

    private fun writeE(): ByteArray {
        val key = fixedEphemeral ?: DhKey.generate()
        e = key
        ss.mixHash(key.pub)
        return key.pub
    }

    private fun readE(pub: ByteArray) {
        re = pub
        ss.mixHash(pub)
    }
}

fun hex(s: String): ByteArray =
    ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
