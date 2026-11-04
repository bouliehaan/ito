package app.ito

import android.os.PowerManager
import android.util.Log
import app.ito.link.Wall
import app.ito.link.WallConfig
import app.ito.link.WallState
import app.ito.link.WallText
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Tells the wall who has texted and not been answered (link/Wall.kt says what and how).
 *
 * It runs whether or not a Mac is linked: that is the point of it. Its own thread,
 * because a post to a wall that is down takes seconds and nothing else should wait
 * on it. Every change to the texts, a "seen" from the Mac and a new wall each post
 * at once; otherwise it posts every ten minutes, so a wall that restarted has its
 * cards back soon, and after a failure it retries sooner.
 */
class WallReporter(private val bridge: Bridge) {
    private val ctx = bridge.ctx
    private val configFile = File(ctx.filesDir, "wall.json")
    private val seenFile = File(ctx.filesDir, "wall-seen.json")
    private val exec = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "ito-wall").apply { isDaemon = true } }

    /** Held from a change to the post that carries it, so the phone does not sleep in between. */
    private val wake = ctx.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ito:wall").apply { setReferenceCounted(false) }

    @Volatile var config: WallConfig? = load()
        private set
    @Volatile var state: WallState? = null
        private set

    // Only touched on [exec].
    private val seen = HashMap<String, Long>()
    private var lastSent: String? = null
    private var lastOkAt = 0L
    private var failures = 0
    private var next: ScheduledFuture<*>? = null
    private var nextAt = Long.MAX_VALUE
    private var announced: JSONObject? = null

    fun start() = exec.execute {
        loadSeen()
        schedule(0)
    }

    /** The texts changed (arrived, read on the phone, answered): tell the wall shortly. */
    fun changed() = exec.execute { soon() }

    /** The Mac showed you these conversations, up to these times. */
    fun seen(marks: JSONObject) = exec.execute {
        var moved = false
        for (k in marks.keys()) {
            val upTo = marks.optLong(k)
            if (upTo > (seen[k] ?: 0)) { seen[k] = upTo; moved = true }
        }
        if (moved) {
            saveSeen()
            soon()
        }
    }

    /** A wall from the Mac's settings, or null to stop telling any wall anything. */
    fun configure(c: WallConfig?) = exec.execute {
        config = c
        if (c == null) configFile.delete() else writeAtomic(configFile, c.toJson().toString())
        state = null
        lastSent = null
        failures = 0
        announce()
        if (c != null) soon()
    }

    /** For the Mac's hello and the phone's screen: where, and how the last post went. Never the key. */
    fun describe(): Any {
        val c = config ?: return JSONObject.NULL
        val o = JSONObject().put("url", c.url)
        state?.let { o.put("state", it.toJson()) }
        return o
    }

    // --- the one chain of posts ---------------------------------------------------

    private fun soon() {
        if (config == null) return
        wake.acquire(30_000)
        schedule(DEBOUNCE_MS)
    }

    /** Run [tick] in [delayMs], unless it is already due sooner. */
    private fun schedule(delayMs: Long) {
        val at = System.currentTimeMillis() + delayMs
        if (next?.isDone == false && nextAt <= at) return
        next?.cancel(false)
        nextAt = at
        next = exec.schedule(Runnable { tick() }, delayMs, TimeUnit.MILLISECONDS)
    }

    private fun tick() {
        nextAt = Long.MAX_VALUE
        try {
            val c = config ?: return
            val now = System.currentTimeMillis()
            val report = runCatching { report(now) }.getOrElse {
                Log.w(TAG, "cannot read the texts for the wall", it)
                return schedule(HEARTBEAT_MS)
            }
            val body = report.toString()
            val due = body != lastSent || state?.ok != true || now - lastOkAt >= HEARTBEAT_MS
            if (!due) return schedule(HEARTBEAT_MS - (now - lastOkAt))

            val result = Wall.post(c, report, now)
            state = result
            if (result.ok) {
                lastSent = body
                lastOkAt = now
                failures = 0
                schedule(HEARTBEAT_MS)
            } else {
                failures++
                Log.i(TAG, "wall: ${result.error}")
                schedule(minOf(RETRY_MAX_MS, RETRY_MS shl minOf(failures - 1, 4)))
            }
            announce()
        } finally {
            if (nextAt > System.currentTimeMillis() + DEBOUNCE_MS) wake.takeIf { it.isHeld }?.release()
        }
    }

    /** Tell the Macs and the phone's screen, only when what they show would change. */
    private fun announce() {
        val now = describe()
        val shown = (now as? JSONObject)?.let { o ->
            JSONObject(o.toString()).also { copy -> copy.optJSONObject("state")?.remove("at") }
        }
        if (shown?.toString() == announced?.toString()) return
        announced = shown
        bridge.link.broadcast(JSONObject().put("t", "wall").put("wall", now))
        bridge.wallChanged()
    }

    private fun report(now: Long): JSONObject {
        val since = now - Wall.LOOKBACK_MS
        val texts = bridge.store.smsSince(since).mapNotNull { r ->
            if (r.optBoolean("rl")) return@mapNotNull null // a relayed copy of someone else's text is not your answer
            val ty = r.getInt("ty")
            val incoming = ty == INBOX
            if (!incoming && ty !in OUTGOING) return@mapNotNull null
            val g = r.optString("g").takeIf { it.isNotEmpty() && bridge.groups.get(it) != null }
            WallText(g?.let { "g:$it" } ?: "t:${r.getLong("th")}", r.getString("a"), incoming, r.getInt("r") == 1, r.getLong("d"))
        } + bridge.store.mmsSince(since).mapNotNull { m ->
            // An MMS that never downloaded (no mobile data) is still someone sending you something.
            val box = m.getInt("box")
            if (box != MMS_INBOX && box !in MMS_OUTGOING) return@mapNotNull null
            WallText("t:${m.getLong("th")}", m.getString("from"), box == MMS_INBOX, m.getInt("r") == 1, m.getLong("d"))
        }
        seen.entries.removeAll { it.value < since }
        return Wall.report(texts, seen, now, bridge.store::nameFor) { id -> bridge.groups.get(id)?.name }
    }

    // --- files ----------------------------------------------------------------------

    private fun load(): WallConfig? = runCatching {
        if (configFile.exists()) WallConfig.fromJson(JSONObject(configFile.readText())) else null
    }.getOrNull()

    private fun loadSeen() = runCatching {
        if (!seenFile.exists()) return@runCatching
        val o = JSONObject(seenFile.readText())
        for (k in o.keys()) seen[k] = o.optLong(k)
    }.onFailure { Log.w(TAG, "wall-seen.json unreadable, starting fresh", it) }

    private fun saveSeen() = runCatching { writeAtomic(seenFile, JSONObject(seen.toMap()).toString()) }

    private fun writeAtomic(f: File, text: String) {
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
    }

    companion object {
        private const val TAG = "ito-wall"
        private const val DEBOUNCE_MS = 1_500L
        private const val HEARTBEAT_MS = 10 * 60_000L
        private const val RETRY_MS = 30_000L
        private const val RETRY_MAX_MS = 5 * 60_000L
        private const val INBOX = 1
        /** Sent, outbox, failed, queued: you wrote back. A draft is not an answer. */
        private val OUTGOING = setOf(2, 4, 5, 6)
        private const val MMS_INBOX = 1
        private val MMS_OUTGOING = setOf(2, 4)
    }
}
