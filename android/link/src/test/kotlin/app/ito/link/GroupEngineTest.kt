package app.ito.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class GroupEngineTest {
    private val sam = "+1 (555) 000-0001"
    private val alex = "5550000002"
    private val jo = "+15550000003"
    private val names = mapOf(Numbers.key(sam) to "sam", Numbers.key(alex) to "alex", Numbers.key(jo) to "jo")

    private var now = 1_000_000_000_000L
    private val sent = mutableListOf<Triple<String, String, SendTag>>()
    private fun engine(file: File? = null) =
        GroupEngine(file, { to, body, tag -> sent += Triple(to, body, tag) }, { names[Numbers.key(it)] ?: "?" }, { now })

    private fun hours(h: Double) { now += (h * 3_600_000).toLong() }

    @Test
    fun broadcastFansOutAndFilesRepliesWithoutRelaying() {
        val e = engine()
        val g = e.save("trip", listOf(sam, alex, jo), relay = false)
        e.send(g.id, "dinner at 8?", "c1")
        assertEquals(3, sent.size)
        assertTrue("no intro on broadcast", sent.all { it.second == "dinner at 8?" })
        assertEquals(1, sent.map { it.third.gm }.distinct().size)

        sent.clear()
        hours(5.0)
        val f = e.onInbound(sam, "yes", now)
        assertEquals(g.id, f?.group)
        assertTrue("broadcast never relays", sent.isEmpty())

        hours(25.0)
        assertNull("past the broadcast window it is a 1:1 text", e.onInbound(alex, "late reply", now))
    }

    @Test
    fun relayIntroducesOnceThenForwardsWithNames() {
        val e = engine()
        val g = e.save("trip", listOf(sam, alex, jo), relay = true)
        e.send(g.id, "dinner at 8?", "c1")
        val toSam = sent.first { Numbers.same(it.first, sam) }.second
        assertEquals("(group text with alex, jo. replies go to everyone)\ndinner at 8?", toSam)

        sent.clear()
        e.send(g.id, "or 9", "c2")
        assertTrue("intro only once", sent.all { it.second == "or 9" })

        sent.clear()
        hours(0.5)
        val f = e.onInbound(sam, "8 works", now)
        assertEquals(g.id, f?.group)
        assertEquals(setOf(Numbers.key(alex), Numbers.key(jo)), sent.map { Numbers.key(it.first) }.toSet())
        assertTrue(sent.all { it.second == "sam: 8 works" && it.third.role == Role.RELAY })
    }

    @Test
    fun relayGoesQuietAfterTwoHoursAndRefileRelaysLater() {
        val e = engine()
        val g = e.save("trip", listOf(sam, alex), relay = true)
        e.send(g.id, "hi", null)
        sent.clear()
        hours(2.5)
        assertNull(e.onInbound(sam, "private thing", now))
        assertTrue("nothing relayed after the window", sent.isEmpty())

        val f = e.refile(sam, "private thing", now, g.id)
        assertEquals(g.id, f?.group)
        assertEquals(listOf("sam: private thing"), sent.map { it.second })
        assertNotNull(e.filedInbound(sam, now, "private thing"))
    }

    @Test
    fun aDirectTextTakesSomeoneOutOfTheGroup() {
        val e = engine()
        val g = e.save("trip", listOf(sam, alex), relay = true)
        e.send(g.id, "hi all", null)
        e.noteDirect(sam)
        sent.clear()
        assertNull(e.onInbound(sam, "just you", now))
        assertTrue(sent.isEmpty())
    }

    @Test
    fun replyGoesToTheGroupThatLastWroteToThem() {
        val e = engine()
        val a = e.save("a", listOf(sam, alex), relay = false)
        val b = e.save("b", listOf(sam, jo), relay = false)
        e.send(a.id, "x", null)
        hours(1.0)
        e.send(b.id, "y", null)
        assertEquals(b.id, e.onInbound(sam, "re", now)?.group)
    }

    @Test
    fun aRelayStormStopsRelayingButKeepsFiling() {
        val e = engine()
        val g = e.save("loop", listOf(sam, alex), relay = true)
        e.send(g.id, "hi", null)
        sent.clear()
        repeat(40) { i -> assertEquals(g.id, e.onInbound(sam, "auto-reply $i", now)?.group); now += 1000 }
        assertEquals(GroupEngine.RELAY_BURST, sent.size)
        sent.clear()
        now += GroupEngine.RELAY_BURST_MS
        e.onInbound(sam, "back to normal", now)
        assertEquals(1, sent.size)
    }

    @Test
    fun stateSurvivesARestart() {
        val dir = Files.createTempDirectory("ito").toFile()
        val f = File(dir, "groups.json")
        val e = engine(f)
        val g = e.save("trip", listOf(sam, alex), relay = true)
        e.send(g.id, "hi", null)
        e.bindSent(sent[0].third, 42)
        e.onInbound(alex, "yo", now)

        sent.clear()
        val again = engine(f)
        assertEquals("trip", again.get(g.id)?.name)
        assertEquals(g.id, again.filedOutbound(42)?.group)
        assertEquals(g.id, again.filedInbound(alex, now, "yo")?.group)
        again.send(g.id, "still introduced?", null)
        assertTrue(sent.all { it.second == "still introduced?" })
        dir.deleteRecursively()
    }
}
