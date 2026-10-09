package app.ito.link

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Pins our Noise to the cacophony vector. The Swift suite reads the same file. */
class NoiseVectorTest {
    private val v = JSONObject(
        File(System.getProperty("ito.vectors"), "noise_xx_25519_chachapoly_sha256.json").readText(),
    )

    @Test
    fun matchesCacophonyVector() {
        val init = XXHandshake(
            initiator = true,
            s = DhKey.fromPrivate(hex(v.getString("init_static"))),
            prologue = hex(v.getString("init_prologue")),
            fixedEphemeral = DhKey.fromPrivate(hex(v.getString("init_ephemeral"))),
        )
        val resp = XXHandshake(
            initiator = false,
            s = DhKey.fromPrivate(hex(v.getString("resp_static"))),
            prologue = hex(v.getString("resp_prologue")),
            fixedEphemeral = DhKey.fromPrivate(hex(v.getString("resp_ephemeral"))),
        )
        val messages = v.getJSONArray("messages")
        for (i in 0 until 3) {
            val m = messages.getJSONObject(i)
            val (writer, reader) = if (i % 2 == 0) init to resp else resp to init
            val ct = writer.writeMessage(hex(m.getString("payload")))
            assertEquals("handshake message $i", m.getString("ciphertext"), ct.toHex())
            assertArrayEquals(hex(m.getString("payload")), reader.readMessage(ct))
        }
        assertEquals(v.getString("handshake_hash"), init.handshakeHash.toHex())
        assertEquals(v.getString("handshake_hash"), resp.handshakeHash.toHex())
        assertArrayEquals(DhKey.fromPrivate(hex(v.getString("resp_static"))).pub, init.remoteStatic)
        assertArrayEquals(DhKey.fromPrivate(hex(v.getString("init_static"))).pub, resp.remoteStatic)

        val ti = init.split()
        val tr = resp.split()
        for (i in 3 until messages.length()) {
            val m = messages.getJSONObject(i)
            val (tx, rx) = if (i % 2 == 0) ti to tr else tr to ti
            val ct = tx.seal(hex(m.getString("payload")))
            assertEquals("transport message $i", m.getString("ciphertext"), ct.toHex())
            assertArrayEquals(hex(m.getString("payload")), rx.open(ct))
        }
    }

    @Test(expected = javax.crypto.AEADBadTagException::class)
    fun tamperedTransportIsRejected() {
        val a = XXHandshake(true, DhKey.generate())
        val b = XXHandshake(false, DhKey.generate())
        b.readMessage(a.writeMessage())
        a.readMessage(b.writeMessage())
        b.readMessage(a.writeMessage())
        val ct = a.split().seal("hi".toByteArray())
        ct[0] = (ct[0].toInt() xor 1).toByte()
        b.split().open(ct)
    }
}
