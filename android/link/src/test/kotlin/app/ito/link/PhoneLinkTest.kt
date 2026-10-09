package app.ito.link

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** End to end over a real socket: handshake, numeric-comparison pairing, trust, sync, refusal. */
class PhoneLinkTest {
    private class Host : PhoneHost {
        override val staticKey = DhKey.generate()
        val pinned = mutableListOf<ByteArray>()
        val codes = LinkedBlockingQueue<String>()
        val handled = LinkedBlockingQueue<JSONObject>()
        val sms = (1L..1200L).map { id ->
            JSONObject().put("id", id).put("th", id % 7).put("a", "555000000${id % 7}").put("b", "message $id ".repeat(5))
                .put("d", id * 1000).put("ty", if (id % 2 == 0L) 2 else 1)
        }

        override fun deviceName() = "test phone"
        override fun isPinned(key: ByteArray) = pinned.any { it.contentEquals(key) }
        override fun pin(key: ByteArray, name: String) { pinned += key }
        override fun showPairing(code: String?, macName: String?) { if (code != null) codes += code }
        override fun hello() = JSONObject().put("name", "test phone")
        override fun status() = JSONObject().put("batt", 100)
        override fun smsAfter(id: Long, limit: Int) = sms.filter { it.getLong("id") > id }.take(limit)
        override fun smsRecent(count: Int) = sms.takeLast(count)
        override fun smsIds() = sms.map { it.getLong("id") }.toLongArray()
        override fun mmsAfter(id: Long, limit: Int) = emptyList<JSONObject>()
        override fun mmsRecent(count: Int) = emptyList<JSONObject>()
        override fun mmsIds() = LongArray(0)
        override fun callsAfter(id: Long, limit: Int) = emptyList<JSONObject>()
        override fun contacts() = listOf(JSONObject().put("k", "1").put("n", "sam").put("p", listOf("5550000001")))
        override fun groups() = emptyList<Group>()
        override fun handle(session: PhoneLink.Session, msg: JSONObject) { handled += msg }
    }

    private class Mac(val key: DhKey = DhKey.generate()) {
        lateinit var ch: Channel
        fun connect(port: Int): JSONObject {
            ch = Channel.connect(Socket("127.0.0.1", port), key, JSONObject().put("name", "test mac"))
            return next()
        }
        fun next(): JSONObject {
            val (kind, body) = ch.receive()
            assertEquals(Kind.JSON, kind)
            return JSONObject(String(body, Charsets.UTF_8))
        }
        fun send(o: JSONObject) = ch.sendJson(o)

        /** The Mac half of numeric comparison: check the commitment, derive the same code. */
        fun pair(): String {
            val commit = next().also { assertEquals("pair.commit", it.getString("t")) }.getString("c")
            val nm = Sas.nonce()
            send(JSONObject().put("t", "pair.nonce").put("n", nm.toHex()))
            val np = hex(next().also { assertEquals("pair.reveal", it.getString("t")) }.getString("n"))
            assertEquals("phone must reveal what it committed to", commit, Sas.commit(np).toHex())
            return Sas.code(ch.handshakeHash, nm, np)
        }
    }

    private val host = Host()
    private val link = PhoneLink(host, port = 0).also { it.start() }

    @After fun stop() = link.stop()

    @Test
    fun pairThenReconnectTrustedAndSync() {
        link.openPairing()
        val mac = Mac()
        assertEquals("pairing", mac.connect(link.boundPort).getString("state"))
        val code = mac.pair()
        assertEquals("both screens show the same code", code, host.codes.poll(5, TimeUnit.SECONDS))
        link.confirmPairing(true)
        mac.send(JSONObject().put("t", "pair.ok"))
        assertEquals("trusted", mac.next().getString("state"))
        assertEquals("hello", mac.next().getString("t"))
        assertArrayEquals(mac.key.pub, host.pinned.single())
        mac.ch.close()

        // Same Mac again: straight to trusted, then a full sync.
        val again = Mac(mac.key)
        assertEquals("trusted", again.connect(link.boundPort).getString("state"))
        again.send(JSONObject().put("t", "sync").put("sms", 0))
        val seen = mutableListOf<Long>()
        var ids = 0
        while (true) {
            val m = again.next()
            when (m.getString("t")) {
                "sms" -> m.getJSONArray("rows").let { r -> for (i in 0 until r.length()) seen += r.getJSONObject(i).getLong("id") }
                "sms.ids" -> ids += m.getJSONArray("ids").length()
                "synced" -> break
            }
        }
        assertEquals((1L..1200L).toList(), seen)
        assertEquals(1200, ids)

        again.send(JSONObject().put("t", "send").put("to", listOf("5550000001")).put("body", "hi"))
        assertEquals("send", host.handled.poll(5, TimeUnit.SECONDS)?.getString("t"))
    }

    @Test
    fun strangerIsRefusedWhenPairingIsClosed() {
        val mac = Mac()
        val auth = mac.connect(link.boundPort)
        assertEquals("refused", auth.getString("state"))
        assertTrue(host.pinned.isEmpty())
    }

    @Test
    fun rejectingTheCodeOnThePhonePinsNothing() {
        link.openPairing()
        val mac = Mac()
        mac.connect(link.boundPort)
        mac.pair()
        host.codes.poll(5, TimeUnit.SECONDS)
        link.confirmPairing(false)
        assertEquals("pair.no", mac.next().getString("t"))
        assertTrue(host.pinned.isEmpty())
    }
}
