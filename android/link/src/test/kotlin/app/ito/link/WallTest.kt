package app.ito.link

import com.sun.net.httpserver.HttpServer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetSocketAddress
import java.util.Base64

/** What the phone tells the wall, how it signs it, and what it makes of the answers. */
class WallTest {
    private val keyText = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc" // 32 bytes of 7
    private val config = WallConfig.of("http://10.0.0.5:43761", keyText)!!
    private val now = 1_793_836_800_000L
    private val minute = 60_000L

    private val mom = "+1 (555) 000-0001"
    private val names = mapOf(Numbers.key(mom) to "Mom", Numbers.key("5550000002") to "Sam Smith")
    private fun name(n: String) = names[Numbers.key(n)]
    private fun group(id: String) = if (id == "trip") "trip" else null

    private fun inText(key: String, from: String, ago: Long, read: Boolean = false) = WallText(key, from, true, read, now - ago)
    private fun outText(key: String, to: String, ago: Long) = WallText(key, to, false, true, now - ago)

    private fun report(texts: List<WallText>, seen: Map<String, Long> = emptyMap()) =
        Wall.report(texts, seen, now, ::name, ::group).getJSONArray("texts").let { a -> List(a.length()) { a.getJSONObject(it) } }

    @Test
    fun signatureMatchesTheWalls() {
        // Computed by secondbrain's own lib/ito.js sign(): the two ends must agree byte for byte.
        assertEquals(
            "606d6960c6e316fb893a1b2a46c940ddfee805b77cf63b94cd53be2bfdd7b944",
            Wall.sign(Base64.getUrlDecoder().decode(keyText), 1793836800123L, """{"v":1,"texts":[]}""".toByteArray()),
        )
    }

    @Test
    fun configTakesWhatEnableItoPrintsAndNothingElse() {
        assertEquals("http://10.0.0.5:43761", config.url)
        assertEquals("http://wall.local:43761", WallConfig.of(" http://wall.local:43761/ ", keyText)?.url)
        assertEquals("http://10.0.0.5", WallConfig.of("http://10.0.0.5/secondbrain", keyText)?.url)
        assertNull("not http", WallConfig.of("ftp://10.0.0.5", keyText))
        assertNull("no host", WallConfig.of("http://", keyText))
        assertNull("short key", WallConfig.of("http://10.0.0.5:43761", keyText.dropLast(1)))
        assertNull("not base64url", WallConfig.of("http://10.0.0.5:43761", keyText.dropLast(1) + "+"))
        assertEquals(config, WallConfig.fromJson(config.toJson()))
    }

    @Test
    fun oneCardPerConversationWithWhoHowManyAndWhenButNeverWhat() {
        val cards = report(listOf(
            inText("t:1", mom, 20 * minute),
            inText("t:1", mom, 5 * minute),
            inText("t:2", "5550000002", 30 * minute),
        ))
        assertEquals(2, cards.size)
        val first = cards[0]
        assertEquals("newest conversation first", "Mom", first.getString("from"))
        assertEquals(2, first.getInt("n"))
        assertEquals(now - 5 * minute, first.getLong("at"))
        assertTrue(first.getBoolean("person"))
        assertEquals(setOf("id", "from", "n", "at", "person"), first.keySet())
        assertEquals("Sam Smith", cards[1].getString("from"))
        assertTrue("ids are stable and opaque", first.getString("id").matches(Regex("[0-9a-f]{12}")))
        assertEquals(first.getString("id"), report(listOf(inText("t:1", mom, 1 * minute)))[0].getString("id"))
    }

    @Test
    fun readOnThePhoneSeenOnTheMacOrAnsweredIsNotNews() {
        assertTrue("read in the phone's own app", report(listOf(inText("t:1", mom, minute, read = true))).isEmpty())
        assertTrue("shown on the mac", report(listOf(inText("t:1", mom, 2 * minute)), mapOf("t:1" to now - minute)).isEmpty())
        assertTrue("answered", report(listOf(inText("t:1", mom, 3 * minute), outText("t:1", mom, 2 * minute))).isEmpty())

        val after = report(listOf(inText("t:1", mom, 10 * minute), outText("t:1", mom, 5 * minute), inText("t:1", mom, minute)))
        assertEquals("a text after the answer is news again, and only it counts", 1, after.single().getInt("n"))
        val seenThenMore = report(listOf(inText("t:1", mom, 10 * minute), inText("t:1", mom, minute)), mapOf("t:1" to now - 5 * minute))
        assertEquals(1, seenThenMore.single().getInt("n"))
    }

