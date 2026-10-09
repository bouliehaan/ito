package app.ito.link

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/*
 * Group texting without MMS.
 *
 * MMS rides cellular data, and the V60 has none: only Wi-Fi Calling and SMS
 * over IMS. So a group is something the phone runs itself, hub and spoke over
 * plain SMS from your one number:
 *
 *   - What you send to a group goes out as one SMS per member.
 *   - "broadcast" groups: replies come back to you alone, and are threaded
 *     into the group on the Mac. Nobody sees anybody else.
 *   - "relay" groups: a real group chat. When a member replies, the phone
 *     forwards it to every other member as "Sam: ..." (GroupMe's old SMS mode,
 *     but through your number). The first text each member gets says it is a
 *     group and who is in it, so nobody is relayed without knowing.
 *
 * Routing a reply. One number means a reply carries no group id, so the
 * phone answers "what is this person replying to?" with what it last sent
 * them: if the latest thing that went to Sam was group G (your message or a
 * relayed one), and it went recently enough, Sam's reply belongs to G.
 * Anything you send Sam one-to-one after that takes Sam back out.
 *
 * The windows differ on purpose. Filing a reply into a broadcast group only
 * moves where you see it, so it can be generous. Relaying puts someone's
 * words in front of other people, so a relay group goes quiet after a
 * couple of hours: a text after that comes only to you, and you can still
 * push it into the group from the Mac (refile), which relays it then.
 */

data class Group(
    val id: String,
    val name: String,
    val members: List<String>,
    val relay: Boolean,
    val created: Long,
) {
    fun has(number: String) = members.any { Numbers.same(it, number) }

    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("name", name).put("members", JSONArray(members))
        .put("relay", relay).put("created", created)

    companion object {
        fun fromJson(o: JSONObject) = Group(
            id = o.getString("id"),
            name = o.getString("name"),
            members = o.getJSONArray("members").let { a -> List(a.length()) { a.getString(it) } },
            relay = o.optBoolean("relay", false),
            created = o.optLong("created", 0),
        )
    }
}

enum class Role { DIRECT, GROUP, RELAY }

/** Attached to each outgoing SMS so the phone can file it once Android assigns it a row id. */
data class SendTag(val cid: String?, val group: String?, val gm: String?, val role: Role)

/** How a stored SMS row is presented: which group, which group message, and whether it is relay plumbing. */
data class Filed(val group: String, val gm: String?, val relay: Boolean)

fun interface SmsOut {
    fun send(to: String, body: String, tag: SendTag)
}

