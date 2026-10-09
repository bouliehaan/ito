package app.ito.fakephone

import app.ito.link.DhKey
import app.ito.link.Group
import app.ito.link.GroupEngine
import app.ito.link.Numbers
import app.ito.link.PhoneHost
import app.ito.link.PhoneLink
import app.ito.link.Role
import app.ito.link.SendTag
import app.ito.link.hex
import app.ito.link.sha256
import app.ito.link.toHex
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.sin

/*
 * A stand-in phone for building the Mac app: the real :link server, real
 * Noise, real pairing, real group engine; made-up people and texts.
 *
 *   ./gradlew :fakephone:installDist && fakephone/build/install/fakephone/bin/fakephone [--port 6969] [--auto]
 *
 * --auto confirms pairing on the "phone" side by itself (it still prints the code).
 * --dir <path> keeps its key and pairings somewhere other than ~/.ito-fakephone; --no-mdns skips advertising.
 * Commands on stdin:  in <number> <text> | ring <number> | hangup | status
 */

private val people = listOf(
    "Sam Rivera" to "+15550100001",
    "Alex Chen" to "+15550100002",
    "Jo Park" to "+15550100003",
    "Mira Okafor" to "+15550100004",
    "Dentist" to "+15550100005",
)

private class FakePhone(dir: File, private val auto: Boolean) : PhoneHost {
    private val keyFile = File(dir, "static.key")
    private val peersFile = File(dir, "peers.txt")
    override val staticKey: DhKey = if (keyFile.exists()) DhKey.fromPrivate(hex(keyFile.readText().trim()))
    else DhKey.generate().also { keyFile.writeText(it.priv.toHex()) }

    lateinit var link: PhoneLink
    private val nextSms = AtomicLong(1)
    val sms = ArrayList<JSONObject>()
    private val calls = ArrayList<JSONObject>()
    val groups = GroupEngine(File(dir, "groups.json"), { to, body, tag -> deliverOut(to, body, tag) }, { n ->
        people.firstOrNull { Numbers.same(it.second, n) }?.first?.split(" ")?.first()?.lowercase() ?: "…" + Numbers.key(n).takeLast(4)
    })

    init {
        val now = System.currentTimeMillis()
        val script = listOf(
            Triple(0, 1, "are we still on for tonight"), Triple(0, 2, "yes. 8pm. bring the thing"),
            Triple(0, 1, "which thing"), Triple(0, 2, "you know which thing"),
            Triple(1, 1, "did you see the new cemu build"), Triple(1, 2, "yeah, vulkan or nothing"),
            Triple(2, 1, "running 10 late"), Triple(3, 1, "the package came"), Triple(3, 2, "amazing thank you"),
            Triple(4, 1, "Reminder: cleaning appt Tue 9:30am. Reply C to confirm"),
        )
        script.forEachIndexed { i, (who, ty, body) ->
            val t = now - (script.size - i) * 47 * 60_000L
            addSms(people[who].second, body, ty, t)
        }
        calls += JSONObject().put("id", 1).put("n", people[0].second).put("nm", people[0].first).put("ty", 3).put("d", now - 3_600_000).put("dur", 0)
        calls += JSONObject().put("id", 2).put("n", people[1].second).put("nm", people[1].first).put("ty", 1).put("d", now - 7_200_000).put("dur", 312)
    }

    @Synchronized fun addSms(address: String, body: String, type: Int, at: Long = System.currentTimeMillis(), tag: SendTag? = null): JSONObject {
        val id = nextSms.getAndIncrement()
        val thread = people.indexOfFirst { Numbers.same(it.second, address) }.toLong() + 1
        val row = JSONObject().put("id", id).put("th", if (thread > 0) thread else 99).put("a", address).put("b", body)
            .put("d", at).put("ds", at).put("ty", type).put("r", 1).put("st", if (type == 2) 0 else -1)
        if (tag != null) groups.bindSent(tag, id)
        sms += row
        return row
    }

    @Synchronized private fun rows(filter: (JSONObject) -> Boolean) = sms.filter(filter).map(::enrich)

    private fun enrich(r: JSONObject): JSONObject {
        val o = JSONObject(r.toString())
        val f = if (r.getInt("ty") == 1) groups.filedInbound(r.getString("a"), r.getLong("ds"), r.getString("b")) else groups.filedOutbound(r.getLong("id"))
        f?.let { o.put("g", it.group); it.gm?.let { gm -> o.put("gm", gm) }; if (it.relay) o.put("rl", true) }
        return o
    }

