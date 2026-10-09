package app.ito

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import app.ito.link.DhKey
import app.ito.link.hex
import app.ito.link.sha256
import app.ito.link.toHex
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The phone's Noise identity and the Macs it trusts.
 *
 * The X25519 private key never sits on disk in the clear: it is sealed with
 * an AES-GCM key that lives in the Android Keystore (hardware-backed on the
 * V60) and cannot be exported. The pinned Mac keys are public keys; they are
 * stored plainly, but only this app can write them.
 */
class Keys(private val ctx: Context) {
    private val dir = File(ctx.filesDir, "keys").apply { mkdirs() }
    private val sealedFile = File(dir, "static.sealed")
    private val peersFile = File(dir, "peers.json")

    val static: DhKey by lazy { loadOrCreate() }

    /** Short public fingerprint: the mDNS name and what the Mac pins against. */
    val fingerprint: String get() = sha256(static.pub).toHex().take(8)

    data class Peer(val key: ByteArray, val name: String, val added: Long)

    @Synchronized fun peers(): List<Peer> {
        if (!peersFile.exists()) return emptyList()
        val a = runCatching { JSONArray(peersFile.readText()) }.getOrNull() ?: return emptyList()
        return List(a.length()) { i ->
            val o = a.getJSONObject(i)
            Peer(hex(o.getString("key")), o.optString("name", "mac"), o.optLong("added"))
        }
    }

    @Synchronized fun isPinned(key: ByteArray) = peers().any { it.key.contentEquals(key) }

    @Synchronized fun pin(key: ByteArray, name: String) {
        val list = peers().filterNot { it.key.contentEquals(key) } + Peer(key, name, System.currentTimeMillis())
        writePeers(list)
    }

    @Synchronized fun unpin(key: ByteArray) = writePeers(peers().filterNot { it.key.contentEquals(key) })

    private fun writePeers(list: List<Peer>) {
        val a = JSONArray(list.map { JSONObject().put("key", it.key.toHex()).put("name", it.name).put("added", it.added) })
        val tmp = File(dir, "peers.json.tmp")
        tmp.writeText(a.toString())
        tmp.renameTo(peersFile)
    }

    private fun loadOrCreate(): DhKey {
        if (sealedFile.exists()) {
            runCatching { return DhKey.fromPrivate(unseal(sealedFile.readBytes())) }
            // The Keystore key is gone (e.g. app data restored elsewhere): start over.
            // Every Mac then sees a new phone identity and has to pair again — by design.
        }
        val fresh = DhKey.generate()
        sealedFile.writeBytes(seal(fresh.priv))
        return fresh
    }

    private fun wrapKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    private fun seal(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, wrapKey())
        return byteArrayOf(c.iv.size.toByte()) + c.iv + c.doFinal(plain)
    }

    private fun unseal(blob: ByteArray): ByteArray {
        val ivLen = blob[0].toInt()
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, blob, 1, ivLen))
        return c.doFinal(blob, 1 + ivLen, blob.size - 1 - ivLen)
    }

    private companion object {
        const val ALIAS = "ito-static-wrap"
    }
}