class GroupEngine(
    private val file: File?,
    private val out: SmsOut,
    private val label: (String) -> String,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private class Touch(val group: String?, val at: Long)

    private val groups = LinkedHashMap<String, Group>()
    private val touches = HashMap<String, Touch>()
    private val introduced = HashSet<String>()
    private val inbound = bounded<String, Filed>(20_000)
    private val relayTimes = HashMap<String, ArrayDeque<Long>>()
    private val outbound = bounded<Long, Filed>(50_000)

    init {
        load()
    }

    @Synchronized fun all(): List<Group> = groups.values.toList()

    @Synchronized fun get(id: String): Group? = groups[id]

    @Synchronized fun save(name: String, members: List<String>, relay: Boolean, id: String? = null): Group {
        val prev = id?.let(groups::get)
        val clean = members.map(String::trim).filter(String::isNotEmpty).distinctBy(Numbers::key)
        require(clean.size >= 2) { "a group needs at least two people" }
        val g = Group(prev?.id ?: newId(), name.trim().ifEmpty { "group" }, clean, relay, prev?.created ?: clock())
        groups[g.id] = g
        persist()
        return g
    }

    @Synchronized fun delete(id: String) {
        groups.remove(id) ?: return
        touches.entries.removeIf { it.value.group == id }
        introduced.removeIf { it.startsWith("$id|") }
        persist()
    }

    /** You texting one person directly takes them out of any group conversation. */
    @Synchronized fun noteDirect(to: String) {
        touches[Numbers.key(to)] = Touch(null, clock())
        persist()
    }

    /** Fan a message out to every member. Returns the group-message id shared by all the copies. */
    @Synchronized fun send(groupId: String, body: String, cid: String?): String {
        val g = groups[groupId] ?: throw IllegalArgumentException("no such group")
        val gm = newId()
        val now = clock()
        for (m in g.members) {
            val k = Numbers.key(m)
            val intro = g.relay && "${g.id}|$k" !in introduced
            val text = if (intro) introFor(g, m) + "\n" + body else body
            out.send(m, text, SendTag(cid, g.id, gm, Role.GROUP))
            touches[k] = Touch(g.id, now)
            if (intro) introduced += "${g.id}|$k"
        }
        persist()
        return gm
    }

    /**
     * An SMS arrived. Decides its group (if any), relays it if that group
     * relays, and remembers the decision so the stored row is shown there.
     */
    @Synchronized fun onInbound(from: String, body: String, sentAt: Long): Filed? {
        val g = replyTarget(from) ?: return null
        return file(g, from, body, sentAt)
    }

    /** Move a received text into a group (relaying it if the group relays), or back out with null. */
    @Synchronized fun refile(from: String, body: String, sentAt: Long, groupId: String?): Filed? {
        val fp = fingerprint(from, sentAt, body)
        if (groupId == null) {
            inbound.remove(fp)
            touches[Numbers.key(from)] = Touch(null, clock())
            persist()
            return null
        }
        val g = groups[groupId] ?: throw IllegalArgumentException("no such group")
        require(g.has(from)) { "not a member of ${g.name}" }
        val already = inbound[fp]
        if (already?.group == g.id) return already
        return file(g, from, body, sentAt)
    }

    /** The phone learned the row id of something it sent. */
    @Synchronized fun bindSent(tag: SendTag, smsId: Long) {
        if (tag.group != null) {
            outbound[smsId] = Filed(tag.group, tag.gm, tag.role == Role.RELAY)
            persist()
        }
    }

    @Synchronized fun filedOutbound(smsId: Long): Filed? = outbound[smsId]

    @Synchronized fun filedInbound(from: String, sentAt: Long, body: String): Filed? =
        inbound[fingerprint(from, sentAt, body)]

    private fun replyTarget(from: String): Group? {
        val t = touches[Numbers.key(from)] ?: return null
        val g = t.group?.let(groups::get) ?: return null
        if (!g.has(from)) return null
        val window = if (g.relay) RELAY_WINDOW_MS else BROADCAST_WINDOW_MS
        return g.takeIf { clock() - t.at <= window }
    }

    private fun file(g: Group, from: String, body: String, sentAt: Long): Filed {
        val gm = newId()
        val filed = Filed(g.id, gm, relay = false)
        inbound[fingerprint(from, sentAt, body)] = filed
        val now = clock()
        touches[Numbers.key(from)] = Touch(g.id, now)
        if (g.relay && relayBudget(g.id, now)) {
            val line = "${label(from)}: $body"
            for (m in g.members) {
                if (Numbers.same(m, from)) continue
                val k = Numbers.key(m)
                val intro = "${g.id}|$k" !in introduced
                out.send(m, if (intro) introFor(g, m) + "\n" + line else line, SendTag(null, g.id, gm, Role.RELAY))
                touches[k] = Touch(g.id, now)
                if (intro) introduced += "${g.id}|$k"
            }
        }
        persist()
        return filed
    }

    /**
     * Two auto-repliers in one relay group would answer each other forever, on your
     * SMS plan. Past [RELAY_BURST] relayed texts in [RELAY_BURST_MS], a group stops
     * relaying (replies are still filed, and still reach you) until it calms down.
     */
    private fun relayBudget(group: String, now: Long): Boolean {
        val q = relayTimes.getOrPut(group) { ArrayDeque() }
        while (q.isNotEmpty() && now - q.first() > RELAY_BURST_MS) q.removeFirst()
        if (q.size >= RELAY_BURST) return false
        q.addLast(now)
        return true
    }

    private fun introFor(g: Group, to: String): String {
        val others = g.members.filterNot { Numbers.same(it, to) }.map(label)
        return "(group text with ${others.joinToString(", ")}. replies go to everyone)"
    }

    private fun fingerprint(from: String, sentAt: Long, body: String): String =
        "${Numbers.key(from)}|${sentAt / 1000}|${sha256(body.toByteArray()).copyOf(8).toHex()}"

    // --- persistence: one small JSON file, replaced atomically ---------------

    private fun persist() {
        val f = file ?: return
        val o = JSONObject()
            .put("groups", JSONArray(groups.values.map(Group::toJson)))
            .put("touches", JSONObject().also { j ->
                touches.forEach { (k, t) -> j.put(k, JSONObject().put("g", t.group ?: JSONObject.NULL).put("at", t.at)) }
            })
            .put("introduced", JSONArray(introduced.toList()))
            .put("inbound", JSONObject().also { j -> inbound.forEach { (k, v) -> j.put(k, v.json()) } })
            .put("outbound", JSONObject().also { j -> outbound.forEach { (k, v) -> j.put(k.toString(), v.json()) } })
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeText(o.toString())
        if (!tmp.renameTo(f)) {
            f.delete()
            tmp.renameTo(f)
        }
    }

    private fun load() {
        val f = file ?: return
        if (!f.exists()) return
        val o = runCatching { JSONObject(f.readText()) }.getOrNull() ?: return
        o.optJSONArray("groups")?.let { a -> for (i in 0 until a.length()) Group.fromJson(a.getJSONObject(i)).let { groups[it.id] = it } }
        o.optJSONObject("touches")?.let { j ->
            j.keys().forEach { k ->
                val t = j.getJSONObject(k)
                touches[k] = Touch(if (t.isNull("g")) null else t.getString("g"), t.getLong("at"))
            }
        }
        o.optJSONArray("introduced")?.let { a -> for (i in 0 until a.length()) introduced += a.getString(i) }
        o.optJSONObject("inbound")?.let { j -> j.keys().forEach { k -> inbound[k] = filedOf(j.getJSONObject(k)) } }
        o.optJSONObject("outbound")?.let { j -> j.keys().forEach { k -> outbound[k.toLong()] = filedOf(j.getJSONObject(k)) } }
    }

    private fun Filed.json() = JSONObject().put("g", group).put("gm", gm ?: JSONObject.NULL).put("rl", relay)

    private fun filedOf(o: JSONObject) =
        Filed(o.getString("g"), if (o.isNull("gm")) null else o.getString("gm"), o.optBoolean("rl"))

    companion object {
        const val RELAY_WINDOW_MS = 2 * 60 * 60 * 1000L
        const val BROADCAST_WINDOW_MS = 24 * 60 * 60 * 1000L
        const val RELAY_BURST = 30
        const val RELAY_BURST_MS = 10 * 60 * 1000L

        private fun newId() = UUID.randomUUID().toString().replace("-", "").substring(0, 12)

        private fun <K, V> bounded(max: Int) = object : LinkedHashMap<K, V>(256, 0.75f, false) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?) = size > max
        }
    }
}