    private fun deliverOut(to: String, body: String, tag: SendTag) {
        val row = addSms(to, body, 2, tag = tag)
        println("  -> sms to $to: ${body.replace("\n", " / ")}")
        link.broadcastRows("sms", listOf(enrich(row)))
        if (tag.cid != null) link.broadcast(JSONObject().put("t", "sent").put("cid", tag.cid).put("to", to).put("ok", true))
    }

    fun inbound(from: String, body: String) {
        val now = System.currentTimeMillis()
        groups.onInbound(from, body, now)
        val row = addSms(from, body, 1, now)
        link.broadcastRows("sms", listOf(enrich(row)))
    }

    // --- PhoneHost -----------------------------------------------------------

    override fun deviceName() = "fake phone"
    override fun isPinned(key: ByteArray) = peersFile.exists() && peersFile.readLines().any { it.trim() == key.toHex() }
    override fun pin(key: ByteArray, name: String) { peersFile.appendText(key.toHex() + "\n"); println("pinned $name") }
    override fun showPairing(code: String?, macName: String?) {
        if (code == null) return
        println("PAIRING CODE  ${code.take(3)} ${code.drop(3)}   (mac: $macName)")
        if (auto) thread { Thread.sleep(300); link.confirmPairing(true) }
        else println("type 'ok' to confirm on the phone side")
    }
    override fun onSessionsChanged(count: Int) = println("linked macs: $count")
    override fun hello() = JSONObject().put("name", "fake phone").put("model", "JVM").put("android", "16").put("number", "+15550109999")
        .put("fp", sha256(staticKey.pub).toHex().take(8)).put("system", true).put("callAudio", "ok").put("sms", true)
    override fun status() = JSONObject().put("batt", 87).put("charging", true).put("plugged", true).put("temp", 29.5).put("wifi", true).put("ims", "wifi")
    override fun smsAfter(id: Long, limit: Int) = rows { it.getLong("id") > id }.take(limit)
    override fun smsRecent(count: Int) = rows { true }.takeLast(count)
    @Synchronized override fun smsIds() = sms.map { it.getLong("id") }.toLongArray()
    override fun mmsAfter(id: Long, limit: Int): List<JSONObject> =
        if (id >= 1) emptyList() else listOf(JSONObject().put("id", 1).put("th", 50).put("d", System.currentTimeMillis() - 86_400_000)
            .put("box", 1).put("r", 1).put("undl", true).put("from", people[3].second).put("to", JSONArray(listOf(people[0].second))).put("b", ""))
    override fun mmsRecent(count: Int) = mmsAfter(0, count)
    override fun mmsIds() = longArrayOf(1)
    @Synchronized override fun callsAfter(id: Long, limit: Int) = calls.filter { it.getLong("id") > id }.take(limit)
    override fun contacts() = people.mapIndexed { i, (n, p) -> JSONObject().put("k", "k$i").put("n", n).put("p", JSONArray(listOf(p))).put("ph", false) }
    override fun groups(): List<Group> = groups.all()

    override fun handle(session: PhoneLink.Session, msg: JSONObject) {
        println("<- ${msg.optString("t")} ${msg.toString().take(160)}")
        when (msg.getString("t")) {
            "send" -> msg.getJSONArray("to").let { a ->
                for (i in 0 until a.length()) {
                    groups.noteDirect(a.getString(i))
                    deliverOut(a.getString(i), msg.getString("body"), SendTag(msg.optString("cid"), null, null, Role.DIRECT))
                }
            }
            "gsend" -> groups.send(msg.getString("g"), msg.getString("body"), msg.optString("cid"))
            "group.save" -> {
                val g = msg.getJSONObject("g")
                val saved = groups.save(g.optString("name"), g.getJSONArray("members").let { a -> List(a.length()) { a.getString(it) } },
                    g.optBoolean("relay"), g.optString("id").ifEmpty { null })
                link.broadcast(JSONObject().put("t", "groups").put("groups", JSONArray(groups.all().map(Group::toJson))))
                session.post(JSONObject().put("t", "group.saved").put("cid", msg.optString("cid")).put("id", saved.id))
            }
            "group.delete" -> {
                groups.delete(msg.getString("id"))
                link.broadcast(JSONObject().put("t", "groups").put("groups", JSONArray(groups.all().map(Group::toJson))))
            }
            "refile" -> {
                val row = synchronized(this) { sms.first { it.getLong("id") == msg.getLong("id") } }
                groups.refile(row.getString("a"), row.getString("b"), row.getLong("ds"), if (msg.isNull("g")) null else msg.getString("g"))
                link.broadcastRows("sms", listOf(enrich(row)))
            }
            "photo" -> session.post(JSONObject().put("t", "photo").put("k", msg.getString("k")).put("jpeg", JSONObject.NULL))
            "dial" -> startCall(msg.getString("n"), "out", session)
            "answer" -> { callState = "active"; callSince = System.currentTimeMillis(); audioTo = session; pushCall() }
            "decline", "hangup" -> endCall()
            "hold" -> { callState = if (msg.optBoolean("on")) "held" else "active"; pushCall() }
            "dtmf" -> println("  dtmf ${msg.optString("d")}")
            "audio" -> { audioTo = if (msg.optBoolean("on")) session else null; pushCall() }
        }
    }