    @Test
    fun groupsSayWhichAndWhoSpokeLast() {
        val cards = report(listOf(inText("g:trip", mom, 10 * minute), inText("g:trip", "5550000002", minute)))
        val card = cards.single()
        assertEquals("Sam Smith", card.getString("from"))
        assertEquals("trip", card.getString("group"))
        assertEquals(2, card.getInt("n"))
        assertFalse("a group the phone no longer has has no name to give", report(listOf(inText("g:gone", mom, minute))).single().has("group"))
    }

    @Test
    fun strangersShortCodesAndOldNews() {
        val stranger = report(listOf(inText("t:9", "+15559876543", minute))).single()
        assertEquals("(555) 987-6543", stranger.getString("from"))
        assertTrue(stranger.getBoolean("person"))

        val code = report(listOf(inText("t:8", "72975", minute))).single()
        assertEquals("72975", code.getString("from"))
        assertFalse("a short code is a machine", code.getBoolean("person"))
        assertFalse("so is a sender with a name", report(listOf(inText("t:7", "T-Mobile", minute))).single().getBoolean("person"))

        assertTrue("past the lookback it is history", report(listOf(inText("t:1", mom, Wall.LOOKBACK_MS + minute))).isEmpty())
        val many = report((1..40).map { inText("t:$it", "555000${1000 + it}", it * minute) })
        assertEquals(Wall.MAX_TEXTS, many.size)
    }

    @Test
    fun postSignsTheBodyAndReadsEveryAnswer() {
        var answer = 200 to """{"ok":true,"cards":2}"""
        var seen: Triple<String?, String?, ByteArray>? = null
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext(Wall.PATH) { ex ->
            seen = Triple(ex.requestHeaders.getFirst("X-Ito-Time"), ex.requestHeaders.getFirst("X-Ito-Signature"), ex.requestBody.readBytes())
            assertEquals(Wall.CONTENT_TYPE, ex.requestHeaders.getFirst("Content-Type"))
            val bytes = answer.second.toByteArray()
            ex.sendResponseHeaders(answer.first, bytes.size.toLong())
            ex.responseBody.use { it.write(bytes) }
        }
        server.start()
        try {
            val wall = WallConfig.of("http://127.0.0.1:${server.address.port}", keyText)!!
            val report = Wall.report(listOf(inText("t:1", mom, minute)), emptyMap(), now, ::name, ::group)

            val ok = Wall.post(wall, report, now)
            assertTrue(ok.ok)
            assertEquals(2, ok.cards)
            val (time, signature, body) = seen!!
            assertEquals(now.toString(), time)
            assertEquals(Wall.sign(wall.key, now, body), signature)
            assertEquals(report.toString(), body.decodeToString())
            assertFalse("never the text", body.decodeToString().contains("\"b\""))

            answer = 403 to """{"error":"signature"}"""
            assertTrue(Wall.post(wall, report, now).error!!.contains("refused the key"))
            answer = 403 to """{"error":"clock","skewMs":-420000}"""
            assertEquals("the phone's clock is 7 min off the wall's", Wall.post(wall, report, now).error)
            answer = 404 to """{"error":"off"}"""
            assertTrue(Wall.post(wall, report, now).error!!.contains("enable-ito"))
            answer = 404 to "Cannot POST"
            assertTrue(Wall.post(wall, report, now).error!!.contains("no ito on that address"))
            answer = 403 to "This device is not allowed to access your mirror."
            assertTrue(Wall.post(wall, report, now).error!!.contains("ipWhitelist"))
        } finally {
            server.stop(0)
        }

        val gone = Wall.post(WallConfig.of("http://127.0.0.1:1", keyText)!!, JSONObject().put("v", 1), now, timeoutMs = 2000)
        assertFalse(gone.ok)
        assertNotNull(gone.error)
        assertTrue(gone.error!!, gone.error!!.startsWith("not answering"))
    }
}
