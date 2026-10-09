package app.ito.link

import java.security.SecureRandom

/*
 * Pairing = Bluetooth-style numeric comparison, run INSIDE the Noise channel.
 *
 * A short code taken straight from the handshake hash is not enough: a
 * man-in-the-middle finishes one leg, then grinds its own last handshake
 * message on the other leg until the two 6-digit codes collide (a million
 * tries is milliseconds). So, like Bluetooth SSP, the phone commits to a
 * nonce before it can see the Mac's:
 *
 *   phone -> pair.commit  C  = SHA256("ito/commit" || Np)
 *   mac   -> pair.nonce   Nm
 *   phone -> pair.reveal  Np        (mac checks C)
 *   both show  SAS = SHA256("ito/sas" || h || Nm || Np) mod 10^6
 *
 * Each side contributes randomness it fixed before seeing the other's, so an
 * attacker running two legs gets two independent codes: a 1-in-a-million
 * shot per attempt, and every attempt needs a human to approve it.
 * h is this channel's handshake hash, so the code also binds the static keys
 * that get pinned.
 */
object Sas {
    private val random = SecureRandom()

    fun nonce(): ByteArray = ByteArray(32).also(random::nextBytes)

    fun commit(nonce: ByteArray): ByteArray = sha256("ito/commit".toByteArray(), nonce)

    fun code(handshakeHash: ByteArray, macNonce: ByteArray, phoneNonce: ByteArray): String {
        val d = sha256("ito/sas".toByteArray(), handshakeHash, macNonce, phoneNonce)
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (d[i].toLong() and 0xff)
        return "%06d".format(java.lang.Long.remainderUnsigned(v, 1_000_000))
    }
}