    override fun onAudio(session: PhoneLink.Session, frame: ByteArray) {
        macFrames++
        if (macFrames % 250 == 0L) println("  mic frames from mac: $macFrames")
    }

    // --- a pretend call: a 440 Hz tone stands in for the other person ---------

    private var callState: String? = null
    private var callNumber = ""
    private var callDir = "in"
    private var callSince = 0L
    @Volatile private var audioTo: PhoneLink.Session? = null
    private var macFrames = 0L

    fun startCall(number: String, dir: String, session: PhoneLink.Session? = null) {
        callNumber = number
        callDir = dir
        callState = if (dir == "in") "ringing" else "dialing"
        pushCall()
        if (dir == "out") thread {
            Thread.sleep(2500)
            if (callState == "dialing") { callState = "active"; callSince = System.currentTimeMillis(); audioTo = session; pushCall() }
        }
        thread {
            var seq = 0
            var phase = 0.0
            while (callState != null) {
                val s = audioTo
                if (s != null && callState == "active") {
                    val buf = ByteBuffer.allocate(4 + 640).putInt(seq++)
                    val pcm = ByteBuffer.allocate(640).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    repeat(320) {
                        pcm.putShort((sin(phase) * 3000).toInt().toShort())
                        phase += 2 * PI * 440 / 16000
                    }
                    s.sendAudio(buf.put(pcm.array()).array())
                }
                Thread.sleep(20)
            }
        }
    }

    fun endCall() {
        if (callState == null) return
        callState = "ended"
        pushCall()
        callState = null
        audioTo = null
    }

    private fun pushCall() {
        val st = callState ?: return
        link.broadcast(JSONObject().put("t", "call").put("id", "c1").put("state", st).put("n", callNumber)
            .put("nm", people.firstOrNull { Numbers.same(it.second, callNumber) }?.first ?: "")
            .put("dir", callDir).put("since", callSince).put("audio", audioTo != null).put("full", true))
    }
}

fun main(args: Array<String>) {
    val port = args.indexOf("--port").takeIf { it >= 0 }?.let { args[it + 1].toInt() } ?: PhoneLink.PORT
    val auto = "--auto" in args
    val dir = (args.indexOf("--dir").takeIf { it >= 0 }?.let { File(args[it + 1]) }
        ?: File(System.getProperty("user.home"), ".ito-fakephone")).apply { mkdirs() }
    val phone = FakePhone(dir, auto)
    val link = PhoneLink(phone, port)
    phone.link = link
    link.start()
    link.openPairing(Long.MAX_VALUE / 4)
    println("fake phone on :${link.boundPort}  key ${sha256(phone.staticKey.pub).toHex().take(8)}  (pairing open)")

    // Advertise like the real phone, so the Mac's Bonjour browse finds it.
    val dns = if ("--no-mdns" in args) null else runCatching {
        ProcessBuilder("dns-sd", "-R", "ito-fake", "_ito._tcp", "local", link.boundPort.toString(), "fp=" + sha256(phone.staticKey.pub).toHex().take(8), "v=1")
            .redirectErrorStream(true).redirectOutput(ProcessBuilder.Redirect.DISCARD).start()
    }.getOrNull()
    Runtime.getRuntime().addShutdownHook(Thread { dns?.destroy() })

    val stdin = System.`in`.bufferedReader()
    while (true) {
        val line = stdin.readLine() ?: run { Thread.sleep(Long.MAX_VALUE); return }
        val parts = line.trim().split(" ", limit = 3)
        when (parts[0]) {
            "in" -> if (parts.size == 3) phone.inbound(parts[1], parts[2])
            "ring" -> if (parts.size >= 2) phone.startCall(parts[1], "in")
            "hangup" -> phone.endCall()
            "ok" -> link.confirmPairing(true)
            "status" -> println("macs: ${link.trustedCount}, sms rows: ${phone.sms.size}")
            "" -> Unit
            else -> println("commands: in <number> <text> | ring <number> | hangup | ok | status")
        }
    }
}
